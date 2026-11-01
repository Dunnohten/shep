import AppKit
import ShepCore

/// The dog crossing the screen: a small transparent click-through panel that follows the travel path while its page
/// (the same dog page as the dock) stretches and squashes the head along its velocity. Written for Shep.
/// The panel only exists on screen for the ~1 s of a travel; the page's 60 fps loop runs only then.
@MainActor
final class TravelPanel: NSPanel {
    /// Room around the dog box for the stretch: 96 x 76, the dog box (40 x 28) centred.
    static let size = CGSize(width: 96, height: 76)

    let dog = DogWebView()
    /// Where the dog's centre is now (Cocoa coordinates); valid while flying and after the last flight.
    private(set) var center: CGPoint?
    private(set) var isFlying = false
    private var timer: Timer?
    private var samples: [TravelSample] = []
    private var started: TimeInterval = 0
    private var finish: (() -> Void)?

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // Decoration for about a second: hidden from VoiceOver, whose cursor would otherwise be pulled into the window as it
    // appears and sent back to the app (which it then reads again) when it goes. The dock carries Shep's accessibility.
    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityChildren() -> [Any]? { [] }

    init() {
        let size = NSSize(width: Self.size.width, height: Self.size.height)
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isFloatingPanel = true
        ignoresMouseEvents = true   // the traveller never takes a click
        sharingType = ScreenPrivacy.sharingType
        dog.frame = NSRect(origin: .zero, size: size)
        dog.autoresizingMask = [.width, .height]
        contentView = dog
        dog.setAccessibilityElement(false)
        let box = DockGeometry.dogSize
        dog.setDogBox(x: Int((size.width - box.width) / 2), y: Int((size.height - box.height) / 2), width: Int(box.width), height: Int(box.height))
        dog.setActive(false)
    }

    func setTheme(_ name: String) { dog.setTheme(name) }
    func setBar(hex: String) { dog.setBar(hex: hex) }

    private func move(toCenter p: CGPoint) {
        center = p
        setFrameOrigin(NSPoint(x: (p.x - Self.size.width / 2).rounded(), y: (p.y - Self.size.height / 2).rounded()))
    }

    /// Flies along `samples` (from `TravelPath.samples`). `completion` runs once, at the last sample; a new flight or `cancel()`
    /// before that drops it.
    func fly(_ samples: [TravelSample], completion: @escaping () -> Void) {
        cancel()
        guard let first = samples.first, samples.count >= 2 else { completion(); return }
        self.samples = samples
        finish = completion
        isFlying = true
        move(toCenter: first.position)
        dog.setActive(true)
        dog.travel(samples)
        // Two frames later, so the page has drawn the first sample (invisible) and the last flight's stale frame never flashes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isFlying else { return }
                self.orderFrontRegardless()
            }
        }
        started = ProcessInfo.processInfo.systemUptime
        let t = Timer(timeInterval: 1.0 / Double(LifecycleFramePolicy.travelFPS), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        if let p = TravelPath.position(in: samples, at: elapsed) { move(toCenter: p) }
        if let last = samples.last, elapsed >= last.time { land() }
    }

    private func land() {
        let done = finish
        finish = nil
        stop()
        done?()
    }

    /// Stops a flight in place (the dog stays where it is, hidden) without calling the completion.
    func cancel() {
        finish = nil
        stop()
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        isFlying = false
        dog.endTravel()
        dog.setActive(false)
        orderOut(nil)
    }
}
