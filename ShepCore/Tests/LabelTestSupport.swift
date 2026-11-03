import CoreGraphics
import Foundation
@testable import ShepCore

/// A plain Accessibility node for the label tests (no AX calls).
struct LabelTestNode: AXNodeSource {
    var role: String
    var subrole: String = ""
    var title: String = ""
    var descriptionText: String = ""
    var help: String = ""
    var valueText: String?
    var frame: CGRect?
    var isEnabled: Bool = true
    var actions: [String] = []
    var identifier: String = ""
    var titleElementText: String = ""
    var kids: [LabelTestNode] = []
    func children() -> [LabelTestNode] { kids }
}

enum LabelFixture {
    static let windowFrame = CGRect(x: 100, y: 100, width: 600, height: 800)

    static func control(_ role: String, subrole: String = "", title: String = "", desc: String = "", help: String = "", id: String,
                        titleElement: String = "", enabled: Bool = true, size: CGSize = CGSize(width: 30, height: 24),
                        value: String? = nil, kids: [LabelTestNode] = [], row: Int) -> LabelTestNode {
        LabelTestNode(role: role, subrole: subrole, title: title, descriptionText: desc, help: help, valueText: value,
                      frame: CGRect(x: 300, y: 120 + CGFloat(row) * 30, width: size.width, height: size.height),
                      isEnabled: enabled, actions: ["AXPress"], identifier: id, titleElementText: titleElement, kids: kids)
    }

    static func text(_ s: String, row: Int) -> LabelTestNode {
        LabelTestNode(role: "AXStaticText", valueText: s, frame: CGRect(x: 120, y: 120 + CGFloat(row) * 30, width: 150, height: 20))
    }

    static func group(_ context: String, row: Int, _ c: LabelTestNode) -> LabelTestNode {
        LabelTestNode(role: "AXGroup", frame: CGRect(x: 110, y: 118 + CGFloat(row) * 30, width: 580, height: 28), kids: [text(context, row: row), c])
    }

    /// Ids that start with "u" are the controls with no real name (and enabled, visible); "l" are named; "s" must be skipped.
    static func tree() -> LabelTestNode {
        var rows: [LabelTestNode] = []
        var n = 0
        func add(_ context: String, _ make: (Int) -> LabelTestNode) { rows.append(group(context, row: n, make(n))); n += 1 }
        // unlabeled
        add("Playback") { control("AXButton", id: "btnPlay", row: $0) }
        add("Rename") { control("AXButton", title: "button", id: "u2", row: $0) }
        add("Picture") { control("AXButton", title: "icon.png", id: "u3", row: $0) }
        add("Close") { control("AXButton", title: "X", id: "u4", row: $0) }
        add("Remember") { control("AXCheckBox", id: "u5", row: $0) }
        add("More") { control("AXLink", id: "u6", row: $0) }
        add("Options") { control("AXMenuButton", id: "u7", row: $0) }
        add("Photo") { control("AXButton", desc: "image", id: "u8", row: $0) }
        add("Sort") { control("AXPopUpButton", id: "u9", row: $0) }
        add("Asset") { control("AXButton", title: "btn_close@2x", id: "u10", row: $0) }
        add("Wi-Fi") { control("AXCheckBox", subrole: "AXSwitch", id: "u11", row: $0) }
        add("Class") { control("AXButton", title: "NSButton", id: "u12", row: $0) }
        add("Help only") { control("AXButton", help: "Opens settings", id: "u13", row: $0) }
        add("Details") { control("AXDisclosureTriangle", id: "u14", row: $0) }
        // named
        add("File") { control("AXButton", title: "Save", id: "l1", row: $0) }
        add("File") { control("AXButton", title: "Cancel", id: "l2", row: $0) }
        add("Login") { control("AXCheckBox", title: "Remember me", id: "l3", row: $0) }
        add("Prefs") { control("AXButton", desc: "Settings", id: "l4", row: $0) }
        add("Audio") { control("AXButton", id: "l5", titleElement: "Volume", row: $0) }
        add("Legal") { control("AXLink", title: "Privacy Policy", id: "l6", row: $0) }
        add("List") { control("AXPopUpButton", id: "l7", value: "Sort by name", row: $0) }   // no title: its selected item names it
        add("Do") { control("AXMenuButton", title: "Actions", id: "l8", row: $0) }
        add("Net") { control("AXCheckBox", subrole: "AXSwitch", title: "Wi-Fi", id: "l9", row: $0) }
        add("Share") { control("AXButton", id: "l10", kids: [LabelTestNode(role: "AXStaticText", valueText: "Share", frame: CGRect(x: 301, y: 125, width: 20, height: 10))], row: $0) }
        add("Window") { control("AXButton", desc: "Close", id: "l11", row: $0) }
        add("Account") { control("AXButton", title: "Sign in", help: "Sign in to your account", id: "l12", row: $0) }
        // must be skipped
        add("Disabled") { control("AXButton", id: "s1", enabled: false, row: $0) }
        add("Hidden") { control("AXButton", id: "s2", size: .zero, row: $0) }
        add("Tiny") { control("AXButton", id: "s3", size: CGSize(width: 1, height: 1), row: $0) }
        // The window's own traffic lights, as the live window has them: unnamed buttons with window-chrome subroles (zoom is disabled).
        func chrome(_ subrole: String, x: CGFloat, enabled: Bool = true) -> LabelTestNode {
            LabelTestNode(role: "AXButton", subrole: subrole, frame: CGRect(x: windowFrame.minX + x, y: windowFrame.minY + 6, width: 14, height: 16),
                          isEnabled: enabled, actions: ["AXPress"])
        }
        let lights = [chrome("AXCloseButton", x: 8), chrome("AXMinimizeButton", x: 28), chrome("AXZoomButton", x: 48, enabled: false)]
        let window = LabelTestNode(role: "AXWindow", subrole: "AXStandardWindow", title: "Fixture", frame: windowFrame,
                                   kids: lights + [LabelTestNode(role: "AXGroup", frame: windowFrame, kids: rows)])
        return window
    }

    static func controls(limits: AXWalkLimits = .labelScan, root: LabelTestNode = tree(), clock: @escaping () -> TimeInterval = { 0 }) -> AXReadResult<LabelTestNode>? {
        AXTreeReader.read(windows: [AXWindowEntry(info: AXWindowInfo(title: "Fixture", subrole: "AXStandardWindow", frame: windowFrame, isMain: true, isFocused: true), root: root)],
                          targetFrame: windowFrame, targetTitle: "Fixture", limits: limits, clock: clock)
    }
}

/// A PNG header (signature and IHDR) for the given size, then `extra` filler bytes: enough for the size and byte checks, not a picture.
func fakePNG(width: Int, height: Int, extra: Int = 0) -> Data {
    func be(_ v: Int) -> [UInt8] { [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
    var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + be(13) + Array("IHDR".utf8) + be(width) + be(height)
    bytes += [UInt8](repeating: 0, count: max(0, extra))
    return Data(bytes)
}

/// An anchor that carries something to tell its control apart (text near it), for tests that build proposals by hand.
func storableAnchor(window: WindowSignature? = nil) -> LabelAnchor {
    LabelAnchor(role: "AXButton", nearbyText: ["Tools"], help: "Does it", path: "AXWindow>AXGroup[0]>AXButton[0]", siblingCount: 1, x: 0.3, y: 0.3,
                windowWidth: 600, windowHeight: 800, window: window)
}
