import Foundation

public enum ProviderKind: String, Equatable, Sendable {
    case glimmer, meta, fake
}

public struct ProviderConfig: Equatable, Sendable {
    public var preferred: ProviderKind
    public var glimmer: GlimmerConfig
    public var meta: MetaConfig
    public var detector: DetectorConfig
    public init(preferred: ProviderKind = .glimmer, glimmer: GlimmerConfig = GlimmerConfig(), meta: MetaConfig = MetaConfig(),
                detector: DetectorConfig = DetectorConfig()) {
        self.preferred = preferred; self.glimmer = glimmer; self.meta = meta; self.detector = detector
    }

    /// SHEP_PROVIDER=glimmer|meta|fake (default glimmer), SHEP_GLIMMER_URL (reuse an already-running OpenAI-compatible
    /// Glimmer, e.g. llama-server, instead of loading a second copy), SHEP_GLIMMER_MODEL (default: the model path under `home`),
    /// SHEP_DETECTOR_URL (the detector sidecar), SHEP_SAM3=1 (opt in to SAM 3; off by default).
    public static func from(environment: [String: String], home: String) -> ProviderConfig {
        var c = ProviderConfig()
        c.glimmer.model = GlimmerConfig.defaultModelPath(home: home)
        if let raw = environment["SHEP_PROVIDER"]?.lowercased(), let k = ProviderKind(rawValue: raw) { c.preferred = k }
        if let u = environment["SHEP_GLIMMER_URL"], let url = URL(string: u), !u.isEmpty { c.glimmer.baseURL = url }
        if let m = environment["SHEP_GLIMMER_MODEL"], !m.isEmpty { c.glimmer.model = m }
        if let u = environment["SHEP_DETECTOR_URL"], let url = URL(string: u), !u.isEmpty { c.detector.baseURL = url }
        if let flag = environment["SHEP_SAM3"]?.lowercased(), ["1", "true", "yes", "on"].contains(flag) { c.detector.useSAM3 = true }
        return c
    }
}

public struct ProviderSelection: Equatable, Sendable {
    public var kind: ProviderKind
    /// Why the choice differs from the request, if it does.
    public var note: String?
}

public enum ProviderFactory {
    /// Meta is chosen only when it is asked for AND MODEL_API_KEY is present; otherwise Glimmer. Never anything else.
    public static func select(config: ProviderConfig, environment: [String: String]) -> ProviderSelection {
        switch config.preferred {
        case .fake: return ProviderSelection(kind: .fake, note: nil)
        case .glimmer: return ProviderSelection(kind: .glimmer, note: nil)
        case .meta:
            if let key = environment["MODEL_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
                return ProviderSelection(kind: .meta, note: nil)
            }
            return ProviderSelection(kind: .glimmer, note: "MODEL_API_KEY is not set, so the local Glimmer provider is used.")
        }
    }

    /// The model that picks among the best-ranked controls: Glimmer (same server as the namer) when Glimmer is the provider;
    /// nil for the cloud and fake providers, where the ranking alone decides.
    public static func makePicker(config: ProviderConfig, environment: [String: String],
                                  transport: any MetaTransport = URLSessionMetaTransport()) -> (any ProposalPicking)? {
        guard select(config: config, environment: environment).kind == .glimmer, (try? config.glimmer.validate()) != nil else { return nil }
        return GlimmerPicker(config: config.glimmer, transport: transport)
    }

    public static func make(config: ProviderConfig, environment: [String: String],
                            transport: any MetaTransport = URLSessionMetaTransport(),
                            preparer: any ImagePreparing = ImageIOPreparer(),
                            fake: FakeProvider? = nil) throws -> (provider: any VisionProvider, selection: ProviderSelection) {
        let selection = select(config: config, environment: environment)
        switch selection.kind {
        case .glimmer:
            try config.glimmer.validate()
            try config.detector.validate()
            let detector = SidecarDetector(config: config.detector, transport: transport)
            let namer = GlimmerNamer(config: config.glimmer, transport: transport)
            let provider = DetectorVisionProvider(detector: detector, namer: namer, preparer: preparer,
                                                  longestSide: config.glimmer.longestSide, jpegQuality: config.glimmer.jpegQuality)
            return (provider, selection)
        case .meta:
            guard let key = MetaKeySource.resolve(environment: environment) else { throw MetaError.noKey }
            return (MetaProvider(vision: MetaClient(apiKey: key, config: config.meta, transport: transport)), selection)
        case .fake:
            guard let fake else { throw ProviderError.refusedConfig("No fake provider was supplied.") }
            return (fake, selection)
        }
    }
}
