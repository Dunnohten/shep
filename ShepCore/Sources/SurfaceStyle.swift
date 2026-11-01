import CoreGraphics
import Foundation

/// Written for Shep.
/// How Shep's own surfaces (the cards, the home indicator) follow the person's accessibility settings. Pure: the views read the
/// settings, ask here, and draw what comes back.

public struct SurfaceStyle: Equatable {
    /// A solid colour instead of a material (Reduce Transparency).
    public var solid: Bool
    public var borderWidth: CGFloat
    /// 0 = the system's separator colour; above 0 = the label colour at this strength (Increase Contrast).
    public var borderStrength: Double
    /// Symbols are drawn at full strength rather than dimmed (Increase Contrast).
    public var fullStrengthSymbols: Bool

    public static func resolve(reduceTransparency: Bool, increaseContrast: Bool) -> SurfaceStyle {
        SurfaceStyle(solid: reduceTransparency,
                     borderWidth: increaseContrast ? 1 : 0.5,
                     borderStrength: increaseContrast ? 0.65 : 0,
                     fullStrengthSymbols: increaseContrast)
    }
}

/// The card's timing: ease-in-out fades of about a quarter second and a slide of a few points toward its place.
/// Reduce Motion keeps a plain, shorter fade and no slide. Never a spring or a bounce.
public struct CardTiming: Equatable {
    public var fadeIn: TimeInterval
    public var fadeOut: TimeInterval
    public var slide: CGFloat

    public static func resolve(reduceMotion: Bool) -> CardTiming {
        reduceMotion ? CardTiming(fadeIn: 0.15, fadeOut: 0.1, slide: 0) : CardTiming(fadeIn: 0.22, fadeOut: 0.15, slide: 6)
    }
}
