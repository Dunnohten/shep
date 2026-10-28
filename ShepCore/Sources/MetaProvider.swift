import CoreGraphics
import Foundation

/// Cloud provider: SAM 3.1 finds controls, Muse Spark names them (both through MetaClient). The screenshot leaves the Mac.
public struct MetaProvider: VisionProvider {
    public let name = "meta"
    public let sendsOffDevice = true
    private let vision: any MetaVisioning
    private let concepts: [String]

    public init(vision: any MetaVisioning, concepts: [String] = VisionRepair.defaultConcepts) {
        self.vision = vision; self.concepts = concepts
    }

    public func analyze(_ input: VisionInput) async throws -> ScreenAnalysis {
        var regions: [SAMRegion] = []
        var failures = 0
        var notes: [String] = []
        for concept in concepts {
            do { regions += try await vision.segment(png: input.png, imageSize: input.geometry.imageSize, concept: concept) }
            catch { failures += 1; notes.append("SAM \(concept): \(Redact.scrub(error.localizedDescription))") }
        }
        if failures == concepts.count, !concepts.isEmpty { throw ProviderError.unreachable(notes.first ?? "SAM failed") }
        let candidates = VisionRepair.candidates(from: regions, geometry: input.geometry, ax: input.axControls)
        var labels: [Int: MuseLabel] = [:]
        if !candidates.isEmpty {
            do { labels = try await vision.name(png: input.png, candidates: candidates, request: input.request) }
            catch { notes.append("Muse names: \(Redact.scrub(error.localizedDescription))") }
        }
        let located = candidates.map { c -> LocatedControl in
            let label = labels[c.id]
            let raw = label?.name ?? ""
            let name = raw.isEmpty || raw.lowercased() == "unlabeled" ? "unlabeled \(c.concept)" : raw
            return LocatedControl(name: name, role: label?.role ?? c.concept, box: c.pixelBox, score: c.score)
        }
        let summary = located.isEmpty ? "No extra controls found on the screenshot." : "Found \(located.count) control(s) the app doesn't list."
        return ScreenAnalysis(summary: summary, controls: located, notes: notes)
    }
}
