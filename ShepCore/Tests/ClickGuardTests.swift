import CoreGraphics
import XCTest
@testable import ShepCore

/// A fake Accessibility layer: the scene the app would read, set by each test.
final class FakeSceneReader: ClickSceneReading {
    var scene: LiveClickScene
    private(set) var reads = 0
    init(_ scene: LiveClickScene) { self.scene = scene }
    func scene(at point: CGPoint, for action: ProposedAction) -> LiveClickScene { reads += 1; return scene }
}

final class ClickGuardTests: XCTestCase {
    let windowFrame = CGRect(x: 100, y: 100, width: 600, height: 400)
    let button = Control(index: 1, role: "AXButton", title: "Save", window: "Doc", frame: CGRect(x: 300, y: 300, width: 80, height: 24), actions: ["AXPress"], pathID: "0/1")
    var approved: ApprovedWindow { ApprovedWindow(pid: 42, number: 7, frame: windowFrame, title: "Doc") }
    var action: ProposedAction { ProposedAction(control: button, kind: .clickPoint, bundleID: "com.example") }
    var point: CGPoint { CGPoint(x: button.frame!.midX, y: button.frame!.midY) }

    func goodScene() -> LiveClickScene {
        LiveClickScene(frontPID: 42, focusedWindowIsApproved: true, windowNumber: 7, windowFrame: windowFrame, windowTitle: "Doc",
                       hitPID: 42, hitInApprovedWindow: true,
                       expected: LiveExpectedElement(control: button, live: LiveTarget(role: "AXButton", title: "Save"), frame: button.frame),
                       hit: LiveHitElement(role: "AXButton", actions: ["AXPress"], frame: button.frame, isExpected: true))
    }
    func verdict(_ scene: LiveClickScene, action a: ProposedAction? = nil, window: ApprovedWindow? = nil) -> String? {
        ClickGuard.verify(window: window ?? approved, action: a ?? action, point: point, scene: scene)
    }

    func testUnchangedSceneAllowsTheClick() {
        XCTAssertNil(verdict(goodScene()))
    }

    func testCheckReadsTheSceneExactlyOnceAndDecidesInOneSynchronousCall() {
        let reader = FakeSceneReader(goodScene())
        XCTAssertNil(ClickGuard.check(window: approved, action: action, point: point, reader: reader))
        XCTAssertEqual(reader.reads, 1)
        reader.scene.windowNumber = 8
        XCTAssertNotNil(ClickGuard.check(window: approved, action: action, point: point, reader: reader))
        XCTAssertEqual(reader.reads, 2)
    }

    func testAnotherAppInFrontRefuses() {
        var s = goodScene(); s.frontPID = 43
        XCTAssertNotNil(verdict(s))
        s.frontPID = nil
        XCTAssertNotNil(verdict(s))
    }

    func testDifferentAXWindowRefuses() {
        var s = goodScene(); s.focusedWindowIsApproved = false
        XCTAssertNotNil(verdict(s))
    }

    func testDifferentWindowNumberRefusesAndUnknownIdentityFailsClosed() {
        var s = goodScene(); s.windowNumber = 9
        XCTAssertNotNil(verdict(s))
        s.windowNumber = nil
        XCTAssertNotNil(verdict(s))
        var unknown = approved; unknown.number = nil
        XCTAssertNotNil(verdict(goodScene(), window: unknown), "an approval with no window number cannot be checked, so it refuses")
    }

    func testWindowMovedOrResizedBeyondToleranceRefuses() {
        var s = goodScene(); s.windowFrame = windowFrame.offsetBy(dx: 1.5, dy: 0)
        XCTAssertNil(verdict(s), "within 2 pt")
        s.windowFrame = windowFrame.offsetBy(dx: 3, dy: 0)
        XCTAssertNotNil(verdict(s))
        s.windowFrame = CGRect(x: 100, y: 100, width: 640, height: 400)
        XCTAssertNotNil(verdict(s))
        s.windowFrame = nil
        XCTAssertNotNil(verdict(s))
    }

    func testWindowTitleChangeRefusesButWhitespaceAndCaseDoNot() {
        var s = goodScene(); s.windowTitle = "  doc "
        XCTAssertNil(verdict(s))
        s.windowTitle = "Delete everything?"
        XCTAssertNotNil(verdict(s))
    }

    func testSameAppDialogOrCoveringWindowRefuses() {
        var s = goodScene(); s.hitInApprovedWindow = false
        XCTAssertNotNil(verdict(s))
        s = goodScene(); s.hitPID = 99
        XCTAssertNotNil(verdict(s))
        s = goodScene(); s.hitPID = nil
        XCTAssertNotNil(verdict(s))
    }

    func testPointOutsideTheApprovedWindowRefuses() {
        var small = approved; small.frame = CGRect(x: 100, y: 100, width: 100, height: 100)
        var s = goodScene(); s.windowFrame = small.frame
        XCTAssertNotNil(verdict(s, window: small))
    }

    func testElementThatDisappearedRefusesForAListedControl() {
        var s = goodScene(); s.expected = nil
        XCTAssertNotNil(verdict(s))
    }

    func testDifferentElementUnderThePointRefuses() {
        var s = goodScene()
        var other = button; other.pathID = "0/9"
        s.expected = LiveExpectedElement(control: other, live: LiveTarget(role: "AXButton", title: "Save"), frame: button.frame)
        XCTAssertNotNil(verdict(s), "a different listed control at the spot")
        s = goodScene(); s.hit = LiveHitElement(role: "AXButton", actions: ["AXPress"], frame: button.frame)
        XCTAssertNotNil(verdict(s), "the hit element is unrelated to the control")
    }

    func testReusedElementWithAnotherRoleLabelOrStateRefuses() {
        for live in [LiveTarget(role: "AXCheckBox", title: "Save"), LiveTarget(role: "AXButton", title: "Erase"),
                     LiveTarget(role: "AXButton", title: "Save", enabled: false), LiveTarget(role: "AXButton", subrole: "AXSecureTextField", title: "Save"),
                     LiveTarget(role: "AXButton", title: "Save", inSnapshotWindow: false)] {
            var s = goodScene(); s.expected?.live = live
            XCTAssertNotNil(verdict(s), "\(live)")
        }
    }

    func testElementThatMovedUnderTheApprovedPointRefuses() {
        var s = goodScene()
        s.expected?.frame = button.frame!.offsetBy(dx: 40, dy: 0)
        XCTAssertNotNil(verdict(s))
        s.expected?.frame = nil
        XCTAssertNotNil(verdict(s), "a listed frame that cannot be read again fails closed")
        s.expected?.frame = button.frame!.offsetBy(dx: 1, dy: 1)
        XCTAssertNil(verdict(s), "within tolerance")
    }

    // MARK: vision proposals

    /// The identity a vision click is approved with (updated for P1-1: a vision click without one is refused).
    func gearIdentity(role: String = "AXButton") -> HitIdentity {
        HitIdentity.resolved(role: role, title: "Gear", frame: button.frame!)
    }
    func visionAction(frame: CGRect? = nil) -> ProposedAction {
        var vision = Control(index: 2, role: "AXButton", title: "Gear", frame: frame ?? button.frame, pathID: "v1")
        vision.fromVision = true
        return ProposedAction(control: vision, kind: .clickPoint, bundleID: "com.example", hitIdentity: gearIdentity())
    }
    /// Nothing listed at the spot; the hit test finds `hit`.
    func visionScene(hit: LiveHitElement?) -> LiveClickScene {
        var s = goodScene(); s.expected = nil; s.hit = hit
        return s
    }

    func testControlFoundOnTheScreenshotNeedsTheWindowChecksAndAConcreteHitElement() {
        let a = visionAction()
        let small = LiveHitElement(role: "AXButton", actions: ["AXPress"], frame: button.frame, identity: gearIdentity())
        XCTAssertNil(verdict(visionScene(hit: small), action: a), "a small actionable element that matches the box")
        var s = visionScene(hit: small)
        s.focusedWindowIsApproved = false
        XCTAssertNotNil(verdict(s, action: a))
        s = goodScene()   // an AX control now sits under a vision point: it must still be the same one it was read as
        s.expected?.live = LiveTarget(role: "AXButton", title: "Delete account")
        XCTAssertNotNil(verdict(s, action: a))
    }

    func testVisionProposalWithAnEmptySnapshotAndNoReadableHitIsRefused() {
        let why = verdict(visionScene(hit: nil), action: visionAction())
        XCTAssertEqual(why, ClickGuard.cannotIdentifyMessage)
    }

    func testVisionProposalWhoseHitIsABigContainerIsRefused() {
        let a = visionAction()
        let big = windowFrame
        XCTAssertNotNil(verdict(visionScene(hit: LiveHitElement(role: "AXGroup", frame: big)), action: a))
        XCTAssertNotNil(verdict(visionScene(hit: LiveHitElement(role: "AXScrollArea", frame: big)), action: a))
        XCTAssertNotNil(verdict(visionScene(hit: LiveHitElement(role: "AXWebArea", frame: big)), action: a))
        // A container is never a target, even a small one that claims to be pressable.
        XCTAssertNotNil(verdict(visionScene(hit: LiveHitElement(role: "AXGroup", actions: ["AXPress"], frame: button.frame)), action: a))
        // An actionable element far larger than the box (over 9x its area).
        let huge = CGRect(x: 250, y: 250, width: 400, height: 150)
        XCTAssertNotNil(verdict(visionScene(hit: LiveHitElement(role: "AXButton", actions: ["AXPress"], frame: huge)), action: a))
    }

    func testVisionProposalHitMustBeActionableOverlapTheBoxAndContainThePoint() {
        let a = visionAction()
        XCTAssertNotNil(verdict(visionScene(hit: LiveHitElement(role: "AXStaticText", frame: button.frame)), action: a), "text is not actionable")
        XCTAssertNotNil(verdict(visionScene(hit: LiveHitElement(role: "AXButton", frame: nil)), action: a), "no readable frame")
        let away = CGRect(x: 320, y: 360, width: 80, height: 24)
        XCTAssertNotNil(verdict(visionScene(hit: LiveHitElement(role: "AXButton", actions: ["AXPress"], frame: away)), action: a), "does not contain the point")
        let imageHit = LiveHitElement(role: "AXImage", actions: ["AXPress"], frame: button.frame!.insetBy(dx: -4, dy: -4),
                                      identity: HitIdentity.resolved(role: "AXImage", title: "Gear", frame: button.frame!.insetBy(dx: -4, dy: -4)))
        var imageAction = visionAction()
        imageAction.hitIdentity = imageHit.identity
        XCTAssertNil(verdict(visionScene(hit: imageHit), action: imageAction),
                     "a pressable non-container slightly larger than the box")
    }

    // MARK: click identity (listed controls)

    func testSameWindowReplacementControlAtTheSameSpotRefuses() {
        var s = goodScene()
        s.hit = LiveHitElement(role: "AXButton", actions: ["AXPress"], frame: button.frame)   // another button, same place and look
        XCTAssertNotNil(verdict(s))
    }

    func testMovedChildWithTheContainerStillUnderThePointRefuses() {
        var s = goodScene()
        s.expected?.frame = button.frame!.offsetBy(dx: 60, dy: 0)
        s.hit = LiveHitElement(role: "AXGroup", frame: windowFrame, isAncestorOfExpected: true)
        XCTAssertNotNil(verdict(s), "the child moved away and its container answers the hit test")
        s.expected?.frame = button.frame   // even when the child still reports its old frame
        XCTAssertNotNil(verdict(s), "a container hit is never the approved control")
    }

    func testHitOnAGenericParentOrContainerRefuses() {
        for role in ["AXGroup", "AXToolbar", "AXScrollArea", "AXButton"] {
            var s = goodScene()
            s.hit = LiveHitElement(role: role, frame: windowFrame, isAncestorOfExpected: true)
            XCTAssertNotNil(verdict(s), role)
        }
    }

    func testHitOnADecorativeChildOfTheApprovedButtonIsAllowed() {
        for role in ["AXImage", "AXStaticText"] {
            var s = goodScene()
            s.hit = LiveHitElement(role: role, frame: button.frame!.insetBy(dx: 20, dy: 4), isDescendantOfExpected: true)
            XCTAssertNil(verdict(s), role)
        }
    }

    func testHitOnADifferentActionableDescendantRefuses() {
        var s = goodScene()
        s.hit = LiveHitElement(role: "AXButton", actions: ["AXPress"], frame: button.frame!.insetBy(dx: 30, dy: 4), isDescendantOfExpected: true)
        XCTAssertNotNil(verdict(s))
        s.hit = LiveHitElement(role: "AXImage", actions: ["AXPress"], frame: button.frame!.insetBy(dx: 30, dy: 4), isDescendantOfExpected: true)
        XCTAssertNotNil(verdict(s), "a pressable image is a control of its own")
        s.hit = LiveHitElement(role: "AXCheckBox", frame: button.frame!.insetBy(dx: 30, dy: 4), isDescendantOfExpected: true)
        XCTAssertNotNil(verdict(s))
    }

    func testMissingHitElementRefusesAndAHitFrameThatMovedRefuses() {
        var s = goodScene(); s.hit = nil
        XCTAssertNotNil(verdict(s))
        s = goodScene(); s.hit?.frame = button.frame!.offsetBy(dx: 40, dy: 0)
        XCTAssertNotNil(verdict(s), "the hit element is the approved one but not where it was listed")
        s = goodScene(); s.hit?.frame = nil
        XCTAssertNotNil(verdict(s))
    }
}
