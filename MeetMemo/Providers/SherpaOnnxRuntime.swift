import Foundation

/// Thin adapter around the sherpa-onnx Swift C-API wrapper.
///
/// This file is the **only** place that touches sherpa-onnx types directly.
/// `SherpaSTTProvider` calls into this adapter, so it can stay decoupled from
/// whether the underlying framework is currently linked in.
///
/// The runtime ships with two parallel implementations gated by the
/// `SHERPA_ONNX_ENABLED` Swift compilation condition:
///
/// - **Disabled (default)** — `make(modelDirectory:)` throws
///   `SherpaOnnxRuntimeError.frameworkUnavailable`. The host UI surfaces a
///   friendly message and the user can keep using the macOS built-in engine.
/// - **Enabled** — Drives the real `SherpaOnnxOfflineRecognizer` +
///   `SherpaOnnxVoiceActivityDetectorWrapper` +
///   `SherpaOnnxSpeakerEmbeddingExtractorWrapper` against the model files
///   downloaded by `SherpaModelManager`.
///
/// See `Frameworks/swift-wrapper/` for the matching `SherpaOnnx.swift` wrapper
/// and bridging header that need to be added to the Xcode target before
/// turning the `SHERPA_ONNX_ENABLED` flag on.
/// Instances are created and consumed exclusively on `SherpaSTTProvider.workQueue`.
/// The unchecked conformance documents that queue confinement so a freshly built runtime
/// can cross the async continuation used during connection without Swift 6 sendability races.
final class SherpaOnnxRuntime: @unchecked Sendable {
    struct Segment {
        let samples: [Float]
        let text: String
        let startSampleOffset: Int
        let endSampleOffset: Int
    }

#if SHERPA_ONNX_ENABLED
    private let recognizer: SherpaOnnxOfflineRecognizer
    private let vad: SherpaOnnxVoiceActivityDetectorWrapper
    private let embeddingExtractor: SherpaOnnxSpeakerEmbeddingExtractorWrapper?
    private let recoveryRecognizer: SherpaOnnxOfflineRecognizer?

    private init(
        recognizer: SherpaOnnxOfflineRecognizer,
        vad: SherpaOnnxVoiceActivityDetectorWrapper,
        embeddingExtractor: SherpaOnnxSpeakerEmbeddingExtractorWrapper?,
        recoveryRecognizer: SherpaOnnxOfflineRecognizer? = nil
    ) {
        self.recognizer = recognizer
        self.vad = vad
        self.embeddingExtractor = embeddingExtractor
        self.recoveryRecognizer = recoveryRecognizer
    }

    static func make(
        modelDirectory: URL,
        senseVoiceModelFileName: String,
        enableSpeakerEmbedding: Bool = true
    ) throws -> SherpaOnnxRuntime {
        let modelPath = modelDirectory.appendingPathComponent(senseVoiceModelFileName).path
        let tokensPath = modelDirectory.appendingPathComponent("tokens.txt").path
        let vadPath = modelDirectory.appendingPathComponent("silero-vad.onnx").path
        let embPath = modelDirectory.appendingPathComponent("3dspeaker-cam-plus.onnx").path

        var requiredPaths = [modelPath, tokensPath, vadPath]
        if enableSpeakerEmbedding { requiredPaths.append(embPath) }
        for path in requiredPaths {
            guard FileManager.default.fileExists(atPath: path) else {
                throw SherpaOnnxRuntimeError.modelFileMissing(path)
            }
        }

        let recognizer = Self.makeSenseVoiceRecognizer(modelPath: modelPath, tokensPath: tokensPath)

        let vad = Self.makeVad(vadPath: vadPath)
        let emb = enableSpeakerEmbedding
            ? Self.makeSpeakerEmbeddingExtractor(modelPath: embPath)
            : nil
        return SherpaOnnxRuntime(recognizer: recognizer, vad: vad, embeddingExtractor: emb)
    }

    /// Qwen3-ASR-0.6B INT8 recognizer used by the post-recording single-track path.
    /// A SenseVoice session is loaded alongside it solely as a non-generative recovery
    /// decoder when the output quality gate detects a repetition loop or hallucination.
    static func makeQwen3ASR(
        modelDirectory: URL,
        hotwords: String = ""
    ) throws -> SherpaOnnxRuntime {
        let qwenDirectory = modelDirectory.appendingPathComponent("qwen3-asr", isDirectory: true)
        let convFrontendPath = qwenDirectory.appendingPathComponent("conv_frontend.onnx").path
        let encoderPath = qwenDirectory.appendingPathComponent("encoder.int8.onnx").path
        let decoderPath = qwenDirectory.appendingPathComponent("decoder.int8.onnx").path
        let tokenizerDirectory = qwenDirectory.appendingPathComponent("tokenizer", isDirectory: true)
        let tokenizerPath = tokenizerDirectory.path
        let tokenizerFiles = ["merges.txt", "tokenizer_config.json", "vocab.json"]
            .map { tokenizerDirectory.appendingPathComponent($0).path }
        let vadPath = modelDirectory.appendingPathComponent("silero-vad.onnx").path
        let fallbackModelPath = modelDirectory
            .appendingPathComponent("sense-voice-small.int8.onnx").path
        let fallbackTokensPath = modelDirectory.appendingPathComponent("tokens.txt").path

        for path in [
            convFrontendPath,
            encoderPath,
            decoderPath,
            vadPath,
            fallbackModelPath,
            fallbackTokensPath,
        ] + tokenizerFiles {
            guard FileManager.default.fileExists(atPath: path) else {
                throw SherpaOnnxRuntimeError.modelFileMissing(path)
            }
        }

        let qwenConfig = sherpaOnnxOfflineQwen3ASRModelConfig(
            convFrontend: convFrontendPath,
            encoder: encoderPath,
            decoder: decoderPath,
            tokenizer: tokenizerPath,
            maxTotalLen: 512,
            // VAD bounds each utterance to 15 seconds. 192 tokens leave ample room for
            // fast Mandarin/English while placing a hard ceiling on a generation loop.
            maxNewTokens: 192,
            temperature: 1e-6,
            topP: 0.8,
            seed: 42,
            hotwords: hotwords
        )
        let modelConfig = sherpaOnnxOfflineModelConfig(
            tokens: "",
            numThreads: 3,
            provider: "cpu",
            debug: 0,
            qwen3Asr: qwenConfig
        )
        let featureConfig = sherpaOnnxFeatureConfig(sampleRate: 16_000, featureDim: 80)
        var recognizerConfig = sherpaOnnxOfflineRecognizerConfig(
            featConfig: featureConfig,
            modelConfig: modelConfig,
            decodingMethod: "greedy_search"
        )
        let recognizer = withUnsafePointer(to: &recognizerConfig) { pointer in
            SherpaOnnxOfflineRecognizer(config: pointer)
        }

        let recoveryRecognizer = Self.makeSenseVoiceRecognizer(
            modelPath: fallbackModelPath,
            tokensPath: fallbackTokensPath
        )
        let vad = Self.makeVad(vadPath: vadPath)
        // Interview roles come from the physical mic/system tracks. Deliberately omit
        // CAM++ here so Qwen never manufactures speaker IDs for one-to-one recordings.
        return SherpaOnnxRuntime(
            recognizer: recognizer,
            vad: vad,
            embeddingExtractor: nil,
            recoveryRecognizer: recoveryRecognizer
        )
    }

    /// Fun-ASR-Nano offline recognizer + the same Silero VAD / CAM++ pipeline used by
    /// SenseVoice. Backs the Fun-ASR-Nano real-time STT engine. ASR weights live under
    /// `modelDirectory/funasr-nano/`; VAD + speaker embedding are reused from the root.
    static func makeFunASRNano(
        modelDirectory: URL,
        language: String = "",
        hotwords: String = "",
        enableSpeakerEmbedding: Bool = true
    ) throws -> SherpaOnnxRuntime {
        let funDir = modelDirectory.appendingPathComponent("funasr-nano", isDirectory: true)
        let encoderPath = funDir.appendingPathComponent("encoder_adaptor.int8.onnx").path
        let llmPath = funDir.appendingPathComponent("llm.int8.onnx").path
        let embeddingPath = funDir.appendingPathComponent("embedding.int8.onnx").path
        let tokenizerDir = funDir.appendingPathComponent("Qwen3-0.6B", isDirectory: true).path
        let vadPath = modelDirectory.appendingPathComponent("silero-vad.onnx").path
        let spkPath = modelDirectory.appendingPathComponent("3dspeaker-cam-plus.onnx").path

        var requiredPaths = [encoderPath, llmPath, embeddingPath, tokenizerDir, vadPath]
        if enableSpeakerEmbedding { requiredPaths.append(spkPath) }
        for path in requiredPaths {
            guard FileManager.default.fileExists(atPath: path) else {
                throw SherpaOnnxRuntimeError.modelFileMissing(path)
            }
        }

        let funCfg = sherpaOnnxOfflineFunASRNanoModelConfig(
            encoderAdaptor: encoderPath,
            llm: llmPath,
            embedding: embeddingPath,
            tokenizer: tokenizerDir,
            language: language,
            itn: true,
            hotwords: hotwords
        )
        let modelCfg = sherpaOnnxOfflineModelConfig(
            tokens: "",
            numThreads: 2,
            provider: "cpu",
            debug: 0,
            modelType: "",
            funasrNano: funCfg
        )
        let featCfg = sherpaOnnxFeatureConfig(sampleRate: 16_000, featureDim: 80)
        var recognizerCfg = sherpaOnnxOfflineRecognizerConfig(
            featConfig: featCfg,
            modelConfig: modelCfg,
            decodingMethod: "greedy_search"
        )
        let recognizer = withUnsafePointer(to: &recognizerCfg) { ptr in
            SherpaOnnxOfflineRecognizer(config: ptr)
        }

        let vad = Self.makeVad(vadPath: vadPath)
        let emb = enableSpeakerEmbedding
            ? Self.makeSpeakerEmbeddingExtractor(modelPath: spkPath)
            : nil
        return SherpaOnnxRuntime(recognizer: recognizer, vad: vad, embeddingExtractor: emb)
    }

    /// Silero VAD — keep the start trigger permissive; callers add leading context before
    /// decoding to preserve soft utterance starts.
    private static func makeVad(vadPath: String) -> SherpaOnnxVoiceActivityDetectorWrapper {
        let sileroCfg = sherpaOnnxSileroVadModelConfig(
            model: vadPath,
            threshold: 0.18,
            minSilenceDuration: 0.25,
            minSpeechDuration: 0.12,
            windowSize: 512,
            maxSpeechDuration: 15.0
        )
        var vadCfg = sherpaOnnxVadModelConfig(
            sileroVad: sileroCfg,
            sampleRate: 16_000,
            numThreads: 1,
            provider: "cpu",
            debug: 0
        )
        return withUnsafePointer(to: &vadCfg) { ptr in
            SherpaOnnxVoiceActivityDetectorWrapper(config: ptr, buffer_size_in_seconds: 60.0)
        }
    }

    private static func makeSpeakerEmbeddingExtractor(modelPath: String) -> SherpaOnnxSpeakerEmbeddingExtractorWrapper {
        var embCfg = sherpaOnnxSpeakerEmbeddingExtractorConfig(
            model: modelPath,
            numThreads: 1,
            debug: 0,
            provider: "cpu"
        )
        return withUnsafePointer(to: &embCfg) { ptr in
            SherpaOnnxSpeakerEmbeddingExtractorWrapper(config: ptr)
        }
    }

    private static func makeSenseVoiceRecognizer(
        modelPath: String,
        tokensPath: String
    ) -> SherpaOnnxOfflineRecognizer {
        let senseVoiceConfig = sherpaOnnxOfflineSenseVoiceModelConfig(
            model: modelPath,
            language: "auto",
            useInverseTextNormalization: true
        )
        let modelConfig = sherpaOnnxOfflineModelConfig(
            tokens: tokensPath,
            numThreads: 2,
            provider: "cpu",
            debug: 0,
            modelType: "sense_voice",
            senseVoice: senseVoiceConfig
        )
        let featureConfig = sherpaOnnxFeatureConfig(sampleRate: 16_000, featureDim: 80)
        var recognizerConfig = sherpaOnnxOfflineRecognizerConfig(
            featConfig: featureConfig,
            modelConfig: modelConfig,
            decodingMethod: "greedy_search"
        )
        return withUnsafePointer(to: &recognizerConfig) { pointer in
            SherpaOnnxOfflineRecognizer(config: pointer)
        }
    }

    func acceptWaveform(_ samples: [Float]) {
        vad.acceptWaveform(samples: samples)
    }

    func flushVAD() {
        vad.flush()
    }

    func nextCompletedSegment(force: Bool) -> Segment? {
        guard !vad.isEmpty() else { return nil }
        let seg = vad.front()
        let startOffset = seg.start
        let samples = seg.samples
        let endOffset = startOffset + samples.count
        vad.pop()

        let result = recognizer.decode(samples: samples, sampleRate: 16_000)
        return Segment(
            samples: samples,
            text: result.text,
            startSampleOffset: startOffset,
            endSampleOffset: endOffset
        )
    }

    func decodeFallbackSegment(samples: [Float], startSampleOffset: Int) -> Segment {
        let result = recognizer.decode(samples: samples, sampleRate: 16_000)
        return Segment(
            samples: samples,
            text: result.text,
            startSampleOffset: startSampleOffset,
            endSampleOffset: startSampleOffset + samples.count
        )
    }

    /// Re-decodes the same time-aligned PCM with the non-generative recovery model.
    /// The returned offsets are unchanged, so a fallback cannot compress either track's
    /// timeline or disturb a later mic/system merge.
    func decodeRecoverySegment(samples: [Float], startSampleOffset: Int) -> Segment? {
        guard let recoveryRecognizer else { return nil }
        let result = recoveryRecognizer.decode(samples: samples, sampleRate: 16_000)
        return Segment(
            samples: samples,
            text: result.text,
            startSampleOffset: startSampleOffset,
            endSampleOffset: startSampleOffset + samples.count
        )
    }

    func embedding(for samples: [Float]) -> [Float] {
        guard let embeddingExtractor else { return [] }
        let stream = embeddingExtractor.createStream()
        stream.acceptWaveform(samples: samples, sampleRate: 16_000)
        stream.inputFinished()
        guard embeddingExtractor.isReady(stream: stream) else { return [] }
        return embeddingExtractor.compute(stream: stream)
    }
#else
    static func make(
        modelDirectory: URL,
        senseVoiceModelFileName: String,
        enableSpeakerEmbedding: Bool = true
    ) throws -> SherpaOnnxRuntime {
        _ = modelDirectory
        _ = senseVoiceModelFileName
        _ = enableSpeakerEmbedding
        throw SherpaOnnxRuntimeError.frameworkUnavailable
    }

    static func makeQwen3ASR(modelDirectory: URL, hotwords: String = "") throws -> SherpaOnnxRuntime {
        _ = modelDirectory
        _ = hotwords
        throw SherpaOnnxRuntimeError.frameworkUnavailable
    }

    static func makeFunASRNano(
        modelDirectory: URL,
        language: String = "",
        hotwords: String = "",
        enableSpeakerEmbedding: Bool = true
    ) throws -> SherpaOnnxRuntime {
        _ = modelDirectory
        _ = language
        _ = hotwords
        _ = enableSpeakerEmbedding
        throw SherpaOnnxRuntimeError.frameworkUnavailable
    }

    func acceptWaveform(_ samples: [Float]) { _ = samples }
    func flushVAD() {}
    func nextCompletedSegment(force: Bool) -> Segment? { _ = force; return nil }
    func decodeFallbackSegment(samples: [Float], startSampleOffset: Int) -> Segment {
        Segment(
            samples: samples,
            text: "",
            startSampleOffset: startSampleOffset,
            endSampleOffset: startSampleOffset + samples.count
        )
    }
    func decodeRecoverySegment(samples: [Float], startSampleOffset: Int) -> Segment? {
        _ = samples
        _ = startSampleOffset
        return nil
    }
    func embedding(for samples: [Float]) -> [Float] { _ = samples; return [] }
#endif
}

enum SherpaOnnxRuntimeError: LocalizedError {
    case frameworkUnavailable
    case modelFileMissing(String)

    var errorDescription: String? {
        let lang = LanguageManager.shared
        switch self {
        case .frameworkUnavailable:
            return lang.t(
                "sherpa-onnx 引擎尚未启用。请运行 scripts/fetch_sherpa_frameworks.sh，按 Frameworks/swift-wrapper/ 下的指引完成 Xcode 集成（添加 xcframework、bridging header，开启 SHERPA_ONNX_ENABLED）。",
                "sherpa-onnx engine is not yet enabled. Run scripts/fetch_sherpa_frameworks.sh and follow the integration steps under Frameworks/swift-wrapper/ (embed the xcframework, set the bridging header, define SHERPA_ONNX_ENABLED)."
            )
        case .modelFileMissing(let path):
            return lang.t(
                "未找到 sherpa-onnx 模型文件：\(path)。请在设置中重新下载对应的本地语音模型。",
                "Missing sherpa-onnx model file: \(path). Re-download the corresponding local speech model in Settings."
            )
        }
    }
}
