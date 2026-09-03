@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import Speech

struct AudioFileTranscriptionResult {
    let chunks: [TranscriptChunk]
}

/// Process-wide lease for the large Qwen recognizer. Different meetings can finish close
/// together, so per-artifact sequential loops alone are not sufficient on a 16 GB Mac.
private actor Qwen3ASRExecutionGate {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private var owner: UUID?
    private var waiters: [Waiter] = []

    func acquire(id: UUID) async throws {
        try Task.checkCancellation()
        if owner == nil {
            owner = id
            return
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
    }

    func release(id: UUID) {
        guard owner == id else { return }
        if waiters.isEmpty {
            owner = nil
            return
        }
        let next = waiters.removeFirst()
        owner = next.id
        next.continuation.resume()
    }

    private func cancelWaiter(id: UUID) {
        guard owner != id,
              let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }
}

private func timelineValue(_ value: Int?, adding offset: Int) -> Int? {
    guard let value else { return nil }
    let (sum, overflow) = max(0, value).addingReportingOverflow(max(0, offset))
    return overflow ? Int.max : sum
}

/// One mono recording track anchored to the meeting's shared absolute timeline.
/// A track whose file already includes leading silence should use offset 0.
struct AudioTrackTranscriptionRequest {
    let url: URL
    let source: AudioSource
    let timelineOffsetMilliseconds: Int
    let hotwords: String

    init(
        url: URL,
        source: AudioSource,
        timelineOffsetMilliseconds: Int = 0,
        hotwords: String = ""
    ) {
        self.url = url
        self.source = source
        self.timelineOffsetMilliseconds = max(0, timelineOffsetMilliseconds)
        self.hotwords = hotwords
    }
}

final class AudioFileTranscriber {
    static let shared = AudioFileTranscriber()
    private static let qwenExecutionGate = Qwen3ASRExecutionGate()

    private init() {}

    func transcribe(
        url: URL,
        source: AudioSource = .mic,
        timelineOffsetMilliseconds: Int = 0,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> AudioFileTranscriptionResult {
        let config = APIKeyValidator.shared.currentSTTConfig()
        switch config.engine {
        case .appleSpeechAnalyzer:
            guard #available(macOS 26.0, *) else {
                throw AudioFileTranscriberError.providerError(
                    LanguageManager.shared.t(
                        "macOS 内置语音识别需要 macOS 26 或更高版本。请切换到本地 SenseVoice。",
                        "macOS built-in speech recognition requires macOS 26 or later. Switch to Local SenseVoice."
                    )
                )
            }
            return try await transcribeWithSpeechAnalyzer(
                url: url,
                source: source,
                timelineOffsetMilliseconds: timelineOffsetMilliseconds,
                progress: progress
            )
        case .sherpaSenseVoice:
            return try await transcribeWithProvider(
                SherpaSTTProviderFactory().makeProvider(),
                config: config,
                url: url,
                source: source,
                timelineOffsetMilliseconds: timelineOffsetMilliseconds,
                progress: progress
            )
        case .funASRNano:
            return try await transcribeWithProvider(
                SherpaSTTProviderFactory(kind: .funASRNano).makeProvider(),
                config: config,
                url: url,
                source: source,
                timelineOffsetMilliseconds: timelineOffsetMilliseconds,
                progress: progress
            )
        }
    }

    /// Sequentially re-transcribes mic/system artifacts with a single Qwen workload at a
    /// time. This is the supported local-accurate entry point on 16 GB Macs; callers must
    /// not fan out one provider per track. Returned chunks retain each physical source and
    /// are merged only by their shared absolute timestamps.
    func transcribeTracksWithQwen3(
        _ tracks: [AudioTrackTranscriptionRequest],
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> AudioFileTranscriptionResult {
        guard !tracks.isEmpty else { throw AudioFileTranscriberError.noTranscript }
        let leaseID = UUID()
        try await Self.qwenExecutionGate.acquire(id: leaseID)
        do {
            try Task.checkCancellation()
            try await Qwen3ASRModelManager.shared.ensureReadyForUse()

            var combined: [TranscriptChunk] = []
            for (index, track) in tracks.enumerated() {
                try Task.checkCancellation()
                let base = Double(index) / Double(tracks.count)
                let scale = 1.0 / Double(tracks.count)
                let config = STTProviderConfig(
                    locale: Locale(identifier: UserDefaultsManager.shared.sttLocaleIdentifier),
                    engine: .sherpaSenseVoice,
                    speakerMode: .fixedByAudioSource,
                    hotwords: track.hotwords
                )
                do {
                    let result = try await transcribeWithProvider(
                        SherpaSTTProviderFactory(kind: .qwen3ASR).makeProvider(),
                        config: config,
                        url: track.url,
                        source: track.source,
                        timelineOffsetMilliseconds: track.timelineOffsetMilliseconds,
                        progress: { value in progress?(base + value * scale) }
                    )
                    combined.append(contentsOf: result.chunks)
                } catch AudioFileTranscriberError.noTranscript {
                    // Mic-only capture deliberately writes an all-silence system track.
                    // A silent participant must not discard the other track's valid result.
                    progress?(base + scale)
                }
            }

            progress?(1.0)
            guard !combined.isEmpty else { throw AudioFileTranscriberError.noTranscript }
            let result = AudioFileTranscriptionResult(chunks: combined.sortedByTranscriptTimeline())
            await Self.qwenExecutionGate.release(id: leaseID)
            return result
        } catch {
            await Self.qwenExecutionGate.release(id: leaseID)
            throw error
        }
    }

    @available(macOS 26.0, *)
    private func transcribeWithSpeechAnalyzer(
        url: URL,
        source: AudioSource,
        timelineOffsetMilliseconds: Int,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> AudioFileTranscriptionResult {
        let locale = try await SpeechModelInstaller.shared.ensureReadyForUse()
        let state = AudioFileTranscriptionState(
            source: source,
            timelineOffsetMilliseconds: timelineOffsetMilliseconds
        )

        let transcriber = SpeechModelInstaller.makeTranscriber(
            locale: locale,
            includeTimeRange: true,
            includeVolatileResults: false
        )
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let file = try AVAudioFile(forReading: url)
        let durationMilliseconds = Self.durationMilliseconds(for: file)
        progress?(0.05)

        let resultsTask = Task {
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let timeRange = SpeechAnalyzerSTTProvider.millisecondRange(from: result.range)
                if let endTime = timeRange?.end {
                    progress?(Self.progress(forEndTime: endTime, durationMilliseconds: durationMilliseconds))
                }
                await state.appendFinalChunk(
                    text: text,
                    startTime: timeRange?.start,
                    endTime: timeRange?.end
                )
            }
        }

        do {
            if let lastSample = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: lastSample)
            } else {
                await analyzer.cancelAndFinishNow()
            }
            try await resultsTask.value
            progress?(1.0)
        } catch {
            resultsTask.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }

        let chunks = await state.finalChunks()
        guard !chunks.isEmpty else {
            throw AudioFileTranscriberError.noTranscript
        }

        return AudioFileTranscriptionResult(chunks: chunks)
    }

    private func transcribeWithProvider(
        _ provider: STTProvider,
        config: STTProviderConfig,
        url: URL,
        source: AudioSource,
        timelineOffsetMilliseconds: Int,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> AudioFileTranscriptionResult {
        let state = AudioFileProviderTranscriptionState(
            source: source,
            timelineOffsetMilliseconds: timelineOffsetMilliseconds
        )
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!

        provider.onTranscriptUpdate = { update in
            state.append(update)
        }
        provider.onTranscriptCorrection = { corrections in
            state.apply(corrections)
        }
        provider.onError = { message in
            state.recordError(message)
        }

        progress?(0.03)
        try await provider.connect(config: config)
        do {
            let file = try AVAudioFile(forReading: url)
        guard let converter = AVAudioConverter(from: file.processingFormat, to: targetFormat) else {
            throw AudioFileTranscriberError.unsupportedAudioFormat
        }

        let totalFrames = max(1, file.length)
        let inputFrameCapacity: AVAudioFrameCount = 4096
        var queuedBufferCount = 0

        while file.framePosition < file.length {
            try Task.checkCancellation()

            let framesRemaining = AVAudioFrameCount(
                min(Int64(inputFrameCapacity), file.length - file.framePosition)
            )
            guard framesRemaining > 0,
                  let inputBuffer = AVAudioPCMBuffer(
                    pcmFormat: file.processingFormat,
                    frameCapacity: framesRemaining
                  ) else {
                break
            }

            try file.read(into: inputBuffer, frameCount: framesRemaining)
            guard inputBuffer.frameLength > 0 else { break }

            if let data = Self.convertToPCM16Data(
                inputBuffer,
                targetFormat: targetFormat,
                converter: converter
            ) {
                provider.sendAudio(data)
                queuedBufferCount += 1
                if queuedBufferCount >= 32 {
                    // sherpa's sendAudio is intentionally non-blocking. Periodic queue
                    // barriers keep multi-hour files from retaining every PCM Data value
                    // and closure in memory before inference catches up.
                    let drainStatus = await provider.awaitPendingFinalization(timeout: 60)
                    guard drainStatus == .completed else {
                        throw AudioFileTranscriberError.providerError(
                            "本地转写处理速度不足，已安全停止；原始录音仍保留，可稍后重试。"
                        )
                    }
                    queuedBufferCount = 0
                }
            }

            let fraction = Double(file.framePosition) / Double(totalFrames)
            progress?(min(0.92, max(0.03, 0.03 + fraction * 0.89)))
        }

        provider.sendLastAudio()
        let finalizationStatus = await provider.awaitPendingFinalization(timeout: 30)
        guard finalizationStatus == .completed else {
            throw AudioFileTranscriberError.providerError(
                "本地精准转写收尾超时，未覆盖已有实时文字；原始录音仍保留，可稍后重试。"
            )
        }
        await provider.applyOfflineRefinement()
        await MainActor.run {}
        progress?(1.0)

        if let message = state.currentErrorMessage() {
            throw AudioFileTranscriberError.providerError(message)
        }

        let chunks = state.finalChunks()
        guard !chunks.isEmpty else {
            throw AudioFileTranscriberError.noTranscript
        }

            let result = AudioFileTranscriptionResult(chunks: chunks.sortedByTranscriptTimeline())
            provider.disconnect()
            let shutdownStatus = await provider.awaitShutdown(timeout: 30)
            guard shutdownStatus == .completed else {
                throw AudioFileTranscriberError.providerError(
                    "本地模型释放超时，已保留原始录音，请稍后重试。"
                )
            }
            return result
        } catch {
            provider.disconnect()
            _ = await provider.awaitShutdown(timeout: 30)
            throw error
        }
    }

    private static func convertToPCM16Data(
        _ inputBuffer: AVAudioPCMBuffer,
        targetFormat: AVAudioFormat,
        converter: AVAudioConverter
    ) -> Data? {
        let outputFrameCapacity = AVAudioFrameCount(
            max(1, Double(inputBuffer.frameLength) * targetFormat.sampleRate / inputBuffer.format.sampleRate)
        ) + 32
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputFrameCapacity
        ) else {
            return nil
        }

        var didProvideInput = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            guard !didProvideInput else {
                outStatus.pointee = .noDataNow
                return nil
            }

            didProvideInput = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        guard conversionError == nil,
              status == .haveData || status == .inputRanDry || status == .endOfStream,
              let channelData = outputBuffer.int16ChannelData?[0] else {
            return nil
        }

        let frameCount = Int(outputBuffer.frameLength)
        guard frameCount > 0 else { return nil }
        return Data(bytes: channelData, count: frameCount * MemoryLayout<Int16>.size)
    }

    private static func durationMilliseconds(for file: AVAudioFile) -> Int {
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0 else { return 1 }
        return max(1, Int((Double(file.length) / sampleRate * 1000).rounded()))
    }

    private static func progress(forEndTime endTime: Int, durationMilliseconds: Int) -> Double {
        let fraction = min(1.0, max(0.0, Double(endTime) / Double(durationMilliseconds)))
        return min(0.95, max(0.05, 0.05 + fraction * 0.90))
    }
}

private actor AudioFileTranscriptionState {
    private let source: AudioSource
    private let timelineOffsetMilliseconds: Int
    private var chunks: [TranscriptChunk] = []

    init(source: AudioSource, timelineOffsetMilliseconds: Int) {
        self.source = source
        self.timelineOffsetMilliseconds = max(0, timelineOffsetMilliseconds)
    }

    func finalChunks() -> [TranscriptChunk] {
        chunks
    }

    func appendFinalChunk(text: String, startTime: Int?, endTime: Int?) {
        chunks.append(TranscriptChunk(
            source: source,
            text: text,
            isFinal: true,
            startTime: timelineValue(startTime, adding: timelineOffsetMilliseconds),
            endTime: timelineValue(endTime, adding: timelineOffsetMilliseconds)
        ))
    }
}

private final class AudioFileProviderTranscriptionState: @unchecked Sendable {
    private let lock = NSLock()
    private let source: AudioSource
    private let timelineOffsetMilliseconds: Int
    private var chunks: [TranscriptChunk] = []
    private var errorMessage: String?

    init(source: AudioSource, timelineOffsetMilliseconds: Int) {
        self.source = source
        self.timelineOffsetMilliseconds = max(0, timelineOffsetMilliseconds)
    }

    func append(_ update: STTTranscriptUpdate) {
        let text = update.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let chunk = TranscriptChunk(
            source: source,
            text: text,
            isFinal: update.isFinal,
            speakerTag: update.speakerTag,
            speakerId: update.speakerId,
            startTime: timelineValue(update.startTime, adding: timelineOffsetMilliseconds),
            endTime: timelineValue(update.endTime, adding: timelineOffsetMilliseconds)
        )

        lock.withLock {
            chunks.append(chunk)
        }
    }

    func apply(_ corrections: [STTTranscriptCorrection]) {
        guard !corrections.isEmpty else { return }

        lock.withLock {
            for correction in corrections {
                guard let correctionStart = timelineValue(
                    correction.startTime,
                    adding: timelineOffsetMilliseconds
                ), let correctionEnd = timelineValue(
                    correction.endTime,
                    adding: timelineOffsetMilliseconds
                ) else {
                    continue
                }
                for index in chunks.indices {
                    let chunk = chunks[index]
                    guard chunk.isFinal,
                          chunk.startTime == correctionStart,
                          chunk.endTime == correctionEnd else {
                        continue
                    }

                    chunks[index] = TranscriptChunk(
                        id: chunk.id,
                        timestamp: chunk.timestamp,
                        source: chunk.source,
                        text: chunk.text,
                        isFinal: chunk.isFinal,
                        speakerTag: correction.newSpeakerTag ?? chunk.speakerTag,
                        speakerId: correction.newSpeakerId,
                        startTime: chunk.startTime,
                        endTime: chunk.endTime,
                        isLowConfidence: chunk.isLowConfidence
                    )
                }
            }
        }
    }

    func recordError(_ message: String) {
        lock.withLock {
            errorMessage = message
        }
    }

    func finalChunks() -> [TranscriptChunk] {
        lock.withLock {
            chunks.filter(\.isFinal)
        }
    }

    func currentErrorMessage() -> String? {
        lock.withLock {
            errorMessage
        }
    }
}

enum AudioFileTranscriberError: LocalizedError {
    case unsupportedAudioFormat
    case noTranscript
    case providerError(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedAudioFormat:
            return LanguageManager.shared.t("不支持此音频格式。", "This audio format is not supported.")
        case .noTranscript:
            return LanguageManager.shared.t("未能从音频中识别出转录内容。", "No transcript could be recognized from this audio.")
        case .providerError(let message):
            return message
        }
    }
}
