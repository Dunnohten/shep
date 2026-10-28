import AppKit
import CoreGraphics
import ImageIO
import ShepCore

// Written for Shep.

/// Finds the colour of the target window's title bar so the tab can match it.
/// With Screen Recording allowed it reads one pixel row of the window (via the same window-only capture "Fix this
/// screen" uses); otherwise the tab falls back to a fixed light or dark grey, which the owner can override with the
/// `shep.tab.fillLight` / `shep.tab.fillDark` defaults ("#RRGGBB").
enum TabTint {
    /// Distance of the sampled row from the window's top edge, in points: below the rounded corners, above the title text.
    static let rowOffset: CGFloat = 4

    /// Fallback fill for the current appearance; honours the owner's override when it is a valid hex colour.
    static func fallbackHex(dark: Bool) -> String {
        let key = dark ? "shep.tab.fillDark" : "shep.tab.fillLight"
        if let custom = UserDefaults.standard.string(forKey: key), TabAppearance.rgb(hex: custom) != nil { return custom.uppercased() }
        return TabAppearance.fallbackFillHex(dark: dark)
    }

    /// The system is in dark mode (Shep is an accessory app, so its appearance follows the system's).
    @MainActor static var isDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// "#RRGGBB" sampled from the window's title bar, or nil when Screen Recording is off, the app is on a never-capture
    /// list (the capture primitive refuses it too) or the capture failed. The caller then uses the appearance fallback.
    /// `liveTarget`: while a live run is bound to an app, any other app is refused here too (not even one pixel row is captured).
    static func sampleBarColor(pid: pid_t, nearFrame frame: CGRect?, liveTarget: String? = nil) async -> String? {
        guard TabTintPolicy.source(bundleID: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
                                   screenRecordingAllowed: CGPreflightScreenCaptureAccess(), liveTarget: liveTarget) == .sample else { return nil }
        guard case .success(let shot) = await ScreenCapture.captureWindow(pid: pid, nearFrame: frame) else { return nil }
        return barColor(png: shot.png, windowWidthPoints: shot.geometry.windowFrame.width)
    }

    static func barColor(png: Data, windowWidthPoints: CGFloat) -> String? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil), image.width > 0, image.height > 0,
              windowWidthPoints > 0 else { return nil }
        let scale = CGFloat(image.width) / windowWidthPoints
        let y = min(max(Int((rowOffset * scale).rounded()), 0), image.height - 1)
        guard let row = image.cropping(to: CGRect(x: 0, y: y, width: image.width, height: 1)),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var bytes = [UInt8](repeating: 0, count: image.width * 4)
        let drawn: Bool = bytes.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: image.width, height: 1, bitsPerComponent: 8,
                                      bytesPerRow: image.width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(row, in: CGRect(x: 0, y: 0, width: image.width, height: 1))
            return true
        }
        guard drawn else { return nil }
        return TabAppearance.barColor(fromRow: bytes, width: image.width)
    }
}
