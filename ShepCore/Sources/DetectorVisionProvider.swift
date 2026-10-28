import CoreGraphics
import Foundation

/// The local control finder: a detector (OmniParser v3, optionally SAM 3) finds boxes, they are merged with the
/// Accessibility tree, and a namer (Glimmer) only names what is left and picks the target of a request.
/// Nothing leaves the Mac. When the namer fails the boxes are still returned, unlabeled, with a note.
public struct DetectorVisionProvider: VisionProvider {
    public let detector: any DetectorProvider
    public let namer: any ControlNaming
    public let sendsOffDevice = false
    public let longestSide: CGFloat
    public let jpegQuality: CGFloat
    private let preparer: any ImagePreparing

    public init(detector: any DetectorProvider, namer: any ControlNaming, preparer: any ImagePreparing = ImageIOPreparer(),
                longestSide: CGFloat = 960, jpegQuality: CGFloat = 0.7) {
        self.detector = detector; self.namer = namer; self.preparer = preparer
        self.longestSide = longestSide; self.jpegQuality = jpegQuality
    }

    public var name: String { "\(detector.name)+\(namer.name)" }

    public func analyze(_ input: VisionInput) async throws -> ScreenAnalysis {
        let detections = try await detector.detect(png: input.png, imageSize: input.geometry.imageSize)
        let candidates = ControlMerger.candidates(detections: detections, geometry: input.geometry, ax: input.axControls)
        var notes = ["detector found \(detections.count) box(es); \(candidates.count) are not in the Accessibility list"]
        guard !candidates.isEmpty else {
            var analysis = ScreenAnalysis(summary: "No extra controls found on the screenshot.", controls: [], notes: notes)
            analysis.debug = Self.debug(detections: detections, candidates: [], labels: [:], candidateAX: [:], offered: [], input: input)
            return analysis
        }
        let marks = candidates.map { ImageMark(id: $0.id, box: $0.pixelBox) }
        guard let image = preparer.prepare(png: input.png, longestSide: longestSide, quality: jpegQuality, marks: marks) else {
            throw ProviderError.imageUnreadable
        }
        let job = NamingJob(image: image, candidates: candidates, hints: ControlMerger.hints(for: candidates, detections: detections),
                            axControls: input.axControls, request: input.request, windowTitle: input.windowTitle)
        var naming = NamingResult()
        do { naming = try await namer.nameControls(job) }
        catch { notes.append("naming failed (\(Redact.scrub(error.localizedDescription))); found controls are listed unlabeled") }
        notes += naming.notes

        // Each box gets one role: an Accessibility element it overlaps wins, then the model's, then the guards in RoleResolver.
        // Boxes that are an element the app already lists, and text, pictures and "other", are not offered as controls.
        var located: [LocatedControl] = []
        var matchedAX = 0
        var notControls = 0
        var candidateAX: [Int: Int] = [:]
        var offered = Set<Int>()
        for c in candidates {
            let label = naming.labels[c.id]
            let raw = label?.name ?? ""
            let resolved = RoleResolver.resolve(frame: c.screenFrame, modelText: label?.role ?? ControlRole.recognized(c.concept)?.rawValue, name: raw, ax: input.axControls)
            if resolved.source == .ax { matchedAX += 1; candidateAX[c.id] = resolved.axMatch?.index; continue }
            if !resolved.role.isProposable { notControls += 1; continue }
            let shown = raw.isEmpty || raw.lowercased() == "unlabeled" ? "unlabeled \(c.concept)" : raw
            located.append(LocatedControl(name: shown, role: resolved.role.rawValue, box: c.pixelBox, score: c.score))
            offered.insert(c.id)
        }
        if matchedAX > 0 { notes.append("\(matchedAX) box(es) overlap controls the app lists; their role comes from Accessibility") }
        if notControls > 0 { notes.append("\(notControls) box(es) are text, pictures or unclear, not controls, and are not offered") }
        var targetBox: CGRect?
        var debug = Self.debug(detections: detections, candidates: candidates, labels: naming.labels, candidateAX: candidateAX,
                               offered: offered, input: input)
        debug.sentSize = image.size
        switch naming.target {
        case .candidate(let id)?:
            targetBox = candidates.first(where: { $0.id == id })?.pixelBox
            if targetBox != nil { debug.namerSource = .candidate(id) }
        case .box(let name, let rect)?:
            // A control the detector missed. If it is really one of the boxes, that box is the target; otherwise it joins the list.
            let nearest = candidates.first(where: { VisionRepair.sameControl($0.pixelBox, rect) })
            if let n = nearest { targetBox = n.pixelBox; debug.namerSource = .modelBoxOnCandidate(n.id) }
            else {
                debug.namerSource = .modelBox
                // Not a new control when it is one the app lists (the pipeline then proposes that control) or a strip, not a control.
                let screen = input.geometry.screenRect(forPixels: rect)
                if !VisionRepair.isAXDuplicate(screen, ax: input.axControls) && !VisionRepair.isImplausibleShape(screen) {
                    located.append(LocatedControl(name: name, role: "", box: rect, score: 0.5))
                }
                targetBox = rect
            }
        case nil:
            break
        }
        let summary = naming.summary.isEmpty ? "Found \(located.count) control(s) the app doesn't list." : naming.summary
        var analysis = ScreenAnalysis(summary: summary, controls: located, notes: notes, targetBox: targetBox)
        analysis.debug = debug
        return analysis
    }

    /// Every detector box for the debug dump: where it is in pixels and window points, which listed control it is (the duplicate
    /// rule the candidates use, then the role rule), its candidate number, the namer's name for it and whether it was offered.
    static func debug(detections: [DetectedBox], candidates: [VisionCandidate], labels: [Int: MuseLabel], candidateAX: [Int: Int],
                      offered: Set<Int>, input: VisionInput) -> AnalysisDebug {
        var debug = AnalysisDebug()
        debug.detectorCount = detections.count
        let space = input.geometry.space
        for d in detections.prefix(AnalysisDebug.limit) {
            let screen = input.geometry.screenRect(forPixels: d.box)
            let candidate = candidates.first(where: { $0.pixelBox == d.box })?.id
            var axIndex: Int?
            var ambiguous = false
            switch VisionRepair.axDuplicateResolution(of: screen, ax: input.axControls) {
            case .one(let c): axIndex = c.index
            case .ambiguous: ambiguous = true
            case .none: axIndex = candidate.flatMap { candidateAX[$0] } ?? RoleResolver.axMatch(for: screen, in: input.axControls)?.index
            }
            debug.detectorBoxes.append(TraceDetectorBox(pixelBox: d.box, windowBox: space.windowRect(fromPixels: d.box), kind: d.kind, score: d.score,
                                                        axIndex: axIndex, axAmbiguous: ambiguous, candidate: candidate,
                                                        label: candidate.flatMap { labels[$0]?.name } ?? "",
                                                        offered: candidate.map { offered.contains($0) } ?? false))
        }
        return debug
    }
}
