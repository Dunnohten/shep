import Foundation

/// What the dog page posts back through `webkit.messageHandlers.shep`.
public enum DogMessage: Equatable, Sendable {
    case submit(String)
    case cancel
    case choice(String)
    case cardShown
    case cardHidden
    case said(String)
    /// The page finished setting up `window.shep`; Swift may now send commands (the layout first).
    case ready
    /// Enter or Space on the page's own dog button (the keyboard way to do what a click on the tab does).
    case activate
    /// An uncaught error in the page, for the log.
    case pageError(String)

    /// Anything unrecognised is nil; the body comes from JavaScript, so it is never trusted.
    public static func parse(_ body: Any) -> DogMessage? {
        guard let d = body as? [String: Any] else { return nil }
        if let t = d["submit"] as? String { return .submit(String(t.prefix(500))) }
        if d["cancel"] as? Bool == true { return .cancel }
        if let c = d["choice"] as? String { return .choice(String(c.prefix(40))) }
        if let s = d["card"] as? String { return s == "shown" ? .cardShown : (s == "hidden" ? .cardHidden : nil) }
        if let t = d["say"] as? String { return .said(t) }
        if d["ready"] as? Bool == true { return .ready }
        if d["activate"] as? Bool == true { return .activate }
        if let e = d["error"] as? String { return .pageError(String(e.prefix(300))) }
        return nil
    }
}
