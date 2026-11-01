import Foundation

/// Written for Shep.
/// What the home indicator shows for a `HouseMode`: two SF Symbols (the paw, then a small status mark), the paw's strength,
/// and the words VoiceOver reads. Plain data; the AppKit view only draws it.
public struct HomeIndicatorState: Equatable {
    public var pawSymbol: String
    public var statusSymbol: String
    /// 1 = full white. The paw is filled when Shep is home and an outline when Shep is out, so the two read apart without colour.
    public var pawAlpha: Double
    public var accessibilityValue: String

    public static func state(for mode: HouseMode) -> HomeIndicatorState {
        switch mode {
        case .asleep:
            return HomeIndicatorState(pawSymbol: "pawprint.fill", statusSymbol: "moon.zzz.fill", pawAlpha: 0.7, accessibilityValue: "Shep is asleep")
        case .waking:
            return HomeIndicatorState(pawSymbol: "pawprint.fill", statusSymbol: "sun.max.fill", pawAlpha: 1, accessibilityValue: "Shep is waking up")
        case .away:
            return HomeIndicatorState(pawSymbol: "pawprint", statusSymbol: "arrow.up.right", pawAlpha: 0.7, accessibilityValue: "Shep is out")
        case .entering:
            return HomeIndicatorState(pawSymbol: "pawprint.fill", statusSymbol: "moon.fill", pawAlpha: 1, accessibilityValue: "Shep is heading to sleep")
        }
    }

    /// A change of state cross-fades; ease-in-out, never a bounce. Reduce Motion keeps it a plain, shorter fade.
    public func fadeSeconds(reduceMotion: Bool) -> Double { reduceMotion ? 0.15 : 0.25 }
}
