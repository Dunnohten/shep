import AppKit
import ApplicationServices
import ShepCore

/// Holds the debug dump the pipeline's input sink opened (the sink runs off the main actor). Empty when the sink never fired.
private final class DebugDumpHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var sink: LiveDebugSink?

    func set(_ new: LiveDebugSink?) { lock.lock(); sink = new; lock.unlock() }
    var current: LiveDebugSink? { lock.lock(); defer { lock.unlock() }; return sink }
}

/// "Fix this screen" end to end for the running app: read the front window's controls, capture it, ask the provider,
/// then walk the proposals one at a time. Every proposal asks (Approve / Cancel in the card) before anything is done.
@MainActor
final class FixScreenCoordinator {
    private let overlay: OverlayController
    /// The environment the providers read (launch variables, then the saved Settings).
    private let environment: () -> [String: String]
    private var running = false
    /// A walk through the proposals ended with at least one action done: the finish beat plays (and keeps the dog's pose).
    var onFinished: (() -> Void)?
    /// `--live-request`: the `[shep] live:` lines (already formatted by ShepCore's LiveLog) for the card, the person's answer and the
    /// outcome. Reporting only: nothing here answers a card.
    /// @Sendable: the debug dump's log callback runs off the main actor (inside the pipeline), so what this closure captures must be
    /// thread-safe (the owner captures a `LiveRunGate`, not itself).
    var onLive: (@Sendable (String) -> Void)?
    /// `--live-status`: the same moments as closed events with no text (`LiveStatusEvent`), for scripts to classify the run from.
    var onLiveEvent: ((LiveStatusEvent) -> Void)?
    /// `--live-debug-dir`: when set, every run writes what it handed the provider and decided into a new folder there
    /// (LiveDebugDump). nil writes nothing.
    var debugDirectory: String?
    /// `--live-target`: while set, a run reads only this app. The front app's bundle id is compared with it right before the
    /// Accessibility read, and a different one ends the run (`outcome: refused`) with nothing read, captured or sent.
    var requiredBundleID: String?
    /// `--live-target`: the run noticed (at a look it makes itself) that the wanted app is no longer in front. The owner ends the run
    /// (`LiveTargetGate.focusLeft` text, bundle ids only); this coordinator then stops quietly (`targetWasLeft`).
    var onTargetLeft: ((String) -> Void)?
    /// A live run's owner hands in the gate it also reads (its reporters filter on it); the latch is shared, never reset. nil: every run
    /// gets a fresh gate of its own (the menu and voice runs).
    var externalGate: LiveRunGate?
    /// The target left the front: what is in flight stops at its next look and says nothing, its result is dropped as a whole (not
    /// dumped, not offered, not sent further: `LiveRunGate.decideResult`), nothing more is asked, and no pending or later approval is
    /// granted. A fresh gate when a run starts, unless the owner supplied one.
    private var runGate = LiveRunGate()

    init(overlay: OverlayController, environment: @escaping () -> [String: String] = { ProcessInfo.processInfo.environment }) {
        self.overlay = overlay
        self.environment = environment
    }

    /// The target of a bound live run left the front. Closes a waiting approval card (the person's answer becomes "cancel": nothing
    /// that was waiting for approval is performed) and makes the run in progress drop whatever it gets next. What already went
    /// (a screenshot sent to the provider) is not undone. Idempotent.
    func targetWasLeft() {
        runGate.latchLeft()
        externalGate?.latchLeft()
        overlay.cancelPendingCard()
    }

    /// The live look at the front app, for the points where the answer matters most (after the capture, before a card, after an
    /// approval): the live front app, not a flag. When the wanted app is not in front (Shep's own card in front does not count as
    /// leaving) the run is marked left and the owner ends it; true then.
    private func targetLeftNow() -> Bool {
        if runGate.isLeft { return true }
        guard let wanted = requiredBundleID else { return false }
        let front = NSWorkspace.shared.frontmostApplication
        let frontIsShep = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        guard let why = LiveTargetGate.focusLeft(wanted: wanted, front: front?.bundleIdentifier, frontIsShep: frontIsShep) else { return false }
        targetWasLeft()
        onTargetLeft?(why)
        return true
    }

    func run(request: String?) async {
        let hadRequest = !(request ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard !running else {
            overlay.say(Brief.busy)
            logEnd(outcome: .busy, failure: .busy, result: nil, actionNote: nil, hadRequest: hadRequest)
            return
        }
        running = true
        runGate = externalGate ?? LiveRunGate()
        var finished = false
        var outcome = LiveOutcome.failed
        // What the reason line is made from: the stage that stopped the run, the pipeline's answer, what the walk reported.
        var failure: LiveFailure?
        var answer: FixScreenResult?
        var actionNote: String?
        defer {
            running = false
            if !finished { overlay.setState(.idle) }
            logEnd(outcome: outcome, failure: failure, result: answer, actionNote: actionNote, hadRequest: hadRequest)
        }

        guard AXIsProcessTrusted() else {
            outcome = .refused; failure = .accessibilityNotAllowed
            overlay.say("I need Accessibility permission first. Open Shep Setup from the menu."); return
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ownPID else {
            outcome = .refused; failure = .noOtherAppInFront
            overlay.say("Bring the window you want fixed to the front first."); return
        }
        let pid = app.processIdentifier
        let wanted = requiredBundleID
        if let wanted = wanted {
            // The last look before anything is read: only the wanted app, in front at this instant, is read.
            if case .refuse(let why) = LiveTargetGate.recheck(wanted: wanted, front: app.bundleIdentifier, wantedRunning: true) {
                outcome = .refused; failure = .targetRefused(why)
                overlay.say(LiveTargetGate.overlayLine); return
            }
        }
        guard ControlPolicy.mayCapture(bundleID: app.bundleIdentifier ?? "") else {
            outcome = .refused; failure = .appNeverLooked
            overlay.say("Shep never looks at this app's window."); return
        }
        onLive?(LiveLog.targetFront(app.bundleIdentifier))   // what this run reads, for any live run
        overlay.setState(.thinking)
        overlay.say(Brief.onIt)

        let maybeSnapshot: AXSnapshot? = await Task.detached { AXReader.read(pid: pid) }.value
        if runGate.isLeft { return }   // the target left while it was being read: nothing else is looked at, nothing is said
        guard let snapshot = maybeSnapshot else { failure = .readFailed; overlay.say("I couldn't read that window's controls."); return }
        if let wanted = wanted, case .refuse(let why) = LiveTargetGate.recheck(wanted: wanted, front: snapshot.bundleID, wantedRunning: true) {
            // The process that was read is not the wanted app: nothing is captured or sent.
            outcome = .refused; failure = .targetRefused(why)
            overlay.say(LiveTargetGate.overlayLine); return
        }

        let shot: ScreenCapture.Shot
        let captured = await ScreenCapture.captureWindow(pid: pid, nearFrame: snapshot.windowFrame)
        if runGate.isLeft { return }
        // Looked at again after the capture, before anything goes to a provider: the target must still be the app in front
        // (Shep's own card in front does not count as leaving). The owner ends the run and says why.
        if targetLeftNow() { return }
        switch captured {
        case .success(let s): shot = s
        case .failure(.noPermission): outcome = .refused; failure = .captureNoPermission; overlay.say("I need Screen Recording permission to look at the window."); return
        case .failure(.noWindow): failure = .captureNoWindow; overlay.say("I couldn't find that window on screen."); return
        case .failure(.notAllowed): outcome = .refused; failure = .captureNotAllowed; overlay.say("Shep never looks at this app's window."); return
        case .failure(.captureFailed): failure = .captureFailed; overlay.say("The screenshot failed."); return
        }

        let environment = self.environment()
        let config = ProviderConfig.from(environment: environment, home: NSHomeDirectory())
        let made: (provider: any VisionProvider, selection: ProviderSelection)
        do { made = try ProviderFactory.make(config: config, environment: environment) }
        catch { failure = .providerSetup(error.localizedDescription); overlay.say(error.localizedDescription); return }

        let axControls = ControlFilter.prepare(snapshot.controls, limit: 60, window: snapshot.windowFrame)
        let focusSample = overlay.focusSample   // how the target was chosen, taken now, for the debug dump's trace
        let input = VisionInput(png: shot.png, geometry: shot.geometry, axControls: axControls, bundleID: snapshot.bundleID,
                                windowTitle: snapshot.windowTitle.isEmpty ? snapshot.appName : snapshot.windowTitle, request: request,
                                modalInFront: snapshot.modalInFront)
        let picker = ProviderFactory.makePicker(config: config, environment: environment)
        let pipeline = FixScreenPipeline(provider: made.provider, picker: picker, cloudAllowed: { MetaVisionSettings.sendScreenshots() },
                                       requiredBundleID: wanted)
        // Nothing is written before the send decision, and the coordinator makes no decision of its own: the pipeline reads consent
        // once, gates the input with that one value and calls this sink immediately before the provider, so the dump exists only for
        // a run that is about to send, on the same decision. A refused input creates no directory.
        let dumpHolder = DebugDumpHolder()
        var inputSink: (@Sendable (VisionInput) -> Void)?
        if let dir = debugDirectory {
            let report = onLive
            inputSink = { sent in
                let opened: LiveDebugSink? = LiveDebug.dumpInputs(gate: nil, begin: {
                    let began: LiveDebugSink? = LiveDebugDump.begin(directory: dir, now: Date(), log: { line in report?(line) })
                    return began
                }, png: sent.png, axControls: sent.axControls, request: sent.request)
                dumpHolder.set(opened)
            }
        }
        if runGate.isLeft { return }   // nothing is sent to a provider for a run whose target already left
        // The whole sequence after the provider's await is `LiveResultFlow.afterProvider` (ShepCore, tested with a provider the test
        // suspends): ONE look at the gate right after the await, then keep the answer, write the trace, offer. A result that arrives
        // after the target left is dropped as a whole: not kept for the closing lines, not written to the debug dump, not offered. The
        // inputs the dump already holds are what was sent.
        let sink = inputSink
        var ended = OfferEnd()
        await LiveResultFlow.afterProvider(gate: runGate, produce: { await pipeline.run(input, inputSink: sink) },
                                           keep: { answer = $0 },
                                           dump: { result in
                                               if let dump = dumpHolder.current {
                                                   dump.write("trace.txt", text: LiveDebug.traceText(result, focus: focusSample))
                                                   dump.announce()
                                               }
                                           },
                                           offer: { result in
                                               ended = await self.offer(result, snapshot: snapshot, windowNumber: shot.windowNumber)
                                           })
        if let offered = ended.outcome { outcome = offered }
        finished = ended.finished
        actionNote = ended.note
        if finished { onFinished?() }
    }

    /// How the offer of a result ended: the outcome it set (nil leaves the run's own), whether the walk finished, the walk's note.
    private struct OfferEnd {
        var outcome: LiveOutcome?
        var finished = false
        var note: String?
    }

    /// Turns an accepted result into an overlay line, or into the walk through its proposals.
    private func offer(_ result: FixScreenResult, snapshot: AXSnapshot, windowNumber: CGWindowID) async -> OfferEnd {
        var end = OfferEnd()
        switch result.status {
        case .notAllowed(let why): end.outcome = .refused; overlay.say(why); return end
        case .failed(let why): overlay.say("That didn't work: \(why)", milliseconds: 6000); return end
        case .ok: break
        }
        if result.proposals.isEmpty {
            end.outcome = .nothingToOffer
            overlay.say(Brief.nothing)
            return end
        }
        if runGate.isLeft { return end }
        cardPeers = snapshot.controls + result.controls   // the whole AX list, not only the capped one the provider saw
        let walked = await walk(result.proposals, fallback: result.fallbackProposals, fallbackRanked: result.fallbackRanked,
                                snapshot: snapshot, windowNumber: windowNumber)
        end.finished = walked.finished
        end.outcome = walked.outcome
        end.note = walked.note
        return end
    }

    /// One proposal at a time. Cancel stops the whole walk.
    /// `finished` is true when every step was handled and at least one action was done (not cancelled, not stopped); `outcome` is
    /// how the walk ended, for the `--live-request` log. When a control found only on the screenshot has nothing nameable under its
    /// spot, the rest of the walk is the listed `fallback` (once; `ProposalFallback` decides), each with its own card; with nothing
    /// listed, the person is asked to say it another way.
    private func walk(_ initial: [Proposal], fallback: [Proposal], fallbackRanked: Bool, snapshot: AXSnapshot,
                      windowNumber: CGWindowID) async -> (finished: Bool, outcome: LiveOutcome, note: String?) {
        var proposals = initial
        var fellBack = false
        var anyDone = false
        var last = LiveOutcome.failed
        var note: String?
        let overlay = self.overlay
        let performer = ActionPerformer(snapshot: snapshot, windowNumber: windowNumber,
                                        beforeClick: { await overlay.hideForClick() },
                                        afterClick: { await MainActor.run { overlay.showAfterClick() } })
        let appName = snapshot.appName
        let runner = ActionRunner(executor: performer, approve: { [weak self] request in
            await self?.confirm(request, appName: appName) ?? false
        })
        var i = 0
        while i < proposals.count {
            let p = proposals[i]
            if Task.isCancelled || runGate.isLeft { return (false, .cancelled, note) }
            cardWasTooLong = false
            let outcome = await runner.run(p.action)
            if runGate.isLeft { return (false, .cancelled, note) }   // left during the card or the action: nothing more is said or asked
            if !fellBack, let step = ProposalFallback.step(after: outcome, of: p, fallback: fallback, ranked: fallbackRanked) {
                fellBack = true
                switch step {
                case .offer(let listed, let intro):
                    onLive?(intro == nil ? LiveLog.fallbackToListed : LiveLog.fallbackToRanked)
                    if let intro {
                        overlay.say(intro, milliseconds: 5000)
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        if Task.isCancelled || runGate.isLeft { return (false, .cancelled, note) }
                    }
                    proposals = listed
                    i = 0
                    continue
                case .rephrase(let prompt):
                    onLive?(LiveLog.fallbackRephrase)
                    if case .refused(let why) = outcome { note = why }
                    overlay.say(prompt, milliseconds: 6000)
                    return (anyDone, anyDone ? .done : .refused, note)
                }
            }
            switch outcome {
            case .done: anyDone = true; last = .done; overlay.say(Brief.done)   // what was done is in the log and the outcome
            case .declined where cardWasTooLong:
                // No card was shown and nobody chose: a refusal that says why, not "Cancelled."
                overlay.say(Brief.tooLong); return (false, .refused, Brief.tooLong)
            case .declined: overlay.say(Brief.cancelled); return (false, .declined, note)
            case .cancelled: return (false, .cancelled, note)
            case .refused(let why): last = .refused; note = why; overlay.say(why)
            case .failed(let why): last = .failed; note = why; overlay.say(why, milliseconds: 5000)
            case .needsFreshApproval(let why):
                // What was approved is not what is there now: stop the walk; the user asks again and approves the new target.
                overlay.say(why, milliseconds: 6000)
                return (false, .needsFreshApproval, why)
            }
            if i < proposals.count - 1 {
                try? await Task.sleep(nanoseconds: UInt64(Brief.stepGapSeconds * 1_000_000_000))
                if Task.isCancelled { return (false, .cancelled, note) }
            }
            i += 1
        }
        return (anyDone, anyDone ? .done : last, note)
    }

    /// The last lines of a run for `--live-request`: what was ranked and why it ended (only when it ended in anything but done,
    /// declined or cancelled), then the outcome itself. Reporting only.
    private func logEnd(outcome: LiveOutcome, failure: LiveFailure?, result: FixScreenResult?, actionNote: String?, hadRequest: Bool) {
        let trace = result?.trace ?? FixScreenTrace(hadRequest: hadRequest)
        if let line = LiveReason.rankedLine(outcome: outcome, trace: trace) { onLive?(line) }
        if let line = LiveReason.reasonLine(outcome: outcome, failure: failure, result: result, actionNote: actionNote) { onLive?(line) }
        if let text = LiveReason.text(outcome: outcome, failure: failure, result: result, actionNote: actionNote) {
            onLiveEvent?(.reason(LiveStatus.stage(forReasonText: text)))   // the stage name only, never the text
        }
        if let line = LiveReason.offerLine(trace: trace) { onLive?(line) }   // the model chose nothing; the ranking's one strong match was offered
        onLive?(LiveLog.outcome(outcome))
        onLiveEvent?(.outcome(outcome))
    }

    /// The window's controls for the run being offered: approval cards shorten a name only when no other control shares it.
    private var cardPeers: [Control] = []
    /// Set by `confirm` when the card text was too long to show whole, so the walk reports a refusal, not a denial.
    private var cardWasTooLong = false

    private func confirm(_ request: ApprovalRequest, appName: String) async -> Bool {
        if targetLeftNow() { return false }   // no card for a run whose target left (read from the live front app, not only from a flag)
        let text = request.cardText(peers: cardPeers)
        guard Brief.cardFits(text) else { cardWasTooLong = true; return false }   // never approve what the card could not show; the walk says why
        let title = request.action.dialogTitle(appName: appName, peers: cardPeers)
        onLive?(LiveLog.cardShown(text))
        onLiveEvent?(.cardShown)
        let choice = await overlay.ask(text, choices: Brief.approvalChoices, title: title)
        // Whatever the person chose in the card; Escape (nil) counts as cancel. An Approve is looked at once more against the live front
        // app: one that raced with the target leaving is not an approval, and is not reported as one.
        let approved = choice == "approve"
        if approved && targetLeftNow() { return false }
        onLive?(LiveLog.answered(approved: approved))
        onLiveEvent?(.answered(approved: approved))
        return approved && !runGate.isLeft
    }
}
