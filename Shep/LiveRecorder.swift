import AppKit
import CoreGraphics
import CoreMedia
import ScreenCaptureKit
import ShepCore

// Written for Shep.

/// Receives the stream's and the recording output's callbacks, which arrive on ScreenCaptureKit's own queues. Plain flags
/// behind a lock; the recorder reads them from the main actor.
@available(macOS 15.0, *)
final class RecordingEvents: NSObject, SCStreamDelegate, SCRecordingOutputDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var failureText: String?
    private var didFinish = false

    var failure: String? { lock.lock(); defer { lock.unlock() }; return failureText }
    var finished: Bool { lock.lock(); defer { lock.unlock() }; return didFinish }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        lock.lock(); didFinish = true; lock.unlock()
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        lock.lock(); failureText = error.localizedDescription; lock.unlock()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock(); failureText = error.localizedDescription; lock.unlock()
    }
}

/// Holds the stream for its stop, which runs in a task that is abandoned if it hangs (`BoundedAwait`). Returns the error text, or nil.
@available(macOS 15.0, *)
private final class StreamStopper: @unchecked Sendable {
    private let stream: SCStream

    init(_ stream: SCStream) { self.stream = stream }

    func stop() async -> String? {
        do {
            try await stream.stopCapture()
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

/// `--live-record <out.mov>`: records the target app's front window, and Shep's own overlay windows, into a movie.
///
/// The recording is bound to windows, not to a screen area. The content filter lists only the target window and Shep's overlay
/// windows (`RecordingWindowSelection`); every other window, however it overlaps or sits on top, is not drawn, and what is not
/// drawn is the plain background colour. The capture policy (`RecordingPolicy`, which is `ControlPolicy.mayCapture`) is checked
/// before the start, and `RecordingWatch` is polled every 0.25 s: when the target closes, changes owner, is replaced under the
/// same process id or becomes forbidden, the stream stops and the partial file is deleted.
@available(macOS 15.0, *)
@MainActor
final class LiveRecorder {
    private let outputURL: URL
    private let maxSeconds: Int
    private let overlayWindowNumbers: () -> Set<Int>
    private let log: (String) -> Void
    private let events = RecordingEvents()

    private var stream: SCStream?
    private var target: RecordingTarget?
    private var displayID: CGDirectDisplayID = 0
    private var selected: [UInt32] = []
    private var timer: Timer?
    private var lastFrame: CGRect = .zero
    private var watch = RecordingWatchState()
    /// `[shep] live: watch ...`: the first check, every change, a summary every 5 s. Seconds count from the start of the recording.
    private var watchLog = RecordingWatchLogState()
    private var watchStartedAt: TimeInterval = 0
    private var refreshing = false
    private var finishing = false
    /// The private working directory this recorder owns by identity (`RecordingSlot`): the stream writes only `<workdir>/clip.mov` (a path
    /// in a parent folder judged private to the person), the movie is published to `outputURL` with link() when it is finished, and only
    /// our own clip and directory are ever removed. ScreenCaptureKit opens by path, so every start, tick, stop and publish re-checks that
    /// the path still leads to the held directory and the clip first seen (`pathIsBound`, `observeClip`); this narrows the race, it
    /// cannot make the write atomic with the descriptor.
    private var slot: RecordingSlot?
    private let onEvent: (LiveStatusEvent) -> Void
    private(set) var isRecording = false
    /// The task that runs `start` (it awaits several times) and whether one was ever launched. A discard requested meanwhile awaits THIS
    /// task (bounded) and then wins; "never started" is only true when no task was ever launched.
    private var startTask: Task<Bool, Never>?
    private var startLaunched = false
    /// `discard-unknown` was reported: a later end of the same cleanup adds a log line, not a second outcome event.
    private var unknownReported = false
    /// A discard was requested (the target left). Latched for good, first reason wins; every await in `start` and `end` looks at it
    /// again afterwards, so a keep that is already finalising cannot publish after it.
    private var pendingDiscard: String?
    /// The task that ends the recording (keep or discard); a requested discard awaits it.
    private var endTask: Task<Void, Never>?
    /// How a discard ended (set by `end`), so a second request gets the same answer.
    private var finalOutcome: RecordingDiscardOutcome?
    /// The clip was published to its final path (`recording-written` was reported).
    private var didPublish = false
    private var alreadyPublishedReported = false
    private var refusalReported = false

    init(outputURL: URL, maxSeconds: Int, overlayWindowNumbers: @escaping () -> Set<Int>, log: @escaping (String) -> Void,
         onEvent: @escaping (LiveStatusEvent) -> Void = { _ in }) {
        self.onEvent = onEvent
        self.outputURL = outputURL
        self.maxSeconds = maxSeconds
        self.overlayWindowNumbers = overlayWindowNumbers
        self.log = log
    }

    /// Launches the start as a task the recorder keeps, and says so synchronously (`startLaunched`), so a discard requested before the
    /// task has run its first line still knows a start exists and waits for it. The task's value is `start`'s: false, with a
    /// `live: record refused:` line, when it did not start; the caller carries on without it.
    @discardableResult
    func launchStart(pid: pid_t, frame: CGRect, crop: CGRect) -> Task<Bool, Never> {
        startLaunched = true
        let task = Task { @MainActor [weak self] () -> Bool in
            guard let self = self else { return false }
            return await self.start(pid: pid, frame: frame, crop: crop)
        }
        startTask = task
        return task
    }

    /// Starts recording `pid`'s window at `frame` (global top-left points), cropped to `crop` (global top-left points, clamped
    /// to the display). Only `launchStart` calls this.
    private func start(pid: pid_t, frame: CGRect, crop: CGRect) async -> Bool {
        if pendingDiscard != nil {
            refuse("the target left the front")
            return false
        }
        let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        let windowNumber = DemoBackdrop.windowNumber(pid: pid, frame: frame)
        if let why = RecordingPolicy.refusal(bundleID: bundleID, screenRecordingAllowed: CGPreflightScreenCaptureAccess(),
                                             targetWindowFound: windowNumber != nil) {
            refuse(why)
            return false
        }
        guard let bundleID = bundleID, let windowNumber = windowNumber else {
            refuse("the target could not be identified")
            return false
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let windowID = UInt32(windowNumber)
        let ids = RecordingWindowSelection.select(windows: currentWindows(), targetPID: Int32(pid), targetWindowID: windowID, ownPID: Int32(ownPID))
        guard ids.contains(windowID) else {
            refuse("the target window is not on screen")
            return false
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            refuse("could not list the windows: \(error.localizedDescription)")
            return false
        }
        let centre = CGPoint(x: crop.midX, y: crop.midY)
        guard let display = content.displays.first(where: { $0.frame.contains(centre) }) ?? content.displays.first else {
            refuse("no display")
            return false
        }
        let clamped = crop.intersection(display.frame)
        guard !clamped.isNull, clamped.width >= 16, clamped.height >= 16 else {
            refuse("the record area is outside the display")
            return false
        }
        let windows = content.windows.filter { ids.contains($0.windowID) }
        guard windows.contains(where: { $0.windowID == windowID }) else {
            refuse("ScreenCaptureKit does not list the target window")
            return false
        }

        // Claim the output at the last moment before the stream exists. Anything at the final path (a file, a directory, a symlink, a
        // dangling symlink) refuses; otherwise the stream gets a private working directory of its own and nothing else is ever removed.
        let claimed: RecordingSlot
        switch RecordingSlot.claim(finalPath: outputURL.path) {
        case .failure(let refusal):
            refuse(refusal.reason)
            return false
        case .success(let made):
            claimed = made
        }
        slot = claimed
        // The recorder is handed a PATH (ScreenCaptureKit does not take a descriptor): before anything is written, the path must still lead
        // to the directory this slot holds. A swapped folder means no stream is ever started.
        guard claimed.pathIsBound() else {
            completeDiscard("the private folder was swapped")
            return false
        }
        if pendingDiscard != nil {   // the target left while the output was being claimed: no stream is ever started
            cleanUpUnstarted()
            refuse("the target left the front")
            return false
        }
        let configuration = SCStreamConfiguration()
        // sourceRect is in the display's own points, top-left origin.
        configuration.sourceRect = CGRect(x: clamped.minX - display.frame.minX, y: clamped.minY - display.frame.minY,
                                          width: clamped.width, height: clamped.height)
        configuration.width = Self.evenPixels(clamped.width * 2)
        configuration.height = Self.evenPixels(clamped.height * 2)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.backgroundColor = DemoBackdrop.color.cgColor
        configuration.showsCursor = true

        let filter = SCContentFilter(display: display, including: windows)
        let captureStream = SCStream(filter: filter, configuration: configuration, delegate: events)
        let recordingConfiguration = SCRecordingOutputConfiguration()
        recordingConfiguration.outputURL = URL(fileURLWithPath: claimed.clipPath)   // the defaults are a QuickTime movie with H.264 video
        let recordingOutput = SCRecordingOutput(configuration: recordingConfiguration, delegate: events)
        do {
            try captureStream.addRecordingOutput(recordingOutput)
            try await captureStream.startCapture()
        } catch {
            refuse("the stream did not start: \(error.localizedDescription)")
            cleanUpUnstarted()
            return false
        }

        stream = captureStream
        displayID = display.displayID
        selected = ids
        target = RecordingTarget(pid: Int32(pid), windowID: windowID, bundleID: bundleID, frame: frame)
        lastFrame = frame
        watch = RecordingWatchState()
        watchLog = RecordingWatchLogState()
        watchStartedAt = ProcessInfo.processInfo.systemUptime
        isRecording = true
        if let why = pendingDiscard {   // the target left while the stream started: stop it and remove what it wrote
            finishing = true
            await end(discardBecause: why)
            return false
        }
        // The first clip must show up in the directory we hold, and the path must still lead there; otherwise stop and discard.
        if let problem = await confirmFirstClip(claimed) {
            finishing = true
            await end(discardBecause: problem)
            return false
        }
        if let why = pendingDiscard {   // the target left during the wait for the first clip
            finishing = true
            await end(discardBecause: why)
            return false
        }
        log(LiveLog.recordStarted)
        let poll = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer = poll
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(maxSeconds)) { [weak self] in
            MainActor.assumeIsolated { self?.stopAndKeep() }
        }
        return true
    }

    /// Stops and keeps the movie after `seconds` (the request finished; this leaves a moment of the end state in the clip).
    func requestStop(afterSeconds seconds: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            MainActor.assumeIsolated { self?.stopAndKeep() }
        }
    }

    /// The run ended before it was done (the target left the front): the clip is stopped and discarded through the slot rules (our own
    /// partial clip and directory only), and this returns only when that has ended, with how it ended. The intent is latched first
    /// (here and in the slot), so a keep that is already finalising, a stop scheduled earlier or a start still in flight cannot publish
    /// after it. A clip that was published before the request stays and is reported as such (`recording-already-published`); a removal
    /// that failed is `discard-failed`, never `recording-discarded`.
    ///
    /// Code review of d8213e1 (N1): nothing is claimed while work is in flight. A start that was launched is awaited (the real task,
    /// for at most `RecordingDiscardPlanner.startBoundSeconds`) and an end that is under way is awaited (at most `endBoundSeconds`);
    /// if either does not finish, or the stream's stop did not complete, the answer is `unknown` (`discard-unknown`: a clip may remain)
    /// and never `recording-discarded`. `neverStarted` is returned only when no start was ever launched, or when the start itself
    /// refused and said so. The events are written by this recorder as the outcome happens.
    func requestDiscard(because why: String) async -> RecordingDiscardOutcome {
        if pendingDiscard == nil { pendingDiscard = why }
        _ = slot?.requestDiscard()   // latch the slot's own intent now: whatever the start does next, it cannot publish
        let task = startTask
        let outcome = await RecordingDiscardFlow.resolve(startLaunched: startLaunched,
                                                         awaitStart: { if let task = task { _ = await task.value } },
                                                         startBoundSeconds: RecordingDiscardPlanner.startBoundSeconds,
                                                         perform: { await self.performDiscard() })
        switch outcome {
        case .neverStarted:
            if !refusalReported {
                refusalReported = true
                onEvent(.recordingDiscarded(refused: true))
            }
        case .unknown(let text):
            reportUnknown(text)
        case .removed, .failed, .alreadyPublished:
            break   // the recorder wrote these events as they happened
        }
        return outcome
    }

    /// The discard itself, once no start is in flight: ask the slot, end the recording if it is running, and wait (bounded) for an end
    /// that is under way.
    private func performDiscard() async -> RecordingDiscardOutcome {
        if let slot = slot, slot.requestDiscard() == .alreadyPublished { return reportAlreadyPublished() }
        if didPublish { return reportAlreadyPublished() }
        if isRecording && !finishing { beginEnd(discardBecause: pendingDiscard) }
        if let task = endTask {
            let waited = await BoundedAwait.run(seconds: RecordingDiscardPlanner.endBoundSeconds) { await task.value }
            let plan = RecordingDiscardPlanner.afterEndWait(wait: waited.didTimeOut ? .timedOut : .completed)
            if case .unknown(let text) = plan { return .unknown(text) }
        }
        if let outcome = finalOutcome { return outcome }
        if didPublish { return reportAlreadyPublished() }
        if refusalReported { return .neverStarted }   // the start refused and reported it: no stream was ever created
        return .unknown(RecordingDiscardPlanner.noOutcomeText)
    }

    /// `discard-unknown`, once: the human line and the status event.
    private func reportUnknown(_ text: String) {
        guard !unknownReported else { return }
        unknownReported = true
        log(LiveLog.recordNote("the discard could not be confirmed: " + text))
        onEvent(.recordingDiscardUnknown)
    }

    private func reportAlreadyPublished() -> RecordingDiscardOutcome {
        if !alreadyPublishedReported {
            alreadyPublishedReported = true
            log(LiveLog.recordNote("the target left after the clip was published; it stays at the output path"))
            onEvent(.recordingAlreadyPublished)
        }
        return .alreadyPublished
    }

    // MARK: watching

    private func tick() {
        guard isRecording, !finishing, let target = target else { return }
        let now = observe(target)
        let movement = RecordingWatch.movement(from: lastFrame, to: now.frame)
        if let note = movement, let frame = now.frame {
            lastFrame = frame
            log(LiveLog.recordNote(note))
        }
        // One watch line per change (RecordingWatchLogState), logged before the check acts on it.
        let t = ProcessInfo.processInfo.systemUptime - watchStartedAt
        if case .stop(let why) = watch.verdict(target: target, now: now) {
            logWatch(t: t, alive: false, reason: RecordingWatchLog.reason(target: target, now: now, moved: movement != nil))
            discard(why)
            return
        }
        if let why = events.failure {
            logWatch(t: t, alive: false, reason: .streamError)
            discard("the stream reported an error: \(why)")
            return
        }
        if let problem = slotProblem() {
            logWatch(t: t, alive: false, reason: .slotProblem)
            discard(problem)
            return
        }
        logWatch(t: t, alive: true, reason: RecordingWatchLog.reason(target: target, now: now, moved: movement != nil))
        // Shep's own windows come and go (the travelling dog, the cards): keep the filter's list current.
        let ids = RecordingWindowSelection.select(windows: currentWindows(), targetPID: target.pid, targetWindowID: target.windowID,
                                                  ownPID: ProcessInfo.processInfo.processIdentifier)
        if Set(ids) != Set(selected), ids.contains(target.windowID) { refreshFilter(ids) }
    }

    private func logWatch(t: Double, alive: Bool, reason: WatchReason) {
        for line in watchLog.record(t: t, alive: alive, reason: reason) { log(line) }
    }

    private func refreshFilter(_ ids: [UInt32]) {
        guard !refreshing, let stream = stream else { return }
        refreshing = true
        Task { [weak self] in
            guard let self = self else { return }
            defer { self.refreshing = false }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard self.isRecording, !self.finishing,
                      let display = content.displays.first(where: { $0.displayID == self.displayID }) else { return }
                let windows = content.windows.filter { ids.contains($0.windowID) }
                try await stream.updateContentFilter(SCContentFilter(display: display, including: windows))
                self.selected = ids
            } catch {
                self.log(LiveLog.recordNote("could not refresh the window list: \(error.localizedDescription)"))
            }
        }
    }

    private func observe(_ target: RecordingTarget) -> RecordingObservation {
        var entries: [RecordingWindowEntry] = []
        for entry in Self.windowInfo() {
            guard let number = entry[kCGWindowNumber as String] as? Int, let pid = entry[kCGWindowOwnerPID as String] as? Int else { continue }
            var bounds: CGRect?
            if let dict = entry[kCGWindowBounds as String] as? NSDictionary { bounds = CGRect(dictionaryRepresentation: dict as CFDictionary) }
            entries.append(RecordingWindowEntry(id: UInt32(number), ownerPID: Int32(pid), bounds: bounds))
        }
        let front = NSWorkspace.shared.frontmostApplication
        return RecordingWatch.observe(
            target: target, windows: entries,
            bundleForPID: { pid in
                let running = NSRunningApplication(processIdentifier: pid_t(pid))
                return (running?.isTerminated ?? true) ? nil : running?.bundleIdentifier
            },
            pidsForBundle: { id in
                NSRunningApplication.runningApplications(withBundleIdentifier: id).filter { !$0.isTerminated }.map { Int32($0.processIdentifier) }
            },
            frontPID: front?.processIdentifier, frontBundleID: front?.bundleIdentifier,
            processFact: { pid in
                if let running = NSRunningApplication(processIdentifier: pid_t(pid)) {
                    return ProcessFact.classify(runningIsTerminated: running.isTerminated, killResult: 0, killErrno: 0)
                }
                let result = kill(pid_t(pid), 0)
                return ProcessFact.classify(runningIsTerminated: nil, killResult: result, killErrno: result == 0 ? 0 : errno)
            })
    }

    private func currentWindows() -> [RecordingWindow] {
        let overlays = overlayWindowNumbers()
        var result: [RecordingWindow] = []
        for entry in Self.windowInfo() {
            guard let number = entry[kCGWindowNumber as String] as? Int, let pid = entry[kCGWindowOwnerPID as String] as? Int else { continue }
            let layer = (entry[kCGWindowLayer as String] as? Int) ?? 0
            let onScreen = (entry[kCGWindowIsOnscreen as String] as? Bool) ?? true
            result.append(RecordingWindow(id: UInt32(number), pid: Int32(pid), layer: layer, onScreen: onScreen, isShepOverlay: overlays.contains(number)))
        }
        return result
    }

    private static func windowInfo() -> [[String: Any]] {
        (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
    }

    private static func evenPixels(_ value: CGFloat) -> Int {
        let n = Int(value.rounded())
        return max(2, n - (n % 2))
    }

    // MARK: ending

    private func stopAndKeep() {
        guard isRecording, !finishing, pendingDiscard == nil else { return }
        beginEnd(discardBecause: nil)
    }

    private func discard(_ why: String) {
        guard isRecording, !finishing else { return }
        beginEnd(discardBecause: why)
    }

    private func beginEnd(discardBecause why: String?) {
        finishing = true
        endTask = Task { [weak self] in await self?.end(discardBecause: why) }
    }

    /// Polls briefly (every 50 ms, at most 3 s) for the first clip through the held directory, then checks that the path still leads there.
    /// nil when all is well. A recording that is slow to create its file is not an error here; `tick()` keeps looking.
    private func confirmFirstClip(_ slot: RecordingSlot) async -> String? {
        var tries = 0
        while tries < 60 {
            switch slot.observeClip() {
            case .failure(let refusal):
                return refusal.reason
            case .success(let seen):
                if seen != nil { return slot.pathIsBound() ? nil : "the private folder was swapped" }
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
            tries += 1
        }
        return slot.pathIsBound() ? nil : "the private folder was swapped"
    }

    /// Why the slot can no longer be trusted, or nil: the clip is not the file first seen, or the path no longer leads to the held directory.
    private func slotProblem() -> String? {
        guard let slot = slot else { return nil }
        if case .failure(let refusal) = slot.observeClip() { return refusal.reason }
        if !slot.pathIsBound() { return "the private folder was swapped" }
        return nil
    }

    private func refuse(_ why: String) {
        refusalReported = true
        log(LiveLog.recordRefused(why))
        onEvent(.recordingDiscarded(refused: true))
    }

    /// The recording ended without a clip at the output path. `recording-discarded` only when the removal succeeded; a removal that
    /// failed (or a clip that stays in its working directory) is `discard-failed`, with the human line saying so.
    private func discarded(_ why: String, outcome: RecordingDiscardOutcome) {
        if case .unknown(let text) = outcome {
            reportUnknown(why + ": " + text)
            return
        }
        // A cleanup that was already reported as unknown ended late: the unknown stays the answer (the script keeps the worst word).
        if unknownReported {
            log(LiveLog.recordNote("the cleanup that was reported as unknown ended late; its late result is not reported as an event"))
            return
        }
        switch outcome {
        case .removed, .neverStarted:
            log(LiveLog.recordDiscarded(why))
        case .failed(let text):
            log(LiveLog.recordNote("the clip was NOT discarded (" + why + "): " + text))
        case .unknown, .alreadyPublished:
            break
        }
        if outcome != .alreadyPublished { onEvent(outcome.statusEvent) }
    }

    /// A stream that never started: its slot is cleaned up; only a failed cleanup is reported (the refusal was already).
    private func cleanUpUnstarted() {
        let outcome = discardSlot()
        if case .failed = outcome { onEvent(outcome.statusEvent) }
    }

    private func written() {
        log(LiveLog.recordWritten(outputURL.path))
        onEvent(.recordingWritten)
    }

    /// The only place the recorder deletes anything: its own clip and its own working directory, after the slot re-checks that the
    /// directory is still the one it made. If the identity no longer matches, nothing is removed and the log says so. The final path
    /// is never unlinked.
    @discardableResult
    private func discardSlot() -> RecordingDiscardOutcome {
        guard let slot = slot else { return .neverStarted }
        self.slot = nil
        let result = slot.discard()
        switch result {
        case .removed, .alreadyFinished: break
        case .identityMismatch: log(LiveLog.recordNote("the working directory is not the one I made; I removed nothing"))
        case .clipReplaced(let text): log(LiveLog.recordNote(text))
        case .leftBehind(let why): log(LiveLog.recordNote("left behind: " + why))
        }
        return RecordingDiscardOutcome(slotResult: result)
    }

    /// Ends the recording with no clip at the output path: removes our own clip and directory and reports how that went.
    private func completeDiscard(_ why: String, stopCompleted: Bool = true) {
        let outcome = RecordingDiscardPlanner.finalOutcome(removal: discardSlot(), stopCompleted: stopCompleted)
        finalOutcome = outcome
        discarded(why, outcome: outcome)
    }

    /// Publishes the finished clip to the output path with link(); an output path taken meanwhile keeps the clip in the working directory.
    /// A discard that was requested meanwhile (the slot's own latch, checked under its lock right before the link) wins: nothing is linked.
    private func publishSlot() {
        guard let slot = slot else { return }
        let result = slot.publish()
        if result != .discardRequested && result != .noClip { self.slot = nil }   // those two still discard the slot's directory below
        switch result {
        case .published, .alreadyFinished:
            didPublish = true
            written()
        case .publishedLeavingWorkDirectory(let note):
            didPublish = true
            log(LiveLog.recordNote(note))
            written()
        case .keptInWorkDirectory(let clipPath, let why):
            keptWithoutClip("could not publish to the output path (\(why)); the clip is kept at \(clipPath)")
        case .identityMismatch:
            keptWithoutClip("the working directory is not the one I made, so I published and removed nothing")
        case .noClip:
            completeDiscard("there is no clip to publish")
        case .clipReplaced(let text):
            keptWithoutClip(text)
        case .discardRequested:
            completeDiscard(pendingDiscard ?? "the target left the front")
        }
    }

    /// No clip at the output path, and something of ours stays where it is: reported as `discard-failed`, not as a discard.
    private func keptWithoutClip(_ text: String) {
        finalOutcome = .failed(text)
        discarded("no clip was published", outcome: .failed(text))
    }

    private func end(discardBecause requested: String?) async {
        timer?.invalidate()
        timer = nil
        // Check the slot before stopping, and again after the movie is finished: a swap in between is a discard, not a publish.
        let before = slotProblem()
        var stopError: String?
        var stopCompleted = true
        if let stream = stream {
            // The stop is bounded: a ScreenCaptureKit stop that hangs is abandoned after `stopBoundSeconds` and the outcome is unknown.
            let stopper = StreamStopper(stream)
            let stopped = await BoundedAwait.run(seconds: RecordingDiscardPlanner.stopBoundSeconds) { await stopper.stop() }
            switch stopped {
            case .value(let error): stopError = error
            case .timedOut: stopCompleted = false
            }
        }
        // The movie is finalised after the stream stops: give the recording output a moment to say so (not when the stop never completed).
        var waited = 0
        let movieTries = Int(RecordingDiscardPlanner.movieWaitSeconds * 10)
        while stopCompleted && !events.finished && waited < movieTries {
            try? await Task.sleep(nanoseconds: 100_000_000)
            waited += 1
        }
        isRecording = false
        stream = nil
        // Everything above awaited: a discard requested meanwhile (`pendingDiscard`) is known now and wins over a good clip. No await
        // follows, and the slot checks its own latch again under its lock right before the link.
        let decision = RecordingEndPlanner.decide(requested: requested, pendingDiscard: pendingDiscard, slotProblem: before ?? slotProblem(),
                                                  failure: events.failure ?? stopError, clipSize: slot?.clipSize() ?? 0,
                                                  movieFinished: events.finished, stopCompleted: stopCompleted)
        switch decision {
        case .discard(let why): completeDiscard(why, stopCompleted: stopCompleted)   // our own partial clip and directory only
        case .publish: publishSlot()
        }
    }
}
