import Foundation

// Written for Shep.

/// A live run bound to an app (`--live-target`) stays bound from `target-ok` until `live: finished`. This is the one pure rule
/// the window tracker, the dock planner and the tab tint share: another app's window is not read, docked to or captured.
public enum LiveBinding {
    /// May the window of the app with this bundle id be read (Accessibility frame, title, title-bar items, a pixel row)?
    /// - target: the `--live-target` bundle id while a run is bound; nil when nothing is bound (everything may be read, as before).
    /// - ownBundleID: Shep's own bundle id; Shep's windows are not another app's.
    /// While bound only the target and Shep qualify, compared case-insensitively. An app with no bundle id never does.
    public static func mayRead(bundleID: String?, target: String?, ownBundleID: String?) -> Bool {
        guard let target = target else { return true }
        guard !ControlPolicy.normalized(bundleID ?? "").isEmpty else { return false }
        if LiveTargetGate.same(bundleID, target) { return true }
        if let own = ownBundleID, !ControlPolicy.normalized(own).isEmpty, LiveTargetGate.same(bundleID, own) { return true }
        return false
    }

    /// The click's hit test (`AXUIElementCopyElementAtPosition` on the system-wide element) answers with whatever app is under the point,
    /// which may be another app's window covering the target. The one thing read of a foreign element is its owner pid
    /// (`AXUIElementGetPid`); its window, role, title, actions, frame and identity are read only when that pid is the approved app's. The approved pid is the one the snapshot was read
    /// from (its bundle id was checked against the live target before the read), so during a live run this is the binding.
    public static func mayReadHit(hitPID: Int32?, approvedPID: Int32) -> Bool {
        guard let hitPID = hitPID else { return false }
        return hitPID == approvedPID
    }
}
