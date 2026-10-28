import CoreGraphics
import Foundation

// Written for Shep.

/// How a live "Fix this screen" request ended (`--live-request`; the line is `[shep] live: outcome: <name>`).
public enum LiveOutcome: String, Equatable, Sendable {
    /// At least one action was approved and done.
    case done
    /// The person answered Cancel (or Escape) on an approval card.
    case declined
    /// The task was stopped (Shep sent home, dismissed) before it finished.
    case cancelled
    /// Shep's rules refused: an app it never looks at, a control it never presses, no permission.
    case refused
    /// Something broke: no window, no screenshot, no provider, a provider error, an action that did not take.
    case failed
    /// The provider had nothing to offer.
    case nothingToOffer = "nothing-to-offer"
    /// The target changed after the card was shown, so a new request needs a new approval.
    case needsFreshApproval = "needs-fresh-approval"
    /// A fix was already running.
    case busy
}

/// The `[shep] live:` log lines of `--live-request`, which scripts/record-fix-demo.sh reads. Every line starts with
/// `[shep] live: ` and fits on one line. Nothing here approves anything: `answered` only records what the person chose.
public enum LiveLog {
    public static let prefix = "[shep] live: "
    /// Longest piece of free text (request, card) kept in a line; longer text ends in an ellipsis.
    public static let textLimit = 300

    public static let waitingForArrival = prefix + "waiting for Shep to arrive"
    public static let noTargetInFront = prefix + "no target app in front"
    public static let arrivalTimedOut = prefix + "Shep did not arrive in time; nothing was submitted"
    public static let finished = prefix + "finished"
    /// A control found only on the screenshot had nothing nameable under it; the walk goes on with the listed controls.
    public static let fallbackToListed = prefix + "fallback: nothing nameable under the spot found on the screenshot; offering the control(s) the app lists"
    /// ... with no listed word match: the ranking's best listed controls are offered as a chooser.
    public static let fallbackToRanked = prefix + "fallback: nothing nameable under the spot found on the screenshot; no listed word match, offering the ranked control(s) the app lists"
    /// ... and nothing listed to offer: the person is asked to say it another way.
    public static let fallbackRephrase = prefix + "fallback: nothing nameable under the spot found on the screenshot and nothing listed to offer; asked to rephrase"

    /// Which app the run reads: the front app when no `--live-target` was given, the wanted app once it is in front. Bundle id only.
    public static func targetFront(_ bundleID: String?) -> String { prefix + "target: front app is " + LiveTargetGate.shown(bundleID) }

    public static func requestSubmitted(_ text: String) -> String { prefix + "request submitted: " + oneLine(text) }
    public static func cardShown(_ text: String) -> String { prefix + "approval card shown: " + oneLine(text) }
    public static func answered(approved: Bool) -> String { prefix + "approval answered: " + (approved ? "approve" : "cancel") }
    public static func outcome(_ outcome: LiveOutcome) -> String { prefix + "outcome: " + outcome.rawValue }
    /// Why a run ended in anything but done, declined or cancelled (the text comes from `LiveReason`, already one line and scrubbed;
    /// it is cleaned again here so no caller can print an unclean one).
    public static func reason(_ text: String) -> String { prefix + "reason: " + LiveReason.clean(text) }
    public static func backdropFailed(_ why: String) -> String { prefix + "backdrop failed: " + oneLine(why) }

    public static func recordRefused(_ why: String) -> String { prefix + "record refused: " + oneLine(why) }
    public static let recordStarted = prefix + "recording started"
    public static func recordWritten(_ path: String) -> String { prefix + "recording written: " + path }
    public static func recordDiscarded(_ why: String) -> String { prefix + "recording discarded: " + oneLine(why) }
    public static func recordNote(_ text: String) -> String { prefix + "record note: " + oneLine(text) }

    public static func debugDirRefused(_ why: String) -> String { prefix + "debug dir refused: " + oneLine(why) }
    public static func debugDumpWritten(_ path: String) -> String { prefix + "debug dump written: " + path }
    public static func debugDumpFailed(_ why: String) -> String { prefix + "debug dump failed: " + oneLine(why) }

    /// `x,y,w,h` in global top-left points, the form the scripts read.
    public static func recordRect(_ cocoaRect: CGRect, primaryScreenHeight: CGFloat) -> String {
        prefix + "record-rect " + BackdropGeometry.logString(cocoaRect, primaryScreenHeight: primaryScreenHeight)
    }

    /// Whitespace runs (newlines, tabs) become single spaces; text past `textLimit` is cut and ends in an ellipsis.
    static func oneLine(_ text: String) -> String {
        var words: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar.properties.isWhitespace || scalar.properties.generalCategory == .control {
                if !current.isEmpty { words.append(String(current)); current = String.UnicodeScalarView() }
            } else {
                current.append(scalar)
            }
        }
        if !current.isEmpty { words.append(String(current)) }
        let joined = words.joined(separator: " ")
        return joined.count > textLimit ? String(joined.prefix(textLimit)) + "…" : joined
    }
}

/// `--live-request` with `--demo-backdrop`: the rectangle of the plain backdrop behind the target app's front window.
/// It holds the window plus a margin (room for the tab, the dog's head, the speech bubble and the approval card), and the
/// overlay panel itself. Cocoa coordinates (y up); clamped to the screens' usable areas, so never into the menu bar.
public enum LiveBackdropGeometry {
    public static let sideMargin: CGFloat = 120
    public static let bottomMargin: CGFloat = 120
    /// The tab (30) plus the dog's headroom (12) plus some air.
    public static let topMargin: CGFloat = 70

    public static func rect(window: CGRect, panel: CGRect?, usable: [CGRect]) -> CGRect? {
        guard window.minX.isFinite, window.minY.isFinite, window.width.isFinite, window.height.isFinite,
              !window.isNull, !window.isEmpty else { return nil }
        let grown = CGRect(x: window.minX - sideMargin, y: window.minY - bottomMargin,
                           width: window.width + 2 * sideMargin, height: window.height + bottomMargin + topMargin)
        var parts = [grown]
        if let panel { parts.append(panel) }   // BackdropGeometry drops a non-finite or empty piece
        return BackdropGeometry.rect(covering: parts, usable: usable, margin: 0)
    }
}
