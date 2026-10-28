import CoreGraphics
import Foundation

/// Pure filtering, ranking and serialization of AX controls. No AppKit, no Accessibility calls.
public enum ControlFilter {
    /// Int() traps on huge values; frames come from other apps.
    static func int(_ v: CGFloat) -> Int { Int(max(-1e9, min(1e9, v))) }

    /// Roles worth offering. Secure text fields are never listed at all.
    public static let actionableRoles: Set<String> = [
        "AXButton", "AXMenuItem", "AXMenuBarItem", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton",
        "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXTab", "AXLink", "AXSlider",
    ]
    public static let pressActions: Set<String> = ["AXPress", "AXConfirm", "AXPick"]

    public static func isUseful(_ c: Control) -> Bool {
        if c.isSecure { return false }
        guard actionableRoles.contains(c.role) || c.actions.contains(where: { pressActions.contains($0) }) else { return false }
        if let f = c.frame {
            guard f.minX.isFinite, f.minY.isFinite, f.width.isFinite, f.height.isFinite, f.width >= 2, f.height >= 2 else { return false }
        }
        return true
    }

    /// Useful controls only, de-duplicated (same role, label and frame), ranked, then numbered 1...n.
    /// - Parameters:
    ///   - limit: cap on the list.
    ///   - window: when set, controls fully outside it are dropped (AX sometimes reports off-window children).
    public static func prepare(_ controls: [Control], limit: Int = 60, window: CGRect? = nil) -> [Control] {
        var seen = Set<String>()
        var kept: [Control] = []
        for c in controls where isUseful(c) {
            if let w = window, let f = c.frame, !w.intersects(f) { continue }
            let key = "\(c.role)|\(c.label)|\(c.frame.map { "\(int($0.minX)),\(int($0.minY)),\(int($0.width)),\(int($0.height))" } ?? "-")"
            if seen.contains(key) { continue }
            seen.insert(key)
            kept.append(c)
        }
        let order = rank(kept)
        return order.prefix(limit).enumerated().map { kept[$1].renumbered($0 + 1) }
    }

    /// Indexes of `controls` best first: enabled before disabled, labelled before unlabelled, pressable before others,
    /// then reading order. Deterministic (ties broken by original position).
    public static func rank(_ controls: [Control]) -> [Int] {
        func score(_ c: Control) -> Int {
            var s = 0
            if c.enabled { s += 4 }
            if !c.label.isEmpty { s += 2 }
            if c.actions.contains(where: { pressActions.contains($0) }) { s += 1 }
            return s
        }
        let reading = VisionRepair.readingOrder(controls.map { $0.frame ?? .zero })
        var position: [Int: Int] = [:]
        for (p, i) in reading.enumerated() { position[i] = p }
        return controls.indices.sorted { a, b in
            let sa = score(controls[a]), sb = score(controls[b])
            if sa != sb { return sa > sb }
            return (position[a] ?? a, a) < (position[b] ?? b, b)
        }
    }

    /// Compact JSON for a model prompt: no secure values, no values of controls outside the target window, values cut to 40
    /// characters, frames as integers.
    public static func serialize(_ controls: [Control]) -> String {
        let rows: [[String: Any]] = controls.map { c in
            var row: [String: Any] = ["id": c.index, "role": c.kind, "label": c.label, "enabled": c.enabled]
            if let f = c.frame { row["frame"] = [int(f.minX), int(f.minY), int(f.width), int(f.height)] }
            if !c.isSecure, c.inTargetWindow, let v = c.value, !v.isEmpty { row["value"] = String(v.prefix(40)) }
            return row
        }
        guard let data = try? JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys]) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }
}
