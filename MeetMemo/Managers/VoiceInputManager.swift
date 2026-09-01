@preconcurrency import AVFoundation
import AppKit
import Combine
import Foundation

enum VoiceInputState: Equatable {
    case idle
    case listening
    case transcribing
    case inserting
}

@MainActor
final class VoiceInputManager: NSObject, ObservableObject {
    static let shared = VoiceInputManager()

    @Published private(set) var state: VoiceInputState = .idle
    @Published private(set) var errorMessage: String?
    @Published private(set) var audioLevel: Float = 0

    private var audioEngine = AVAudioEngine()
    private var audioPipeline: AudioProcessingPipeline?
    private var provider: STTProvider?
    private var providerConnectTask: Task<Void, Never>?
    private var audioDrainTask: Task<Void, Never>?
    private var finalizationTask: Task<Void, Never>?
    private var maxListeningTask: Task<Void, Never>?
    private var transcriptParts: [String] = []
    private var receivedFinalTranscriptKeys = Set<FinalTranscriptKey>()
    private var pendingAudioChunks: [Data] = []
    private var pendingAudioByteCount = 0
    private var sessionID = UUID()
    private var finalizingSessionID: UUID?
    private let finalFlushTimeout = VoiceInputTiming.finalFlushTimeout
    // 在 provider 连接（含首次模型加载）期间缓冲麦克风音频，避免冷启动吃掉开头几秒。
    private let maxPendingAudioBytes = VoiceInputTiming.maxPendingAudioBytes
    private let trailingSilenceBytes = VoiceInputTiming.trailingSilenceBytes

    private override init() {
        super.init()
    }

    var isActive: Bool {
        state != .idle
    }

    func toggle() {
        switch state {
        case .idle:
            start()
        case .listening:
            stop()
        case .transcribing, .inserting:
            break
        }
    }

    func start() {
        guard state == .idle else { return }

        let recordingSession = RecordingSessionManager.shared
        guard recordingSession.activeMeetingId == nil,
              !recordingSession.isRecording,
              !recordingSession.isStoppingRecording else {
            fail(LanguageManager.shared.t(
                "会议录音中暂不能启动语音输入。",
                "Voice input cannot start while meeting recording is active."
            ))
            return
        }

        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor [weak self] in
                    if granted {
                        self?.start()
                    } else {
                        self?.fail(LanguageManager.shared.t("需要麦克风权限才能使用语音输入。", "Microphone access is required for voice input."))
                    }
                }
            }
            return
        }

        let newSessionID = UUID()
        sessionID = newSessionID
        transcriptParts.removeAll()
        receivedFinalTranscriptKeys.removeAll()
        pendingAudioChunks.removeAll()
        pendingAudioByteCount = 0
        finalizingSessionID = nil
        finalizationTask?.cancel()
        finalizationTask = nil
        errorMessage = nil
        audioLevel = 0
        state = .listening
        VoiceInputFloatingWindowManager.shared.showListening()

        do {
            try startMicrophoneCapture(sessionID: newSessionID)
        } catch {
            fail(ErrorHandler.shared.handleError(error))
            return
        }

        providerConnectTask = Task { [weak self] in
            await self?.connectProvider(sessionID: newSessionID)
        }

        startMaxListeningGuard(sessionID: newSessionID)
    }

    /// listening 安全阀：超过最大时长后自动停止并插入已识别内容，
    /// 防止忘记停止（单击/双击）或 keyUp 丢失（按住模式）造成的无限录音。
    private func startMaxListeningGuard(sessionID guardedSessionID: UUID) {
        maxListeningTask?.cancel()
        maxListeningTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(VoiceInputTiming.maxListeningDuration))
            guard !Task.isCancelled else { return }
            self?.handleMaxListeningReached(sessionID: guardedSessionID)
        }
    }

    private func handleMaxListeningReached(sessionID guardedSessionID: UUID) {
        guard sessionID == guardedSessionID, state == .listening else { return }
        maxListeningTask = nil
        stop()
    }

    func stop() {
        guard state == .listening else { return }
        let stoppedSessionID = sessionID
        maxListeningTask?.cancel()
        maxListeningTask = nil
        state = .transcribing
        VoiceInputFloatingWindowManager.shared.showTranscribing()

        let stoppedPipeline = audioPipeline
        audioPipeline = nil
        cleanupAudioEngine()
        audioDrainTask?.cancel()
        audioDrainTask = Task { @MainActor [weak self] in
            if let stoppedPipeline {
                await stoppedPipeline.drainAndStop()
            }
            guard let self,
                  self.sessionID == stoppedSessionID,
                  self.state == .transcribing else { return }
            self.audioDrainTask = nil

            if let stoppedProvider = self.provider {
                self.finalizeAndInsert(provider: stoppedProvider, sessionID: stoppedSessionID)
            } else if self.providerConnectTask == nil {
                await self.finishAndInsert()
            }
        }
    }

    private func connectProvider(sessionID: UUID) async {
        do {
            try await ensureActiveEngineReady()
            guard self.sessionID == sessionID, state == .listening || state == .transcribing else { return }

            // A nonisolated async function runs on the generic executor, so no unstructured
            // detached child is needed. The Sendable transfer box carries exclusive ownership
            // back to MainActor and parent cancellation remains structured.
            let transferredProvider = try await Self.makeConnectedProviderOffMain(sessionID: sessionID)
            try Task.checkCancellation()
            let connectedProvider = transferredProvider.provider
            guard self.sessionID == sessionID, state == .listening || state == .transcribing else {
                connectedProvider.disconnect()
                return
            }
            provider = connectedProvider
            providerConnectTask = nil
            flushPendingAudio(to: connectedProvider)

            if state == .transcribing {
                if let audioDrainTask {
                    await audioDrainTask.value
                }
                finalizeAndInsert(provider: connectedProvider, sessionID: sessionID)
            }
        } catch {
            guard self.sessionID == sessionID, state == .listening || state == .transcribing else { return }
            providerConnectTask = nil
            fail(ErrorHandler.shared.handleError(error))
        }
    }

    /// 进入实际连接前确认当前引擎模型已就绪（仅刷新+校验，不触发下载），
    /// 未就绪时抛错并给出明确提示，而不是静默丢音或长时间无响应。
    private func ensureActiveEngineReady() async throws {
        switch UserDefaultsManager.shared.sttEngine {
        case .sherpaSenseVoice:
            await SherpaModelManager.shared.refreshReadiness()
            guard SherpaModelManager.shared.isReady else {
                throw VoiceInputError.modelNotReady(LanguageManager.shared.t(
                    "SenseVoice 模型尚未下载，请先在设置中下载模型。",
                    "SenseVoice models are not downloaded. Download them in Settings first."
                ))
            }
        case .funASRNano:
            await FunASRNanoModelManager.shared.refreshReadiness()
            guard FunASRNanoModelManager.shared.isReady else {
                throw VoiceInputError.modelNotReady(LanguageManager.shared.t(
                    "Fun-ASR-Nano 模型尚未下载，请先在设置中下载模型。",
                    "Fun-ASR-Nano models are not downloaded. Download them in Settings first."
                ))
            }
        case .appleSpeechAnalyzer:
            if #available(macOS 26.0, *) {
                await SpeechModelInstaller.shared.checkModelAvailability()
                guard SpeechModelInstaller.shared.isModelReady else {
                    throw VoiceInputError.modelNotReady(LanguageManager.shared.t(
                        "系统语音识别模型尚未就绪，请先在设置中完成准备。",
                        "The system speech model is not ready. Prepare it in Settings first."
                    ))
                }
            } else {
                throw VoiceInputError.modelNotReady(LanguageManager.shared.t(
                    "macOS 内置语音识别需要 macOS 26 或更高版本。",
                    "Built-in speech recognition requires macOS 26 or later."
                ))
            }
        }
    }

    /// 会议录音即将开始时，静默停止正在进行的语音输入（不弹错误、不向前台插字）。
    func cancelForRecording() {
        guard state != .idle else { return }
        // 变更 sessionID 使所有挂起的连接/识别/插入回调失效，避免误插入到录音目标应用。
        sessionID = UUID()
        providerConnectTask?.cancel()
        providerConnectTask = nil
        audioDrainTask?.cancel()
        audioDrainTask = nil
        finalizationTask?.cancel()
        finalizationTask = nil
        maxListeningTask?.cancel()
        maxListeningTask = nil
        cleanupAudioEngine()
        audioPipeline?.stop()
        audioPipeline = nil
        provider?.disconnect()
        provider = nil
        transcriptParts.removeAll()
        receivedFinalTranscriptKeys.removeAll()
        finalizingSessionID = nil
        pendingAudioChunks.removeAll(keepingCapacity: false)
        pendingAudioByteCount = 0
        audioLevel = 0
        errorMessage = nil
        state = .idle
        VoiceInputFloatingWindowManager.shared.hideWindow()
    }

    private func startMicrophoneCapture(sessionID: UUID) throws {
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            throw VoiceInputError.audioFormatUnavailable
        }

        guard let pipeline = AudioProcessingPipeline(
            source: .mic,
            inputFormat: inputFormat,
            targetFormat: targetFormat,
            onAudioData: { [weak self] data, _ in
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          self.sessionID == sessionID,
                          self.state == .listening || self.state == .transcribing else { return }
                    if let provider = self.provider {
                        provider.sendAudio(data)
                    } else {
                        self.appendPendingAudio(data)
                    }
                }
            },
            onAudioLevel: { [weak self] level, _ in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.sessionID == sessionID, self.state == .listening else { return }
                    self.audioLevel = level
                    VoiceInputFloatingWindowManager.shared.updateAudioLevel(level)
                }
            }
        ) else {
            throw VoiceInputError.audioPipelineUnavailable
        }

        audioPipeline = pipeline
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [pipeline] buffer, _ in
            pipeline.enqueue(buffer)
        }
        audioEngine.prepare()
        try audioEngine.start()
    }

    private func appendPendingAudio(_ data: Data) {
        pendingAudioChunks.append(data)
        pendingAudioByteCount += data.count

        while pendingAudioByteCount > maxPendingAudioBytes, !pendingAudioChunks.isEmpty {
            let removed = pendingAudioChunks.removeFirst()
            pendingAudioByteCount -= removed.count
        }
    }

    private func flushPendingAudio(to provider: STTProvider) {
        let chunks = pendingAudioChunks
        pendingAudioChunks.removeAll(keepingCapacity: true)
        pendingAudioByteCount = 0
        chunks.forEach { provider.sendAudio($0) }
    }

    private func finalizeAndInsert(provider stoppedProvider: STTProvider, sessionID stoppedSessionID: UUID) {
        guard finalizingSessionID != stoppedSessionID else { return }
        finalizingSessionID = stoppedSessionID
        if trailingSilenceBytes > 0 {
            stoppedProvider.sendAudio(Data(repeating: 0, count: trailingSilenceBytes))
        }
        stoppedProvider.sendLastAudio()

        finalizationTask?.cancel()
        finalizationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let status = await stoppedProvider.awaitPendingFinalization(timeout: self.finalFlushTimeout)
            await self.awaitMainQueueBarrier()
            guard !Task.isCancelled,
                  self.sessionID == stoppedSessionID,
                  self.state == .transcribing,
                  self.finalizingSessionID == stoppedSessionID else { return }
            if status.mayHaveMissedTailAudio {
                self.errorMessage = LanguageManager.shared.t(
                    "语音识别收尾超时，最后几个字可能未完成。",
                    "Voice recognition finalization timed out; the last few words may be missing."
                )
            }
            await self.finishAndInsert()
        }
    }

    private nonisolated static func makeConnectedProviderOffMain(sessionID: UUID) async throws -> TransferredSTTProvider {
        let engine = UserDefaultsManager.shared.sttEngine
        let provider = factory(for: engine).makeProvider()
        provider.onTranscriptUpdate = { update in
            DispatchQueue.main.async {
                let manager = VoiceInputManager.shared
                guard manager.sessionID == sessionID else { return }
                guard update.isFinal else { return }
                let text = update.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty, manager.acceptFinalTranscript(text: text, update: update) {
                    manager.transcriptParts.append(text)
                }
            }
        }
        provider.onError = { message in
            DispatchQueue.main.async {
                let manager = VoiceInputManager.shared
                guard manager.sessionID == sessionID else { return }
                manager.fail(message)
            }
        }
        provider.onTranscriptCorrection = nil
        do {
            try Task.checkCancellation()
            try await provider.connect(config: APIKeyValidator.shared.currentSTTConfig())
            try Task.checkCancellation()
            return TransferredSTTProvider(provider)
        } catch {
            provider.disconnect()
            throw error
        }
    }

    private func finishAndInsert() async {
        state = .inserting
        let rawText = VoiceInputTextComposer.compose(transcriptParts)
        let finalText = UserDefaultsManager.shared.voiceInputCleansText
            ? VoiceInputTextNormalizer.normalize(rawText)
            : rawText.trimmingCharacters(in: .whitespacesAndNewlines)

        provider?.disconnect()
        provider = nil
        audioDrainTask = nil
        finalizationTask = nil
        finalizingSessionID = nil

        guard !finalText.isEmpty else {
            fail(LanguageManager.shared.t("没有识别到可插入的内容。", "No text was recognized to insert."))
            return
        }

        let result = await VoiceInputTextInserter.shared.insert(finalText)
        state = .idle
        providerConnectTask = nil
        pendingAudioChunks.removeAll(keepingCapacity: false)
        pendingAudioByteCount = 0
        receivedFinalTranscriptKeys.removeAll()
        switch result {
        case .inserted, .pastedBestEffort:
            // 正常结束（已插入或回退到剪贴板）直接收起浮窗，不再展示结果确认面板。
            VoiceInputFloatingWindowManager.shared.hideWindow()
        case .failed:
            VoiceInputFloatingWindowManager.shared.showFailedAndHide()
        }
    }

    private func fail(_ message: String) {
        print("❌ VoiceInput failed: \(message)")
        errorMessage = message
        providerConnectTask?.cancel()
        providerConnectTask = nil
        audioDrainTask?.cancel()
        audioDrainTask = nil
        finalizationTask?.cancel()
        finalizationTask = nil
        maxListeningTask?.cancel()
        maxListeningTask = nil
        cleanupAudioEngine()
        audioPipeline?.stop()
        audioPipeline = nil
        provider?.disconnect()
        provider = nil
        transcriptParts.removeAll()
        receivedFinalTranscriptKeys.removeAll()
        finalizingSessionID = nil
        pendingAudioChunks.removeAll(keepingCapacity: false)
        pendingAudioByteCount = 0
        audioLevel = 0
        state = .idle
        VoiceInputFloatingWindowManager.shared.showFailedAndHide(message: message)
    }

    private func cleanupAudioEngine() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.reset()
        audioEngine = AVAudioEngine()
    }

    private func awaitMainQueueBarrier() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    private func acceptFinalTranscript(text: String, update: STTTranscriptUpdate) -> Bool {
        let key = FinalTranscriptKey(text: text, startTime: update.startTime, endTime: update.endTime)
        return receivedFinalTranscriptKeys.insert(key).inserted
    }

    private nonisolated static func factory(for engine: STTEngine) -> STTProviderFactory {
        switch engine {
        case .appleSpeechAnalyzer:
            if #available(macOS 26.0, *) {
                return SpeechAnalyzerSTTProviderFactory()
            }
            return UnavailableSTTProviderFactory(
                message: "macOS 内置语音识别需要 macOS 26 或更高版本。请切换到本地 SenseVoice。"
            )
        case .sherpaSenseVoice:
            return SherpaSTTProviderFactory()
        case .funASRNano:
            return SherpaSTTProviderFactory(kind: .funASRNano)
        }
    }

}

/// The provider is fully constructed on a generic executor and has no concurrent consumer
/// until this box is opened on MainActor. This documents that one-time ownership transfer
/// without declaring every mutable STT implementation universally Sendable.
private final class TransferredSTTProvider: @unchecked Sendable {
    let provider: STTProvider

    init(_ provider: STTProvider) {
        self.provider = provider
    }
}

private struct FinalTranscriptKey: Hashable {
    let text: String
    let startTime: Int?
    let endTime: Int?
}

private enum VoiceInputError: LocalizedError {
    case audioFormatUnavailable
    case audioPipelineUnavailable
    case modelNotReady(String)

    var errorDescription: String? {
        switch self {
        case .audioFormatUnavailable:
            return "Unable to create the target audio format for voice input."
        case .audioPipelineUnavailable:
            return "Unable to create the audio pipeline for voice input."
        case let .modelNotReady(message):
            return message
        }
    }
}
