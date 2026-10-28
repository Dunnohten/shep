import CoreGraphics
import Foundation

// Written for Shep.

/// One ranked candidate as the log and the debug dump show it. The mark is the number the picker was shown.
public struct TraceRankedControl: Equatable, Sendable {
    public static let labelLimit = 60
    public var mark: Int
    public var role: String
    /// Whitespace collapsed, at most `labelLimit` characters.
    public var label: String
    public var matchScore: Double
    public var fromVision: Bool

    public init(mark: Int, role: String, label: String, matchScore: Double, fromVision: Bool) {
        self.mark = mark; self.role = role; self.matchScore = matchScore; self.fromVision = fromVision
        let words = label.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        self.label = String(words.prefix(TraceRankedControl.labelLimit))
    }
}

/// One detector box as the debug dump shows it: text only, no pixels. The box in original-image pixels and in window points, what
/// the detector called it, which listed control it is (its # in ax-controls.txt), its candidate number and the namer's name for it.
/// The detector's caption is never kept (it is read off the screen and can hold anything).
public struct TraceDetectorBox: Equatable, Sendable {
    public static let kindLimit = 24
    public var pixelBox: CGRect
    public var windowBox: CGRect
    /// "icon", "button"...: capped at `kindLimit`.
    public var kind: String
    public var score: Double
    /// The Accessibility control this box is, when it is one.
    public var axIndex: Int?
    /// Two listed controls fit it equally well (it is dropped, not guessed).
    public var axAmbiguous: Bool
    /// Its number for the namer, when it became a candidate.
    public var candidate: Int?
    /// The namer's name for it, capped at `TraceRankedControl.labelLimit`; empty when it gave none.
    public var label: String
    /// It became a control found on the screenshot (not a listed control, not text or a picture).
    public var offered: Bool

    public init(pixelBox: CGRect, windowBox: CGRect, kind: String, score: Double, axIndex: Int? = nil, axAmbiguous: Bool = false,
                candidate: Int? = nil, label: String = "", offered: Bool = false) {
        self.pixelBox = pixelBox; self.windowBox = windowBox; self.score = score; self.axIndex = axIndex; self.axAmbiguous = axAmbiguous
        self.candidate = candidate; self.offered = offered
        self.kind = String(kind.prefix(TraceDetectorBox.kindLimit))
        self.label = TraceRankedControl(mark: 0, role: "", label: label, matchScore: 0, fromVision: true).label
    }
}

/// Where the namer's pick came from.
public enum TraceNamerSource: Equatable, Sendable {
    /// One of the numbered detector boxes.
    case candidate(Int)
    /// A box the model drew, which is the same control as candidate n.
    case modelBoxOnCandidate(Int)
    /// A box the model drew itself: no detector box is under it.
    case modelBox
}

/// The control the namer's pick matched in the pipeline (before any check overruled it).
public enum TraceNamerMatch: Equatable, Sendable {
    /// A control the app lists: its # in ax-controls.txt, role and label.
    case ax(index: Int, role: String, label: String)
    /// A control known only from the screenshot; a click there has nothing but the hit test to go on.
    case screenshotOnly(role: String, label: String)
}

/// The coordinate spaces a run used.
public struct TraceSpace: Equatable, Sendable {
    public var imageSize: CGSize
    public var windowFrame: CGRect
    /// Pixels per point actually used for the conversions.
    public var scaleX: Double
    public var scaleY: Double
    /// True when the scale was measured from the image and the window (the normal case); false when the fallback scale was used.
    public var measured: Bool
    /// The fallback scale the capture supplied (used only when a size is missing).
    public var fallbackScale: Double
    /// Pixel size of the image the namer was shown, when known.
    public var sentSize: CGSize?

    public init(geometry: CaptureGeometry, sentSize: CGSize? = nil) {
        imageSize = geometry.imageSize; windowFrame = geometry.windowFrame; scaleX = geometry.scaleX; scaleY = geometry.scaleY
        measured = geometry.windowFrame.width > 0 && geometry.windowFrame.height > 0 && geometry.imageSize.width > 0 && geometry.imageSize.height > 0
        fallbackScale = geometry.scale; self.sentSize = sentSize
    }
}

/// What a detector-based provider adds to the trace. Empty for providers that have no detector.
public struct AnalysisDebug: Equatable, Sendable {
    /// Every box the detector returned, in its order (at most `limit`).
    public var detectorBoxes: [TraceDetectorBox] = []
    public var detectorCount = 0
    public var namerSource: TraceNamerSource?
    public var sentSize: CGSize?
    public static let limit = 60
    public init() {}
}

/// What a Fix-this-screen run did on the way to its answer, so a run that offers nothing can say why. Plain values only.
/// The default value is the empty trace; `FixScreenResult.trace` is empty unless the pipeline got far enough to fill it in.
public struct FixScreenTrace: Equatable, Sendable {
    public static let rankedLimit = 8

    /// The run had a request (the namer, the ranking and the picker all use it).
    public var hadRequest: Bool
    /// The box (original screenshot pixels) the namer pointed at, when it pointed at one.
    public var namerTargetBox: CGRect?
    /// That box matched a control (listed or found).
    public var namerMatched: Bool
    /// That box fitted two controls equally well, so it was left alone.
    public var namerAmbiguous: Bool
    /// The control it matched is one Shep never presses.
    public var namerRefused: Bool
    /// Controls read from Accessibility (prepared), controls found on the screenshot, candidates that survived ranking.
    public var axCount: Int
    public var foundCount: Int
    public var rankedCount: Int
    /// The best `rankedLimit` candidates, best first.
    public var ranked: [TraceRankedControl]
    /// The picker answered (its marks and explanation below are its answer).
    public var pickerUsed: Bool
    public var pickerMarks: [Int]
    public var pickerExplanation: String
    /// The picker was asked and failed; the ranking decided.
    public var pickerError: String?
    /// How many controls were chosen (by the picker or the ranking) and how many of those the approval policy dropped.
    public var chosenCount: Int
    public var droppedByPolicy: Int
    /// The picker chose nothing (or failed) and the ranking's one strong match was offered instead: why, in the words the log uses.
    public var strongMatchOffer: String?
    public static let strongMatchAfterNone = "picker: model chose no control; ranking's one strong match offered"
    public static let strongMatchAfterFailure = "picker: failed; ranking's one strong match offered"
    public static let strongMatchOverScreenshotPick = "namer: pick is only on the screenshot; ranking's one strong Accessibility match offered"

    /// The coordinate spaces of the capture (image pixels, window points, the scale used).
    public var space: TraceSpace?
    /// The detector's boxes and where the namer's pick came from.
    public var detector = AnalysisDebug()
    /// The control the namer's pick matched, before any check overruled it; nil when it matched none.
    public var namerMatch: TraceNamerMatch?
    /// Proposals held back for when a screenshot-only proposal has no nameable element under it.
    public var fallbackCount = 0

    public init(hadRequest: Bool = false, namerTargetBox: CGRect? = nil, namerMatched: Bool = false, namerAmbiguous: Bool = false,
                namerRefused: Bool = false, axCount: Int = 0, foundCount: Int = 0, rankedCount: Int = 0,
                ranked: [TraceRankedControl] = [], pickerUsed: Bool = false, pickerMarks: [Int] = [], pickerExplanation: String = "",
                pickerError: String? = nil, chosenCount: Int = 0, droppedByPolicy: Int = 0) {
        self.hadRequest = hadRequest; self.namerTargetBox = namerTargetBox; self.namerMatched = namerMatched
        self.namerAmbiguous = namerAmbiguous; self.namerRefused = namerRefused; self.axCount = axCount
        self.foundCount = foundCount; self.rankedCount = rankedCount; self.ranked = ranked; self.pickerUsed = pickerUsed
        self.pickerMarks = pickerMarks; self.pickerExplanation = pickerExplanation; self.pickerError = pickerError
        self.chosenCount = chosenCount; self.droppedByPolicy = droppedByPolicy
    }
}

/// A live run that stopped before the pipeline had an answer: the stage and the cause, for the reason line.
public enum LiveFailure: Equatable, Sendable {
    case accessibilityNotAllowed
    case noOtherAppInFront
    case appNeverLooked
    case readFailed
    case captureNoPermission
    case captureNoWindow
    case captureNotAllowed
    case captureFailed
    case providerSetup(String)
    /// `--live-target`: the wanted app was not the one to read (`LiveTargetGate`; the text is already `target: ...`).
    case targetRefused(String)
    case busy
}

/// The `[shep] live: reason:` and `ranked:` lines of `--live-request`.
public enum LiveReason {
    /// The longest reason text after `reason: `.
    public static let maxLength = 240
    /// How many ranked candidates the `ranked:` line shows.
    public static let rankedShown = 5

    /// One line, secrets masked, at most `maxLength` characters (a longer text ends in an ellipsis). The mask comes first so a
    /// secret cut in half by the limit cannot slip through.
    public static func clean(_ text: String) -> String {
        let oneLine = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        let masked = Redact.scrub(oneLine)
        guard masked.count > maxLength else { return masked }
        return String(masked.prefix(maxLength - 1)) + "\u{2026}"
    }

    static func endsQuietly(_ outcome: LiveOutcome) -> Bool {
        outcome == .done || outcome == .declined || outcome == .cancelled
    }

    /// Why the run ended as it did: `<stage>: <cause>`. nil for done, declined and cancelled.
    /// - failure: the run stopped before the pipeline had an answer.
    /// - result: the pipeline's answer (its trace says what happened inside).
    /// - actionNote: what the walk through the proposals reported (a refusal, a failed action, a changed target).
    public static func text(outcome: LiveOutcome, failure: LiveFailure?, result: FixScreenResult?, actionNote: String?) -> String? {
        if endsQuietly(outcome) { return nil }
        let raw = rawText(outcome: outcome, failure: failure, result: result, actionNote: actionNote)
        return clean(raw)
    }

    /// The whole log line, or nil when the outcome needs no reason.
    public static func reasonLine(outcome: LiveOutcome, failure: LiveFailure?, result: FixScreenResult?, actionNote: String?) -> String? {
        guard let t = text(outcome: outcome, failure: failure, result: result, actionNote: actionNote) else { return nil }
        return LiveLog.reason(t)
    }

    /// `[shep] live: ranked: #1 AXButton "Gear" score=3.50; ...` (top five), for a run that had a request and ended in anything
    /// but done, declined or cancelled. `ranked: none` when nothing was ranked. nil otherwise.
    public static func rankedLine(outcome: LiveOutcome, trace: FixScreenTrace) -> String? {
        if endsQuietly(outcome) || !trace.hadRequest { return nil }
        let shown = trace.ranked.prefix(rankedShown).map { c in
            "#\(c.mark) \(c.role) \"\(c.label)\" score=\(String(format: "%.2f", c.matchScore))"
        }
        let body = shown.isEmpty ? "none" : shown.joined(separator: "; ")
        let oneLine = body.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        return LiveLog.prefix + "ranked: " + Redact.scrub(oneLine)
    }

    /// The `reason:` line for a run whose proposal came from the ranking's one strong match; nil otherwise.
    public static func offerLine(trace: FixScreenTrace) -> String? {
        guard let why = trace.strongMatchOffer else { return nil }
        return LiveLog.reason(why)
    }

    private static func rawText(outcome: LiveOutcome, failure: LiveFailure?, result: FixScreenResult?, actionNote: String?) -> String {
        if let failure = failure { return failureText(failure) }
        if outcome == .busy { return failureText(.busy) }
        if let result = result {
            switch result.status {
            case .notAllowed(let why): return "policy: refused (\(why))"
            case .failed(let why): return "provider: \(why)"
            case .ok: break
            }
            if result.proposals.isEmpty, (actionNote ?? "").isEmpty { return pipelineText(result.trace) }
        }
        if let note = actionNote, !note.isEmpty {
            switch outcome {
            case .refused: return "policy: refused (\(note))"
            case .needsFreshApproval: return "action: target changed after approval (\(note))"
            default: return "action: \(note)"
            }
        }
        switch outcome {
        case .refused: return "policy: refused (no further detail)"
        case .nothingToOffer: return "provider: nothing to offer (no further detail)"
        case .needsFreshApproval: return "action: target changed after approval"
        default: return "run: ended without saying why"
        }
    }

    static func failureText(_ failure: LiveFailure) -> String {
        switch failure {
        case .accessibilityNotAllowed: return "policy: refused (Accessibility is not allowed for Shep)"
        case .noOtherAppInFront: return "policy: refused (no other app is in front)"
        case .appNeverLooked: return "policy: refused (the front app is one Shep never looks at)"
        case .readFailed: return "read: could not read the window's controls (no snapshot)"
        case .captureNoPermission: return "capture: no permission (Screen Recording is not allowed)"
        case .captureNoWindow: return "capture: no window"
        case .captureNotAllowed: return "policy: refused (the window belongs to an app Shep never looks at)"
        case .captureFailed: return "capture: capture failed"
        case .providerSetup(let why): return "provider: \(why)"
        case .targetRefused(let why): return why
        case .busy: return "busy: a fix is already running"
        }
    }

    /// The pipeline answered and offered nothing: name the last stage that decided it.
    static func pipelineText(_ t: FixScreenTrace) -> String {
        var namer = ""
        if t.namerTargetBox != nil, !t.namerMatched {
            namer = t.namerAmbiguous ? "namer: pick fit two controls equally well" : "namer: pick did not match any listed control"
        }
        if t.namerRefused {
            return "policy: refused (the control the model pointed at is one Shep never presses)"
        }
        let rest: String
        if t.pickerUsed, t.pickerMarks.isEmpty || t.chosenCount == 0, t.droppedByPolicy == 0 {
            let said = t.pickerExplanation.trimmingCharacters(in: .whitespacesAndNewlines)
            rest = said.isEmpty ? "picker: model chose no control" : "picker: model chose no control: \"\(said)\""
        } else if t.droppedByPolicy > 0, t.droppedByPolicy >= t.chosenCount {
            rest = "policy: refused (every control chosen is one Shep never presses)"
        } else if let error = t.pickerError {
            let tail = t.rankedCount == 0 ? "" : (t.hadRequest ? ": no candidate matched the request words" : ": nothing worth offering")
            rest = "picker: failed (\(error)); ranking decided\(tail)"
        } else if t.rankedCount == 0 {
            rest = "ranking: no candidate controls (\(t.axCount) from Accessibility, \(t.foundCount) found on screen)"
        } else if t.hadRequest {
            rest = "ranking: no candidate matched the request words"
        } else {
            rest = "ranking: nothing worth offering"
        }
        return namer.isEmpty ? rest : namer + "; " + rest
    }
}
