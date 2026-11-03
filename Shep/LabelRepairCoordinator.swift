import AppKit
import ApplicationServices
import ImageIO
import ShepCore
import UniformTypeIdentifiers

/// "Fix this screen" in its label-repair form: scan the front window for controls with no real name, ask the local model for names,
/// show ONE approval card with every proposal, and store only what the person accepts. Also "clear labels for this app".
/// The store is written only from `LabelApproval.resolve` / `confirmClear` results, which only the card's answers can produce.
@MainActor
final class LabelRepairCoordinator {
    private let overlay: OverlayController
    private let store: LabelOverlayStore
    private let environment: () -> [String: String]
    typealias NamerMaker = ([String: String]) throws -> (namer: any LabelNaming, selection: LabelProviderSelection)
    private let makeNamer: NamerMaker
    private var running = false

    init(overlay: OverlayController, store: LabelOverlayStore, environment: @escaping () -> [String: String],
         makeNamer: @escaping NamerMaker = { env in try LabelNamerFactory.make(environment: env, home: NSHomeDirectory()) }) {
        self.overlay = overlay; self.store = store; self.environment = environment; self.makeNamer = makeNamer
    }

    /// The app both "fix this screen" and "clear labels" act on: the one owning the window the dog is on, else the front app; never Shep.
    private func targetApp() -> NSRunningApplication? {
        let front = NSWorkspace.shared.frontmostApplication
        guard let pid = LabelTargetApp.choose(dogPID: overlay.observedWindow?.pid, frontPID: front?.processIdentifier,
                                              ownPID: ProcessInfo.processInfo.processIdentifier) else { return nil }
        return front?.processIdentifier == pid ? front : NSRunningApplication(processIdentifier: pid)
    }

    // MARK: fix this screen

    func fixScreen() async {
        guard !running else { overlay.say("Still working on the last one."); return }
        running = true
        defer { running = false; overlay.setState(.idle) }

        guard AXIsProcessTrusted() else { overlay.say("I need Accessibility permission first. Open Shep Setup from the menu."); return }
        guard let app = targetApp() else {
            overlay.say("Bring the window you want fixed to the front first."); return
        }
        let pid = app.processIdentifier
        let bundleID = app.bundleIdentifier ?? ""
        guard ControlPolicy.mayCapture(bundleID: bundleID) else { overlay.say("Shep never looks at this app's window."); return }
        overlay.setState(.thinking)

        // The window the dog is on (VoiceOver's focus first, then the keyboard), not whichever window the app calls main.
        let target = AXReader.focusedReadTarget(pid: pid)
        let read: AXSnapshot? = await Task.detached {
            AXReader.read(pid: pid, target: target, limits: .labelScan)
        }.value
        if Task.isCancelled { return }
        guard let snapshot = read, snapshot.bundleID == bundleID else { overlay.say("I couldn't read that window's controls."); return }
        let scan = LabelScanner.scan(controls: snapshot.controls, windowFrame: snapshot.windowFrame, truncated: snapshot.truncated || snapshot.depthCut)
        let kinds = scan.candidates.map { $0.kind }
        let skipped = scan.unstableSkipped
        if scan.partial {
            // A cap ended the walk: a twin of any control may be in the part not read, so nothing is offered or sent to the model.
            overlay.say(LabelSummary.tooLarge(flagged: scan.entries.filter { $0.flagged }.count), milliseconds: 6000)
            return
        }
        if scan.candidates.isEmpty {
            overlay.say(skipped > 0 ? LabelSummary.noneTellApart(skipped: skipped, partial: scan.partial) : LabelSummary.noneFound(partial: scan.partial),
                        milliseconds: 6000)
            return
        }

        let env = environment()
        // Muse Glimmer on this Mac unless the person asked for Meta's cloud Muse Spark (SHEP_LABEL_PROVIDER=meta) and a key is set.
        let made: (namer: any LabelNaming, selection: LabelProviderSelection)
        do { made = try makeNamer(env) }
        catch {
            overlay.say(LabelSummary.modelUnavailable(found: scan.candidates.count, kinds: kinds, partial: scan.partial, skipped: skipped), milliseconds: 7000)
            return
        }
        if let note = made.selection.note { print("[shep] \(note)") }
        var inputs = scan.candidates.map { LabelModelInput(candidate: $0) }
        let withCrops = LabelCrop.enabled(environment: env, screenRecordingGranted: CGPreflightScreenCaptureAccess())
        let cloudNote = made.selection.kind == .meta ? (withCrops ? " That includes small pictures of the controls." : "") : ""
        overlay.say("Found \(scan.candidates.count) unlabeled. Asking \(made.selection.destination).\(cloudNote)", milliseconds: 3000)
        if withCrops {
            inputs = await attachCrops(inputs, candidates: scan.candidates, pid: pid, windowFrame: snapshot.windowFrame)
        }
        let suggestions: [LabelSuggestion]
        do { suggestions = try await made.namer.nameLabels(LabelJob(inputs: inputs)) }
        catch {
            overlay.say(LabelSummary.modelUnavailable(found: scan.candidates.count, kinds: kinds, partial: scan.partial, skipped: skipped), milliseconds: 7000)
            return
        }
        if Task.isCancelled { return }
        let proposals = LabelProposals.make(candidates: scan.candidates, suggestions: suggestions, windowSize: snapshot.windowFrame.size)
        if proposals.isEmpty {
            overlay.say(LabelSummary.noUsableLabels(found: scan.candidates.count, kinds: kinds, partial: scan.partial, skipped: skipped), milliseconds: 7000)
            return
        }
        // The person went to another app while the model worked: nothing is shown or stored for a window that is no longer in front.
        if targetApp()?.processIdentifier != pid {
            overlay.say("The window changed while I worked, so I labeled nothing.", milliseconds: 5000)
            return
        }

        let appName = snapshot.appName
        let (review, answer) = await runCard(LabelReview(bundleID: bundleID, appName: appName, proposals: proposals))
        var labeled = 0
        if let approved = LabelApproval.resolve(review, answer: answer) {
            do {
                let result = try store.apply(approved)
                labeled = result.stored
                if let backup = result.corruptBackup { print("[shep] the label file could not be read; a copy was kept at \(backup.lastPathComponent)") }
            } catch {
                overlay.say("I couldn't save the labels, so nothing was stored.", milliseconds: 6000)
                return
            }
        }
        overlay.say(LabelSummary.afterApproval(found: scan.candidates.count, labeled: labeled, kinds: kinds, partial: scan.partial, skipped: skipped), milliseconds: 7000)
    }

    // MARK: the card

    private enum Screen {
        case main
        case picker(LabelPick, Int)
    }

    /// One card, shown again as the person rejects or edits items. Escape or Cancel ends it with no answer that approves anything.
    private func runCard(_ initial: LabelReview) async -> (LabelReview, LabelCardAnswer?) {
        var review = initial
        var screen = Screen.main
        while !Task.isCancelled {
            let card: LabelCard
            switch screen {
            case .main: card = LabelCardBuilder.main(review)
            case .picker(let mode, let page): card = LabelCardBuilder.picker(review, mode: mode, page: page)
            }
            let id = await overlay.ask(card.text, choices: card.choices.map { choice in (id: choice.id, label: choice.label) }, title: card.title)
            guard let action = LabelCardAction.parse(id) else { return (review, nil) }
            switch LabelCardFlow.apply(action, to: &review) {
            case .finish(let answer): return (review, answer)
            case .stay:
                if review.activeProposals.isEmpty { screen = .main }
            case .main: screen = .main
            case .picker(let mode): screen = .picker(mode, 0)
            case .page(let n):
                if case .picker(let mode, _) = screen { screen = .picker(mode, n) }
            case .needsText(let target):
                let typed = await overlay.askText(prompt: "New label for control \(target)")
                if let typed = typed, !review.edit(target, to: typed) {
                    overlay.say("That is not a usable label. Use one to four words that say what the control does.", milliseconds: 4000)
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                }
                screen = .main
            }
        }
        return (review, nil)
    }

    // MARK: clear

    func clearLabels() async {
        guard !running else { overlay.say("Still working on the last one."); return }
        running = true
        defer { running = false }
        guard let app = targetApp(), let bundleID = app.bundleIdentifier else {
            overlay.say("Bring the app whose labels you want cleared to the front first."); return
        }
        let appName = app.localizedName ?? "this app"
        let count = store.count(bundleID: bundleID)
        if count == 0 { overlay.say(LabelSummary.cleared(count: 0, appName: appName)); return }
        let choice = await overlay.ask(LabelSummary.clearPrompt(count: count, appName: appName),
                                       choices: [(id: "clear", label: "Clear labels"), (id: "keep", label: "Keep them")],
                                       title: "Shep wants to clear its labels for \(appName)")
        let answer: ClearAnswer? = choice == "clear" ? .confirm : (choice == "keep" ? .keep : nil)
        guard let approved = LabelApproval.confirmClear(bundleID: bundleID, answer: answer) else {
            overlay.say(LabelSummary.clearKept(appName: appName)); return
        }
        do {
            let removed = try store.clear(approved)
            overlay.say(LabelSummary.cleared(count: removed, appName: appName), milliseconds: 5000)
        } catch {
            overlay.say("I couldn't clear the labels.", milliseconds: 5000)
        }
    }

    // MARK: optional crops (off unless SHEP_LABEL_IMAGES is set and Screen Recording is allowed)

    private func attachCrops(_ inputs: [LabelModelInput], candidates: [LabelCandidate], pid: pid_t, windowFrame: CGRect) async -> [LabelModelInput] {
        guard case .success(let shot) = await ScreenCapture.captureWindow(pid: pid, nearFrame: windowFrame),
              let source = CGImageSourceCreateWithData(shot.png as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return inputs }
        let size = CGSize(width: image.width, height: image.height)
        let scale = CGFloat(shot.geometry.scaleX)
        var out = inputs
        var budget = LabelCrop.ByteBudget()
        for (i, c) in candidates.enumerated() where i < out.count {
            guard let rect = LabelCrop.pixelRect(relative: c.relativeFrame, scale: scale, imageSize: size),
                  let piece = image.cropping(to: rect), let small = Self.fitted(piece), let png = Self.encodePNG(small) else { continue }
            // The first crop that would push the request past its byte cap, and every later one, is dropped.
            guard budget.admit(bytes: png.count) else { break }
            out[i].imagePNG = png
        }
        return out
    }

    /// The crop scaled down so its longest side is at most `LabelCrop.maxPixelSide` (never enlarged).
    private static func fitted(_ image: CGImage) -> CGImage? {
        guard let target = LabelCrop.fittedSize(width: image.width, height: image.height) else { return nil }
        if target.width == image.width && target.height == image.height { return image }
        guard let context = CGContext(data: nil, width: target.width, height: target.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: target.width, height: target.height))
        return context.makeImage()
    }

    private static func encodePNG(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}
