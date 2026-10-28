import Foundation
import ShepCore

/// `Shep --fix-screen-once <png>`: runs the Fix-this-screen pipeline once on a screenshot file and prints the result
/// and timing. No capture and no UI: the provider and the pipeline only. When SHEP_AX_PID (a pid) or SHEP_WINDOW_OWNER (a bundle
/// identifier) names the app the screenshot came from, its controls are read through Accessibility for the window given by
/// SHEP_WINDOW_FRAME / SHEP_WINDOW_TITLE and handed to the pipeline, as the app's own flow does. Without one, no app controls
/// are passed and the report says so. Cloud providers also need SHEP_ALLOW_CLOUD=1.
enum FixScreenCLI {
    /// The real window title when the caller captured a live window (SHEP_WINDOW_TITLE); a bare PNG is just "image".
    static func windowName(_ environment: [String: String]) -> String {
        let t = (environment["SHEP_WINDOW_TITLE"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "image" : String(t.prefix(120))
    }

    static func run(path: String, environment: [String: String]) async -> Int32 {
        guard let png = FileManager.default.contents(atPath: (path as NSString).expandingTildeInPath),
              let size = ImageIOPreparer.pixelSize(of: png) else {
            print("fix-screen-once: cannot read an image at \(path)")
            return 2
        }
        let config = ProviderConfig.from(environment: environment, home: NSHomeDirectory())
        let made: (provider: any VisionProvider, selection: ProviderSelection)
        do { made = try ProviderFactory.make(config: config, environment: environment) }
        catch {
            print("fix-screen-once: \(error.localizedDescription)")
            return 3
        }
        if let note = made.selection.note { print("note: \(note)") }
        // Where the pixels sit on screen: the exact window frame when the caller knows it (scripts/e2e-glimmer.sh does),
        // else a stated scale, else a guess. A guess is wrong on scaled displays (1.75 is common), so it is said out loud.
        let frame: CGRect
        if let given = environment["SHEP_WINDOW_FRAME"].flatMap(CoordinateSpace.parseFrame) {
            frame = given
        } else if let s = environment["SHEP_IMAGE_SCALE"].flatMap(Double.init), s > 0 {
            frame = CoordinateSpace.assumedFrame(imageSize: size, scale: CGFloat(s))
        } else {
            let guess: CGFloat = size.width >= 2000 ? 2 : 1
            print("note: window frame unknown; assuming \(guess)x pixels per point (set SHEP_WINDOW_FRAME=x,y,w,h or SHEP_IMAGE_SCALE)")
            frame = CoordinateSpace.assumedFrame(imageSize: size, scale: guess)
        }
        let geometry = CaptureGeometry(windowFrame: frame, imageSize: size, scale: Double(size.width / max(frame.width, 1)))
        let allowCloud = environment["SHEP_ALLOW_CLOUD"] == "1"
        // SHEP_REQUEST is what the person would have asked (scripts/e2e-glimmer.sh --request); empty means "no request".
        let request = (environment["SHEP_REQUEST"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let givenFrame = environment["SHEP_WINDOW_FRAME"].flatMap { CoordinateSpace.parseFrame($0) }
        let started = Date()
        let picker = ProviderFactory.makePicker(config: config, environment: environment)
        let pipeline = FixScreenPipeline(provider: made.provider, picker: picker, cloudAllowed: { allowCloud })
        // Who the image belongs to is decided first (CLITarget): a named app is resolved through the system and checked against
        // the capture policy, a failed lookup or read refuses, and a bare image is an unattested file. The provider is only
        // reached after that.
        let outcome = await CLIFixScreen.run(environment: environment, lookup: AXCommandLine.SystemLookup(), pipeline: pipeline) { resolved in
            var axControls: [Control] = []
            var modalInFront = false
            if let pid = resolved.pid {
                guard let ax = AXCommandLine.fixScreenControls(pid: pid, environment: environment, frame: givenFrame) else { return nil }
                print(ax.note)
                axControls = ax.controls
                modalInFront = ax.modalInFront
            } else {
                print("note: no SHEP_AX_PID or SHEP_WINDOW_OWNER, so the app's own controls were not read: every box will look like it is missing from the Accessibility list")
            }
            return VisionInput(png: png, geometry: geometry, axControls: axControls, bundleID: resolved.bundleID,
                               windowTitle: windowName(environment), request: request.isEmpty ? nil : String(request.prefix(300)),
                               modalInFront: modalInFront)
        }
        if let notice = outcome.notice { print(notice) }
        if let why = outcome.refusal {
            print("fix-screen-once: refused: \(why)")
            return 6
        }
        guard let result = outcome.result else { return 1 }
        print(FixScreenReport.render(result, seconds: Date().timeIntervalSince(started)))
        if case .ok = result.status { return 0 }
        return 1
    }
}
