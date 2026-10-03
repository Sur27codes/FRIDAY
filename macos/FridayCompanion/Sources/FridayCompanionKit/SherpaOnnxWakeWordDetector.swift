import CSherpaOnnx
import Foundation

/// Errors specific to standing up the real, local sherpa-onnx keyword
/// spotter (P2-M3C). These are distinct from `AudioCaptureError` — they
/// describe the wake *engine* failing to initialize, not the microphone.
public enum SherpaOnnxWakeWordError: Error, Equatable {
    case modelResourceNotFound(String)
    case spotterCreationFailed
    case streamCreationFailed
}

/// Everything the real detector needs to know about the vendored model
/// and the target phrase. Deliberately separate from
/// `SherpaOnnxWakeWordDetector` itself so tests can point at a smaller
/// fixture model or a different keyword without touching the detector's
/// logic (mirrors `WakeSessionConfig` next to `WakeCoordinatorEngine`).
public struct SherpaOnnxWakeWordConfig: Sendable {
    public let encoderPath: String
    public let decoderPath: String
    public let joinerPath: String
    public let tokensPath: String
    /// BPE-token representation of the target phrase, in the model's own
    /// vocabulary — NOT plain English text. This one is
    /// `"▁HE Y ▁F RI DAY"` for "Hey Friday", produced by running the
    /// model's own `bpe.model` (SentencePiece) tokenizer against the
    /// literal phrase (§13: the production detector must target the
    /// literal phrase "Hey Friday" — this is that phrase, in the only
    /// format this model family accepts, not a substitute keyword).
    public let keywordTokens: String
    /// The stable identifier this milestone's `WakeEvent.phraseID`
    /// carries downstream — kept separate from `keywordTokens` so
    /// nothing outside this file ever needs to know the BPE encoding.
    public let phraseID: String
    public let numThreads: Int32
    public let keywordsScore: Float
    public let keywordsThreshold: Float
    public let sampleRate: Int32
    public let featureDim: Int32
    /// Beam width for the keyword search. Wider means more decode paths
    /// survive pruning before `keywordsScore`/`keywordsThreshold` ever
    /// get a say — a genuinely distinct lever from those two (see
    /// `docs/E-traceability-matrix.md`'s P2-M3C section for the sweep
    /// evidence that motivated widening this beyond the C API doc's
    /// default example value of 4).
    public let maxActivePaths: Int32

    public init(
        encoderPath: String, decoderPath: String, joinerPath: String, tokensPath: String,
        keywordTokens: String, phraseID: String = "hey_friday",
        numThreads: Int32 = 1, keywordsScore: Float = 2.0, keywordsThreshold: Float = 0.25,
        sampleRate: Int32 = 16000, featureDim: Int32 = 80, maxActivePaths: Int32 = 4
    ) {
        self.encoderPath = encoderPath
        self.decoderPath = decoderPath
        self.joinerPath = joinerPath
        self.tokensPath = tokensPath
        self.keywordTokens = keywordTokens
        self.phraseID = phraseID
        self.numThreads = numThreads
        self.keywordsScore = keywordsScore
        self.keywordsThreshold = keywordsThreshold
        self.sampleRate = sampleRate
        self.featureDim = featureDim
        self.maxActivePaths = maxActivePaths
    }

    /// Resolves the model files this package vendors (see
    /// `Vendor/sherpa-onnx/THIRD_PARTY_NOTICES.md` for the model's
    /// provenance/license). `keywordTokens` here was computed once,
    /// offline, via the model's own `bpe.model` tokenizer against the
    /// literal string "HEY FRIDAY" (see that same notice for the exact
    /// command) — it is not guessed or hand-approximated.
    ///
    /// P2-PROD-BOOTSTRAP-R2 §3.2/§3.3 — resolution order, self-contained
    /// FIRST:
    ///   1. `Contents/Resources/sherpa-onnx-kws-model` next to the
    ///      running app's OWN resources (`Bundle.main.resourceURL`) —
    ///      where `Scripts/build-and-install-app.sh` places the model
    ///      files directly (plain files under `Contents/Resources/`,
    ///      exactly like the dylibs/helper binaries — no nested resource
    ///      bundle, which `codesign` does not seal cleanly at an app's
    ///      TOP level; confirmed directly: `codesign` refused to seal a
    ///      `FridayCompanion_FridayCompanionKit.bundle` placed at the
    ///      bundle root with "unsealed contents present in the bundle
    ///      root"). This is the path the INSTALLED app uses — no
    ///      development checkout required.
    ///   2. `Bundle.module` (the SPM-generated resource-bundle accessor)
    ///      — unchanged fallback for `swift test`/`swift run`, where
    ///      there is no real `.app` wrapper and `Bundle.main.resourceURL`
    ///      doesn't contain the model. `Bundle.module`'s own generated
    ///      logic already falls through to the absolute `.build` path in
    ///      that case, exactly as it always has.
    public static func bundledDefault() throws -> SherpaOnnxWakeWordConfig {
        if let resourceURL = Bundle.main.resourceURL {
            let candidate = resourceURL.appendingPathComponent("sherpa-onnx-kws-model", isDirectory: true)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return config(forModelDirectory: candidate)
            }
        }
        guard let dir = Bundle.module.url(forResource: "sherpa-onnx-kws-model", withExtension: nil) else {
            throw SherpaOnnxWakeWordError.modelResourceNotFound("sherpa-onnx-kws-model resource bundle missing")
        }
        return config(forModelDirectory: dir)
    }

    private static func config(forModelDirectory dir: URL) -> SherpaOnnxWakeWordConfig {
        SherpaOnnxWakeWordConfig(
            encoderPath: dir.appendingPathComponent("encoder.int8.onnx").path,
            decoderPath: dir.appendingPathComponent("decoder.int8.onnx").path,
            joinerPath: dir.appendingPathComponent("joiner.int8.onnx").path,
            tokensPath: dir.appendingPathComponent("tokens.txt").path,
            keywordTokens: "▁HE Y ▁F RI DAY"
        )
    }
}

/// Real, local, offline "Hey Friday" detection via the vendored
/// sherpa-onnx open-vocabulary keyword spotter (ADR-007, resolved in
/// `docs/W-adr-backlog.md` during P2-M3C). This is the first
/// `WakeWordDetecting` conformance in the codebase backed by actual
/// audio inference rather than a fixed marker value or a no-op — see
/// `NullWakeWordDetector` (kept only for tests/explicitly-disabled-wake
/// configuration) and `FakeWakeWordDetector` (test-only, marker-based).
///
/// Every method here only ever touches: the caller-supplied `AudioFrame`
/// samples (converted to float and fed to the model), the model files on
/// disk, and this instance's own opaque spotter/stream handles. Nothing
/// here reaches the network, the filesystem outside the vendored model
/// path, or any FRIDAY subsystem beyond returning a `WakeEvent` value —
/// preserving the P2-M3 privacy/security boundary (§19/§20) unchanged.
public final class SherpaOnnxWakeWordDetector: WakeWordDetecting, @unchecked Sendable {
    public let engineIdentifier: String

    private let config: SherpaOnnxWakeWordConfig
    private let diagnostics: WakeDiagnosticsRecorder?
    private let lock = NSLock()
    private var spotter: OpaquePointer?
    private var stream: OpaquePointer?

    public init(
        config: SherpaOnnxWakeWordConfig, diagnostics: WakeDiagnosticsRecorder? = nil,
        engineIdentifier: String = "sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01 (sherpa-onnx v1.13.6)"
    ) {
        self.config = config
        self.diagnostics = diagnostics
        self.engineIdentifier = engineIdentifier
    }

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }

        var spotterConfig = SherpaOnnxKeywordSpotterConfig(
            feat_config: SherpaOnnxFeatureConfig(sample_rate: config.sampleRate, feature_dim: config.featureDim),
            model_config: SherpaOnnxOnlineModelConfig(
                transducer: SherpaOnnxOnlineTransducerModelConfig(encoder: nil, decoder: nil, joiner: nil),
                paraformer: SherpaOnnxOnlineParaformerModelConfig(encoder: nil, decoder: nil),
                zipformer2_ctc: SherpaOnnxOnlineZipformer2CtcModelConfig(model: nil),
                tokens: nil,
                num_threads: config.numThreads,
                provider: nil,
                debug: 0,
                model_type: nil,
                modeling_unit: nil,
                bpe_vocab: nil,
                tokens_buf: nil,
                tokens_buf_size: 0,
                nemo_ctc: SherpaOnnxOnlineNemoCtcModelConfig(model: nil),
                t_one_ctc: SherpaOnnxOnlineToneCtcModelConfig(model: nil)
            ),
            max_active_paths: config.maxActivePaths,
            num_trailing_blanks: 1,
            keywords_score: config.keywordsScore,
            keywords_threshold: config.keywordsThreshold,
            keywords_file: nil,
            keywords_buf: nil,
            keywords_buf_size: 0
        )

        let created: OpaquePointer? = withCStrings([
            config.encoderPath, config.decoderPath, config.joinerPath, config.tokensPath, "cpu", config.keywordTokens,
        ]) { c in
            spotterConfig.model_config.transducer.encoder = c[0]
            spotterConfig.model_config.transducer.decoder = c[1]
            spotterConfig.model_config.transducer.joiner = c[2]
            spotterConfig.model_config.tokens = c[3]
            spotterConfig.model_config.provider = c[4]
            spotterConfig.keywords_buf = c[5]
            spotterConfig.keywords_buf_size = Int32(strlen(c[5]))
            return SherpaOnnxCreateKeywordSpotter(&spotterConfig)
        }

        guard let created else { throw SherpaOnnxWakeWordError.spotterCreationFailed }

        guard let newStream = SherpaOnnxCreateKeywordStream(created) else {
            SherpaOnnxDestroyKeywordSpotter(created)
            throw SherpaOnnxWakeWordError.streamCreationFailed
        }

        spotter = created
        stream = newStream
        diagnostics?.recordDetectorSampleRate(config.sampleRate)
    }

    public func process(_ frame: AudioFrame, sessionID: String) -> WakeEvent? {
        lock.lock()
        defer { lock.unlock() }
        guard let spotter, let stream else { return nil }

        let floatSamples = frame.samples.map { Float($0) / 32768.0 }
        floatSamples.withUnsafeBufferPointer { buf in
            SherpaOnnxOnlineStreamAcceptWaveform(stream, Int32(frame.sampleRate), buf.baseAddress, Int32(buf.count))
        }
        diagnostics?.recordFrameForwardedToDetector()

        while SherpaOnnxIsKeywordStreamReady(spotter, stream) != 0 {
            SherpaOnnxDecodeKeywordStream(spotter, stream)
        }

        guard let result = SherpaOnnxGetKeywordResult(spotter, stream) else { return nil }
        defer { SherpaOnnxDestroyKeywordResult(result) }

        let keyword = result.pointee.keyword.map { String(cString: $0) } ?? ""
        diagnostics?.recordDetectorResult(keyword: keyword)
        guard !keyword.isEmpty else { return nil }

        SherpaOnnxResetKeywordStream(spotter, stream)
        return WakeEvent(
            eventID: UUID().uuidString, sessionID: sessionID, phraseID: config.phraseID,
            detectedAt: frame.capturedAt, source: "wake_word", engine: engineIdentifier, confidence: nil
        )
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        if let stream { SherpaOnnxDestroyOnlineStream(stream) }
        if let spotter { SherpaOnnxDestroyKeywordSpotter(spotter) }
        stream = nil
        spotter = nil
    }

    deinit {
        if let stream { SherpaOnnxDestroyOnlineStream(stream) }
        if let spotter { SherpaOnnxDestroyKeywordSpotter(spotter) }
    }
}

/// Holds N C strings alive simultaneously for the duration of `body` —
/// `Foundation`/the standard library only provide `withCString` for one
/// string at a time, and this config needs several live at once for a
/// single `SherpaOnnxCreateKeywordSpotter` call.
private func withCStrings<R>(_ strings: [String], _ body: ([UnsafePointer<CChar>]) -> R) -> R {
    func recurse(_ remaining: ArraySlice<String>, _ acc: [UnsafePointer<CChar>]) -> R {
        guard let first = remaining.first else { return body(acc) }
        return first.withCString { cstr in
            recurse(remaining.dropFirst(), acc + [cstr])
        }
    }
    return recurse(strings[...], [])
}
