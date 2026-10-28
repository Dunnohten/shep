import CoreGraphics
import Foundation

/// A proposed action plus what the policy says about it. The UI shows these with Approve / Cancel.
public struct Proposal: Equatable, Sendable {
    public var action: ProposedAction
    public var requirement: ApprovalRequirement
}

public struct FixScreenResult: Equatable, Sendable {
    public enum Status: Equatable, Sendable { case ok, notAllowed(String), failed(String) }
    public var status: Status
    public var provider: String
    public var summary: String
    /// AX controls first, then controls found on the screenshot; numbered 1...n.
    public var controls: [Control]
    /// At most `FixScreenPipeline.maxProposals`, best first, none that policy refuses. Nothing here has been performed.
    public var proposals: [Proposal]
    public var notes: [String]
    /// When there are no proposals: one sentence saying why (nothing fits the request, nothing worth offering).
    public var explanation: String = ""
    /// What happened on the way (namer pick, ranking, picker); empty unless the pipeline filled it in.
    public var trace = FixScreenTrace()
    /// Controls the app lists that answer the request, held back in case a proposal found only on the screenshot has nothing
    /// nameable under it when it is about to be clicked (`ProposalFallback`). Empty when every proposal is a listed control.
    public var fallbackProposals: [Proposal] = []
    /// No listed control shares a word with the request, so `fallbackProposals` is the ranking's best listed controls instead
    /// (offered as a chooser, `ProposalFallback.chooserIntro`).
    public var fallbackRanked = false
    public var foundCount: Int { controls.filter(\.fromVision).count }
}

/// What happens after a proposal found only on the screenshot was refused because nothing nameable is under its spot.
public enum ProposalFallback {
    /// The listed controls to walk instead, or nil to go on as before (any other outcome, a listed proposal, no fallback).
    public static func replacement(after outcome: ActionOutcome, of proposal: Proposal, fallback: [Proposal]) -> [Proposal]? {
        guard proposal.action.control.fromVision, outcome == .refused(ClickGuard.unidentified) else { return nil }
        let listed = fallback.filter { !$0.action.control.fromVision }
        return listed.isEmpty ? nil : listed
    }

    /// Said before a ranked fallback (no listed word match): the controls are the ranking's guess, so the person chooses.
    public static let chooserIntro = "I couldn't tell which control you mean from the screenshot. Here are the closest ones I can name; approve the one you want."
    /// Said instead of a bare "can't identify" when there is nothing listed to offer.
    public static let rephrasePrompt = "I couldn't tell which control you mean. Can you say it another way, e.g. its label?"

    /// What the walk does next after `outcome`: nil to go on as before; else offer the listed fallback (each with its own card,
    /// ClickGuard checking every click; `ranked` adds the chooser intro), or, with nothing listed, ask the person to rephrase.
    public static func step(after outcome: ActionOutcome, of proposal: Proposal, fallback: [Proposal], ranked: Bool) -> ProposalFallbackStep? {
        guard proposal.action.control.fromVision, outcome == .refused(ClickGuard.unidentified) else { return nil }
        guard let listed = replacement(after: outcome, of: proposal, fallback: fallback) else { return .rephrase(rephrasePrompt) }
        return .offer(listed, intro: ranked ? chooserIntro : nil)
    }
}

public enum ProposalFallbackStep: Equatable {
    /// Walk these listed controls instead; say `intro` first when set.
    case offer([Proposal], intro: String?)
    /// Nothing to offer: say this and end the walk.
    case rephrase(String)
}

/// "Fix this screen": AX controls + screenshot -> provider -> VisionRepair merge -> proposed actions -> ApprovalPolicy.
public struct FixScreenPipeline: Sendable {
    public static let maxProposals = ProposalRanker.maxProposals
    public let provider: any VisionProvider
    /// Picks among the best-ranked controls by mark number; without one the ranking itself decides.
    public let picker: (any ProposalPicking)?
    private let preparer: any ImagePreparing
    /// Asked before a screenshot leaves the Mac (cloud providers only).
    public let cloudAllowed: @Sendable () -> Bool

    /// `--live-target`: when set, an input whose app is not this one is refused before anything reaches the provider or the picker.
    public let requiredBundleID: String?

    public init(provider: any VisionProvider, picker: (any ProposalPicking)? = nil, preparer: any ImagePreparing = ImageIOPreparer(),
                cloudAllowed: @escaping @Sendable () -> Bool = { false }, requiredBundleID: String? = nil) {
        self.provider = provider; self.picker = picker; self.preparer = preparer; self.cloudAllowed = cloudAllowed
        self.requiredBundleID = requiredBundleID
    }

    /// Whether this input may go to the provider at all: nil when it may, else the refusal `run` returns without calling the
    /// provider or the picker. Pure and cheap. This form reads the consent closure once; `run` reads it once itself and judges with
    /// that single value (`gate(_:cloudAllowed:)`), so one run never uses two consent decisions.
    public func gate(_ input: VisionInput) -> FixScreenResult.Status? {
        gate(input, cloudAllowed: cloudAllowed())
    }

    /// The gate for a consent value the caller already read.
    public func gate(_ input: VisionInput, cloudAllowed consent: Bool) -> FixScreenResult.Status? {
        if let required = requiredBundleID, ControlPolicy.normalized(required) != ControlPolicy.normalized(input.bundleID) {
            return .notAllowed(LiveTargetGate.wrongFrontText(front: input.bundleID, wanted: required))
        }
        guard ControlPolicy.mayCapture(bundleID: input.bundleID) else {
            return .notAllowed("Shep never looks at this app's window.")
        }
        if provider.sendsOffDevice, !consent {
            return .notAllowed("Sending screenshots to the cloud is off.")
        }
        return nil
    }

    /// Runs the pipeline. Cloud consent is read exactly once, at the start, and that one value decides the gate. `inputSink`, when
    /// given, is called with the exact input the provider is about to get, immediately before `provider.analyze`, and only for a run
    /// that passed the gate: a refused run never calls it (the debug dump hangs here, so it can only hold what is being sent).
    public func run(_ input: VisionInput, inputSink: (@Sendable (VisionInput) -> Void)? = nil) async -> FixScreenResult {
        let consent = cloudAllowed()
        let ax = ControlFilter.prepare(input.axControls, window: nil)
        let asked = (input.request ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var trace = FixScreenTrace(hadRequest: !asked.isEmpty, axCount: ax.count)
        func result(_ status: FixScreenResult.Status, summary: String = "", notes: [String] = []) -> FixScreenResult {
            FixScreenResult(status: status, provider: provider.name, summary: summary, controls: ax, proposals: [], notes: notes, trace: trace)
        }
        if let refusal = gate(input, cloudAllowed: consent) { return result(refusal) }
        var normalized = input
        normalized.axControls = ax
        let analysis: ScreenAnalysis
        inputSink?(normalized)   // the same decision as the gate above; strictly before the provider is asked
        do { analysis = try await provider.analyze(normalized) }
        catch { return result(.failed(Redact.scrub(error.localizedDescription))) }

        trace.space = TraceSpace(geometry: input.geometry, sentSize: analysis.debug.sentSize)
        trace.detector = analysis.debug
        var notes = analysis.notes
        if input.modalInFront { notes.insert(FixScreenPipeline.modalNotice, at: 0) }
        let regions = analysis.controls.map { SAMRegion(box: $0.box, score: $0.score, concept: $0.role.isEmpty ? "button" : $0.role) }
        let candidates = VisionRepair.candidates(from: regions, geometry: input.geometry, ax: ax)
        var byBox: [String: LocatedControl] = [:]
        for l in analysis.controls {
            let key = Self.key(l.box)
            if byBox[key] == nil { byBox[key] = l }
        }
        var labels: [Int: MuseLabel] = [:]
        for c in candidates {
            if let l = byBox[Self.key(c.pixelBox)] { labels[c.id] = MuseLabel(id: c.id, name: l.name, role: l.role.isEmpty ? nil : l.role) }
        }
        var found = VisionRepair.visionItems(candidates, labels: labels, window: input.windowTitle)
        let before = found.count
        found = found.filter { ControlPolicy.refusal($0, bundleID: input.bundleID) == nil }
        if found.count < before { notes.append("left out \(before - found.count) found control(s) Shep never presses") }
        // A found box as big as a pane is not a control: its centre is nothing a click could be bound to.
        let windowFrame = input.geometry.windowFrame
        let controlSized = found.filter { item in item.frame.map { !ProposalRanker.isPaneSized($0, window: windowFrame) } ?? true }
        if controlSized.count < found.count { notes.append("left out \(found.count - controlSized.count) found box(es) as big as a pane") }
        found = controlSized
        trace.foundCount = found.count

        let merged = VisionRepair.merge(ax: ax, vision: found)
        var proposals: [Proposal] = []
        var explanation = ""

        // 1. The namer saw the screenshot and the request together and pointed at one box: offer just that control (an app
        //    control or a found one), if policy allows it.
        var decided = false
        var preferred: Control?   // a listed strong match that overruled a screenshot-only pick: offered without the picker
        if let box = analysis.targetBox, !asked.isEmpty {
            trace.namerTargetBox = box
            let screen = input.geometry.screenRect(forPixels: box)
            let paneSized = ProposalRanker.isPaneSized(screen, window: windowFrame)
            if paneSized { notes.append("the model's pick covers a whole pane, not a control, so the ranking decides") }
            var hit = paneSized ? nil : merged.filter { control in control.frame != nil && VisionRepair.sameControl(control.frame!, screen) }
                .max { x, y in VisionRepair.iou(x.frame!, screen) < VisionRepair.iou(y.frame!, screen) }
            var ambiguous = false
            if hit == nil, !paneSized {
                switch VisionRepair.axDuplicateResolution(of: screen, ax: ax) {
                case .one(let c): hit = c
                case .ambiguous: ambiguous = true
                case .none: hit = RoleResolver.axMatch(for: screen, in: merged.filter { control in !control.fromVision })
                }
            }
            trace.namerMatch = hit.map(Self.namerMatch)
            // The model's pick shares no word with the request while exactly one other control clearly answers it by its words:
            // the pick is not trusted over that (a toolbar button for "turn on the speed limit"). The ranking and picker decide.
            var deferred = false
            if let picked = hit, !paneSized {
                let rankedAll = ProposalRanker.rank(merged, request: asked, bundleID: input.bundleID, window: windowFrame)
                if ProposalRanker.requestMatch(picked, request: asked) == 0,
                   let strong = ProposalRanker.uniqueStrongMatch(in: rankedAll, request: asked), strong != picked {
                    notes.append("the model's pick shares no word with the request, but one control clearly matches it, so the ranking decides")
                    hit = nil
                    deferred = true
                } else if picked.fromVision, let strong = Self.strongListedMatch(merged, request: asked, input: input) {
                    // A pick known only from the screenshot carries the model's own name, which echoes the request, so its words
                    // prove nothing; a click there has only the hit test to go on. One listed control that answers the request
                    // by its own words wins (run 1, 08:08: a box the model drew on empty toolbar space, named "speed limit").
                    notes.append("the model's pick is only on the screenshot and one control the app lists clearly matches the request, so that one is offered")
                    hit = nil
                    deferred = true
                    preferred = strong
                }
            }
            trace.namerMatched = hit != nil
            trace.namerAmbiguous = ambiguous
            if let hit {
                let action = ApprovalPolicy.defaultAction(for: hit, bundleID: input.bundleID)
                let req = ApprovalPolicy.requirement(for: action)
                if case .refused = req { notes.append("the control you asked for is one Shep never presses"); trace.namerRefused = true }
                else { proposals = [Proposal(action: action, requirement: req)]; decided = true }
            } else if !paneSized, !deferred {
                notes.append(ambiguous ? "the model's pick fit two controls equally well, so I left it alone"
                                       : "the model's pick did not match any listed control")
            }
        }

        // 2. Otherwise rank everything, let the model pick among the best by mark number, and propose at most three.
        if !decided {
            let ranked = ProposalRanker.rank(merged, request: asked.isEmpty ? nil : asked, bundleID: input.bundleID,
                                             window: input.geometry.windowFrame)
            var chosen: [Control] = []
            var picked = false
            trace.rankedCount = ranked.count
            trace.ranked = ranked.prefix(FixScreenTrace.rankedLimit).enumerated().map { pair in
                TraceRankedControl(mark: pair.offset + 1, role: pair.element.control.role, label: pair.element.control.label,
                                   matchScore: pair.element.matchScore, fromVision: pair.element.control.fromVision)
            }
            if let strong = preferred {
                chosen = [strong]
                trace.strongMatchOffer = FixScreenTrace.strongMatchOverScreenshotPick
            } else if ranked.isEmpty {
                explanation = asked.isEmpty ? "I didn't find a control worth offering." : "I couldn't find a control for \u{201C}\(String(asked.prefix(60)))\u{201D}."
            } else {
                if let picker {
                    let candidates = ranked.enumerated().map { PickCandidate(mark: $0 + 1, control: $1.control) }
                    let marks = candidates.compactMap { c in c.control.frame.map { ImageMark(id: c.mark, box: input.geometry.space.pixelRect(fromScreen: $0)) } }
                    let image = preparer.prepare(png: input.png, longestSide: 960, quality: 0.7, marks: marks)
                    let job = PickJob(image: image, candidates: candidates, request: asked.isEmpty ? nil : asked, windowTitle: input.windowTitle)
                    do {
                        let result = try await picker.pick(job)
                        picked = true
                        trace.pickerUsed = true
                        trace.pickerMarks = result.marks
                        trace.pickerExplanation = result.explanation
                        var seen = Set<Int>()
                        let known = result.marks.filter { seen.insert($0).inserted }
                            .compactMap { m in candidates.first(where: { $0.mark == m })?.control }
                        chosen = Array(known.prefix(job.maxPicks))
                        if chosen.isEmpty {
                            explanation = result.explanation.isEmpty ? (asked.isEmpty ? "I didn't see a clear next step." : "None of the controls does that.") : result.explanation
                        }
                    } catch {
                        notes.append("picking failed (\(Redact.scrub(error.localizedDescription))); the ranking decides")
                        trace.pickerError = Redact.scrub(error.localizedDescription)
                    }
                    // The model chose nothing (or failed): the ranking's one strong match, if there is exactly one, is still
                    // offered. It goes through the same approval and policy checks below; nothing changes when the model chose.
                    if chosen.isEmpty, !asked.isEmpty, let strong = ProposalRanker.uniqueStrongMatch(in: ranked, request: asked) {
                        chosen = [strong]
                        explanation = ""
                        trace.strongMatchOffer = picked ? FixScreenTrace.strongMatchAfterNone : FixScreenTrace.strongMatchAfterFailure
                    }
                }
                if !picked, chosen.isEmpty {   // (not when the ranking's one strong match was already taken above)
                    // No model: with a request, only controls whose words match it; without one, what Shep exists for:
                    // the controls it found on the screenshot, best first.
                    let fallback = asked.isEmpty ? ranked.filter { $0.control.fromVision } : ranked.filter { $0.matchScore > 0 }
                    chosen = fallback.prefix(Self.maxProposals).map(\.control)
                    if chosen.isEmpty {
                        explanation = asked.isEmpty ? "I didn't find a control worth offering." : "I couldn't find a control for \u{201C}\(String(asked.prefix(60)))\u{201D}."
                    }
                }
            }
            trace.chosenCount = chosen.prefix(Self.maxProposals).count
            for c in chosen.prefix(Self.maxProposals) {
                let action = ApprovalPolicy.defaultAction(for: c, bundleID: input.bundleID)
                let req = ApprovalPolicy.requirement(for: action)
                if case .refused = req { trace.droppedByPolicy += 1; continue }
                proposals.append(Proposal(action: action, requirement: req))
            }
            if proposals.isEmpty, explanation.isEmpty { explanation = "I didn't find a control worth offering." }
        }
        // A proposal found only on the screenshot is clicked, and the click needs something nameable under it. If there is nothing,
        // the walk offers these listed controls instead of refusing (`ProposalFallback`).
        // With no listed word match, the ranking's best listed controls are offered as a chooser instead.
        let needsFallback = proposals.contains { $0.action.control.fromVision }
        var fallback = needsFallback ? Self.listedFallback(merged, request: asked, input: input, excluding: proposals) : []
        let fallbackRanked = needsFallback && fallback.isEmpty
        if fallbackRanked { fallback = Self.rankedFallback(merged, request: asked, input: input, excluding: proposals) }
        trace.fallbackCount = fallback.count
        let summary = analysis.summary.isEmpty ? VisionRepair.summary(merged, appName: input.windowTitle.isEmpty ? "This window" : input.windowTitle)
                                               : analysis.summary
        var result = FixScreenResult(status: .ok, provider: provider.name, summary: summary, controls: merged, proposals: proposals, notes: notes,
                                     explanation: explanation, trace: trace)
        result.fallbackProposals = fallback
        result.fallbackRanked = fallbackRanked && !fallback.isEmpty
        return result
    }

    /// The one listed control that answers `request` by its own words: `uniqueStrongMatch` over the controls the app lists.
    static func strongListedMatch(_ merged: [Control], request: String, input: VisionInput) -> Control? {
        let ranked = ProposalRanker.rank(merged.filter { !$0.fromVision }, request: request, bundleID: input.bundleID, window: input.geometry.windowFrame)
        return ProposalRanker.uniqueStrongMatch(in: ranked, request: request)
    }

    /// Listed controls that share a word (or a synonym) with the request, best first, at most `maxProposals`, none already
    /// proposed and none the approval policy refuses. Empty without a request.
    static func listedFallback(_ merged: [Control], request: String, input: VisionInput, excluding proposals: [Proposal]) -> [Proposal] {
        guard !request.isEmpty else { return [] }
        return listedProposals(merged, request: request, input: input, excluding: proposals) { $0.matchScore > 0 }
    }

    /// The ranking's best listed controls whatever their words, at most `maxProposals`, none already proposed and none the
    /// approval policy refuses: the chooser offered when `listedFallback` is empty.
    static func rankedFallback(_ merged: [Control], request: String, input: VisionInput, excluding proposals: [Proposal]) -> [Proposal] {
        listedProposals(merged, request: request, input: input, excluding: proposals) { _ in true }
    }

    private static func listedProposals(_ merged: [Control], request: String, input: VisionInput, excluding proposals: [Proposal],
                                        where keep: (RankedControl) -> Bool) -> [Proposal] {
        let proposed = Set(proposals.map { $0.action.control.index })
        let ranked = ProposalRanker.rank(merged.filter { !$0.fromVision }, request: request, bundleID: input.bundleID, window: input.geometry.windowFrame)
        var out: [Proposal] = []
        for r in ranked where keep(r) && !proposed.contains(r.control.index) {
            let action = ApprovalPolicy.defaultAction(for: r.control, bundleID: input.bundleID)
            let req = ApprovalPolicy.requirement(for: action)
            if case .refused = req { continue }
            out.append(Proposal(action: action, requirement: req))
            if out.count == maxProposals { break }
        }
        return out
    }

    /// Said when a dialog or sheet is open over the window the screenshot shows.
    public static let modalNotice = "a dialog is open in front of this window"

    static func key(_ r: CGRect) -> String { "\(r.minX),\(r.minY),\(r.width),\(r.height)" }

    /// What the namer's pick matched, for the trace: a listed control by its number, or one known only from the screenshot.
    static func namerMatch(_ c: Control) -> TraceNamerMatch {
        let shown = TraceRankedControl(mark: 0, role: c.role, label: c.label, matchScore: 0, fromVision: c.fromVision)
        return c.fromVision ? .screenshotOnly(role: shown.role, label: shown.label) : .ax(index: c.index, role: shown.role, label: shown.label)
    }
}
