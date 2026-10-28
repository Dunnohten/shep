import CoreGraphics
import Foundation

/// Plain-text report for `Shep --ax-read-once`. Read-only: it only formats what the reader saw.
/// Scripts grep the `key: value` lines (`controls_kept`, `nodes_visited`, `truncated`, `modal_in_front`).
public enum AXReadReport {
    public static func frameText(_ r: CGRect?) -> String {
        guard let r = r else { return "-" }
        return "\(ControlFilter.int(r.minX)),\(ControlFilter.int(r.minY)),\(ControlFilter.int(r.width)),\(ControlFilter.int(r.height))"
    }

    public static func yesNo(_ b: Bool) -> String { b ? "yes" : "no" }

    /// One control, one line: role, label, where the label came from, frame, actions (and the value, never a secure one's).
    public static func controlLine(_ c: Control) -> String {
        var s = "  #\(c.index) \(c.role) \"\(c.label)\" source=\(c.labelSource.rawValue) frame=\(frameText(c.frame)) actions=\(c.actions.joined(separator: ","))"
        if !c.isSecure, c.inTargetWindow, let v = c.value, !v.isEmpty { s += " value=\"\(v.prefix(40))\"" }
        if !c.enabled { s += " (disabled)" }
        if !c.window.isEmpty || !c.windowSubrole.isEmpty { s += " window=\"\(c.window)\"/\(c.windowSubrole)" }
        return s
    }

    public static func render(windows: [AXWindowSummary], nodesVisited: Int, kept: [Control], truncated: Bool, modalInFront: Bool) -> String {
        var lines: [String] = []
        if let target = windows.first(where: { $0.isTarget }) {
            lines.append("selected_window: title=\"\(target.info.title)\" frame=\(frameText(target.info.frame)) subrole=\(target.info.subrole)")
        } else {
            lines.append("selected_window: none")
        }
        lines.append("windows_seen: \(windows.count)")
        for w in windows {
            lines.append("  window: title=\"\(w.info.title)\" frame=\(frameText(w.info.frame)) subrole=\(w.info.subrole) modal=\(yesNo(w.info.isModal)) target=\(yesNo(w.isTarget)) nodes=\(w.nodesVisited)" + (w.examined ? "" : " (not examined: time budget used up)"))
        }
        lines.append("nodes_visited: \(nodesVisited)")
        lines.append("controls_kept: \(kept.count)")
        for c in kept { lines.append(controlLine(c)) }
        lines.append("truncated: \(yesNo(truncated))")
        lines.append("modal_in_front: \(yesNo(modalInFront))")
        if modalInFront { lines.append("modal_notice: \(FixScreenPipeline.modalNotice)") }
        return lines.joined(separator: "\n")
    }
}
