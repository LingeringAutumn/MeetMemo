import Foundation

/// STT provider backed by sherpa-onnx (SenseVoice-Small + Silero VAD + CAM++ speaker embedding).
///
/// Two-stage speaker labeling:
/// 1. Per VAD segment, extract a CAM++ embedding and assign a speaker id via
///    online centroid clustering. The result is emitted immediately as a final
///    `STTTranscriptUpdate` with the provisional `speakerId`.
/// 2. When the host calls `applyOfflineRefinement()` (after `awaitPendingFinalization`
///    returns), all collected embeddings are re-clustered offline with complete-linkage
///    HAC, and any segments whose final speaker id differs from the provisional one
///    are emitted as `STTTranscriptCorrection`s via `onTranscriptCorrection`.
///
/// NOTE: The actual sherpa-onnx Swift calls (OfflineRecognizer init, VAD accept,
/// EmbeddingExtractor compute) are gated behind the `SherpaOnnxRuntime` adapter and
/// activated only when the prebuilt xcframework is integrated into the Xcode project.
/// Until then, `connect` throws a friendly error so the host can fall back gracefully.
/// Which sherpa-onnx offline recognizer the provider drives. Both share the same
/// VAD-segment → decode → CAM++ diarization pipeline; only the recognizer differs.
enum SherpaRecognizerKind {
    case senseVoice
    case funASRNano
}

/// Linearizes session lifecycle decisions before work is submitted to the recognizer queue.
///
/// Queue serialization alone is not sufficient here: `sendAudio`, `sendLastAudio`, and
/// `disconnect` can race while deciding what to enqueue. Holding this small lock while a
/// block is submitted gives those calls a deterministic order without ever running model
/// work under the lock.
final class SherpaSessionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var nextGeneration: UInt64 = 0
    private var activeGeneration: UInt64?
    private var acceptsAudio = false

    func beginSession(enqueueReset: (UInt64) -> Void) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }

        nextGeneration &+= 1
        // Generation zero is reserved as an invalid value. Reaching this branch would
        // require more sessions than a process can realistically create, but keeping the
        // invariant explicit makes wraparound deterministic.
        if nextGeneration == 0 { nextGeneration = 1 }

        let generation = nextGeneration
        activeGeneration = generation
        acceptsAudio = false
        enqueueReset(generation)
        return generation
    }

    @discardableResult
    func invalidate(enqueueReset: () -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let hadActiveSession = activeGeneration != nil
        activeGeneration = nil
        acceptsAudio = false
        enqueueReset()
        return hadActiveSession
    }

    @discardableResult
    func invalidateIfCurrent(_ generation: UInt64, enqueueReset: () -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard activeGeneration == generation else { return false }
        activeGeneration = nil
        acceptsAudio = false
        enqueueReset()
        return true
    }

    func isCurrent(_ generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeGeneration == generation
    }

    /// Installs the runtime and opens audio submission as one lifecycle operation.
    func activateIfCurrent(_ generation: UInt64, install: () -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard activeGeneration == generation else { return false }
        install()
        acceptsAudio = true
        return true
    }

    func submitIfCurrent(_ generation: UInt64, enqueue: () -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard activeGeneration == generation else { return false }
        enqueue()
        return true
    }

    func submitAudio(enqueue: (UInt64) -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard let generation = activeGeneration, acceptsAudio else { return false }
        enqueue(generation)
        return true
    }

    func submitFinal(enqueue: (UInt64) -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard let generation = activeGeneration, acceptsAudio else { return false }
        // Closing the gate before enqueueing makes duplicate finalization and audio sent
        // after the final marker deterministic, even when callers use different threads.
        acceptsAudio = false
        enqueue(generation)
        return true
    }

    func submitBarrier(enqueue: (UInt64) -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard let generation = activeGeneration else { return false }
        enqueue(generation)
        return true
    }
}

private final class SherpaFinalizationResolver: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<STTFinalizationStatus, Never>?

    init(_ continuation: CheckedContinuation<STTFinalizationStatus, Never>) {
        self.continuation = continuation
    }

    func resume(returning status: STTFinalizationStatus) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: status)
    }
}

final class SherpaSTTProvider: STTProvider, @unchecked Sendable {
    var capabilities: STTProviderCapabilities {
        STTProviderCapabilities(
            supportsStableUtteranceTiming: true,
            supportsCorrections: true,
            supportsFinalizationFlush: true
        )
    }

    private let callbackLock = NSLock()
    private var transcriptUpdateCallback: ((STTTranscriptUpdate) -> Void)?
    private var transcriptCorrectionCallback: (([STTTranscriptCorrection]) -> Void)?
    private var errorCallback: ((String) -> Void)?

    var onTranscriptUpdate: ((STTTranscriptUpdate) -> Void)? {
        get { withCallbackLock { transcriptUpdateCallback } }
        set { withCallbackLock { transcriptUpdateCallback = newValue } }
    }

    var onTranscriptCorrection: (([STTTranscriptCorrection]) -> Void)? {
        get { withCallbackLock { transcriptCorrectionCallback } }
        set { withCallbackLock { transcriptCorrectionCallback = newValue } }
    }

    var onError: ((String) -> Void)? {
        get { withCallbackLock { errorCallback } }
        set { withCallbackLock { errorCallback = newValue } }
    }

    private struct SessionCallbacks {
        let transcriptUpdate: ((STTTranscriptUpdate) -> Void)?
        let transcriptCorrection: (([STTTranscriptCorrection]) -> Void)?
        let error: ((String) -> Void)?
    }

    private struct SegmentRecord {
        let startMs: Int
        let endMs: Int
        let embedding: [Float]
        let provisionalSpeakerId: Int
    }

    private enum RuntimeConfiguration {
        case senseVoice(modelDirectory: URL, modelFileName: String)
        case funASRNano(modelDirectory: URL)
    }

    private struct RefinementSnapshot {
        let generation: UInt64
        let records: [SegmentRecord]
        let callback: (([STTTranscriptCorrection]) -> Void)?
    }

    static let sampleRate = 16_000
    static let fallbackDecodeSampleLimit = sampleRate * 30
    static let ringBufferTrimSlackSamples = sampleRate * 5
    private static let leadingContextSamples = Int(Double(sampleRate) * 0.5)

    private var runtime: SherpaOnnxRuntime?
    private var sessionGeneration: UInt64?
    private var sessionCallbacks: SessionCallbacks?
    private var ringBuffer: [Float] = []
    private var totalSamplesIngested: Int = 0
    private var emittedSegmentCount = 0
    private var lastEmittedEndSampleOffset = 0
    private var lastEmittedText = ""
    private var speakerCentroids: [(centroid: [Float], count: Int)] = []
    private var segmentLedger: [SegmentRecord] = []
    private let workQueue = DispatchQueue(label: "io.meetmemo.sherpa.stt", qos: .userInitiated)
    private let sessionGate = SherpaSessionGate()

    // Debug accounting (only meaningful when `debugLogging` is on). Lets us tell
    // whether swallowed words are dropped upstream by the VAD (low passed/ingested
    // ratio) or downstream by SenseVoice (high empty-decode count).
    private let debugLogging = UserDefaultsManager.shared.sherpaSTTDebugLogging
    private var vadSpeechSamples = 0
    private var emptyDecodeCount = 0
    private var fallbackDecodeCount = 0

    private let kind: SherpaRecognizerKind

    init(kind: SherpaRecognizerKind = .senseVoice) {
        self.kind = kind
    }

    private func withCallbackLock<T>(_ body: () -> T) -> T {
        callbackLock.lock()
        defer { callbackLock.unlock() }
        return body()
    }

    private func callbackSnapshot() -> SessionCallbacks {
        withCallbackLock {
            SessionCallbacks(
                transcriptUpdate: transcriptUpdateCallback,
                transcriptCorrection: transcriptCorrectionCallback,
                error: errorCallback
            )
        }
    }

    private func resolveRuntimeConfiguration() async throws -> RuntimeConfiguration {
        switch kind {
        case .senseVoice:
            return try await Task { @MainActor in
                try await SherpaModelManager.shared.ensureReadyForUse()
                return RuntimeConfiguration.senseVoice(
                    modelDirectory: SherpaModelManager.shared.modelDirectory,
                    modelFileName: SherpaModelManager.shared.activeSenseVoiceModelFileName
                )
            }.value
        case .funASRNano:
            return try await Task { @MainActor () throws -> RuntimeConfiguration in
                guard SherpaModelManager.shared.modelFilesReady(SherpaModelManager.funASRNanoModelFiles) else {
                    throw FunASRNanoError.modelsNotReady
                }
                return .funASRNano(modelDirectory: SherpaModelManager.shared.modelDirectory)
            }.value
        }
    }

    private func makeRuntime(
        configuration: RuntimeConfiguration,
        generation: UInt64
    ) async throws -> SherpaOnnxRuntime {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<SherpaOnnxRuntime, Error>) in
            let submitted = sessionGate.submitIfCurrent(generation) { [self] in
                workQueue.async { [self] in
                    guard sessionGate.isCurrent(generation) else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    do {
                        let runtime: SherpaOnnxRuntime
                        switch configuration {
                        case .senseVoice(let modelDirectory, let modelFileName):
                            runtime = try SherpaOnnxRuntime.make(
                                modelDirectory: modelDirectory,
                                senseVoiceModelFileName: modelFileName
                            )
                        case .funASRNano(let modelDirectory):
                            runtime = try SherpaOnnxRuntime.makeFunASRNano(modelDirectory: modelDirectory)
                        }
                        continuation.resume(returning: runtime)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            if !submitted {
                continuation.resume(throwing: CancellationError())
            }
        }
    }

    private func installRuntime(
        _ newRuntime: SherpaOnnxRuntime,
        callbacks: SessionCallbacks,
        generation: UInt64
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            let submitted = sessionGate.submitIfCurrent(generation) { [self] in
                workQueue.async { [self] in
                    let activated = sessionGate.activateIfCurrent(generation) {
                        runtime = newRuntime
                        sessionGeneration = generation
                        sessionCallbacks = callbacks
                    }
                    continuation.resume(returning: activated)
                }
            }
            if !submitted {
                continuation.resume(returning: false)
            }
        }
    }

    func connect(config: STTProviderConfig) async throws {
        _ = config
        let callbacks = callbackSnapshot()
        let generation = sessionGate.beginSession { [self] _ in
            workQueue.async { [self] in
                resetSessionStateOnWorkQueue()
            }
        }

        do {
            let runtimeConfiguration = try await resolveRuntimeConfiguration()
            try Task.checkCancellation()
            guard sessionGate.isCurrent(generation) else { throw CancellationError() }

            // Runtime creation can load several large models. Keep that synchronous work
            // off the caller's executor (normally the main actor) and on the same serial
            // queue that owns all subsequent runtime access.
            let newRuntime = try await makeRuntime(
                configuration: runtimeConfiguration,
                generation: generation
            )
            try Task.checkCancellation()

            let installed = await installRuntime(
                newRuntime,
                callbacks: callbacks,
                generation: generation
            )
            guard installed, sessionGate.isCurrent(generation) else {
                throw CancellationError()
            }
            try Task.checkCancellation()
        } catch {
            if !(error is CancellationError), sessionGate.isCurrent(generation) {
                await MainActor.run { [self] in
                    guard sessionGate.isCurrent(generation) else { return }
                    callbacks.error?(error.localizedDescription)
                }
            }
            sessionGate.invalidateIfCurrent(generation) { [self] in
                workQueue.async { [self] in
                    resetSessionStateOnWorkQueue()
                }
            }
            throw error
        }
    }

    func sendAudio(_ pcmData: Data) {
        _ = sessionGate.submitAudio { [self] generation in
            workQueue.async { [weak self] in
                guard let self,
                      self.sessionGate.isCurrent(generation),
                      self.sessionGeneration == generation,
                      let runtime = self.runtime else { return }
                self.processIncomingBytes(pcmData, runtime: runtime, generation: generation)
            }
        }
    }

    func sendLastAudio() {
        _ = sessionGate.submitFinal { [self] generation in
            workQueue.async { [weak self] in
                guard let self,
                      self.sessionGate.isCurrent(generation),
                      self.sessionGeneration == generation,
                      let runtime = self.runtime else { return }
                runtime.flushVAD()
                self.drainCompletedSegments(runtime: runtime, force: true, generation: generation)
            }
        }
    }

    func disconnect() {
        sessionGate.invalidate { [self] in
            workQueue.async { [self] in
                resetSessionStateOnWorkQueue()
            }
        }
    }

    private func resetSessionStateOnWorkQueue() {
        dispatchPrecondition(condition: .onQueue(workQueue))
        logDebugSummary()
        runtime = nil
        sessionGeneration = nil
        sessionCallbacks = nil
        ringBuffer.removeAll(keepingCapacity: false)
        totalSamplesIngested = 0
        emittedSegmentCount = 0
        lastEmittedEndSampleOffset = 0
        lastEmittedText = ""
        speakerCentroids.removeAll()
        segmentLedger.removeAll()
        vadSpeechSamples = 0
        emptyDecodeCount = 0
        fallbackDecodeCount = 0
    }

    private func logDebugSummary() {
        guard debugLogging, totalSamplesIngested > 0 else { return }
        let inputSeconds = Double(totalSamplesIngested) / Double(Self.sampleRate)
        let vadSeconds = Double(vadSpeechSamples) / Double(Self.sampleRate)
        let passedRatio = inputSeconds > 0 ? vadSeconds / inputSeconds : 0
        print(String(
            format: "🔎 SenseVoice session: input %.1fs | VAD-passed %.1fs (%.0f%%) | segments %d | empty-decodes %d | fallback %d",
            inputSeconds, vadSeconds, passedRatio * 100, emittedSegmentCount, emptyDecodeCount, fallbackDecodeCount
        ))
    }

    func testConnection(config: STTProviderConfig, timeout: TimeInterval) async throws {
        try await Task { @MainActor in
            try await SherpaModelManager.shared.ensureReadyForUse()
        }.value
    }

    func awaitPendingFinalization(timeout: TimeInterval) async -> STTFinalizationStatus {
        await Self.waitForFinalization(timeout: timeout) { [self] completion in
            sessionGate.submitBarrier { [self] _ in
                // Submission is made while the lifecycle gate is locked, so this marker
                // cannot jump ahead of a racing final-audio or disconnect operation.
                workQueue.async {
                    completion()
                }
            }
        }
    }

    func applyOfflineRefinement() async {
        let snapshot: RefinementSnapshot? = await withCheckedContinuation { continuation in
            let submitted = sessionGate.submitBarrier { [self] generation in
                workQueue.async { [self] in
                    guard sessionGate.isCurrent(generation),
                          sessionGeneration == generation else {
                        continuation.resume(returning: nil)
                        return
                    }
                    continuation.resume(returning: RefinementSnapshot(
                        generation: generation,
                        records: segmentLedger,
                        callback: sessionCallbacks?.transcriptCorrection
                    ))
                }
            }
            if !submitted {
                continuation.resume(returning: nil)
            }
        }
        guard let snapshot, snapshot.records.count >= 2 else { return }

        let embeddings = snapshot.records.map { $0.embedding }
        let refined = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: SpeakerClustering.refineOffline(embeddings: embeddings))
            }
        }

        var corrections: [STTTranscriptCorrection] = []
        for (record, newId) in zip(snapshot.records, refined) {
            if newId != record.provisionalSpeakerId {
                corrections.append(STTTranscriptCorrection(
                    startTime: record.startMs,
                    endTime: record.endMs,
                    newSpeakerId: newId,
                    newSpeakerTag: Self.speakerTag(forId: newId)
                ))
            }
        }
        guard !corrections.isEmpty else { return }
        let finalizedCorrections = corrections
        await MainActor.run { [self] in
            guard sessionGate.isCurrent(snapshot.generation) else { return }
            snapshot.callback?(finalizedCorrections)
        }
    }

    /// Waits for a queue marker or a deadline, whichever wins. The resolver is one-shot,
    /// so returning on timeout never waits for (or cancels) a potentially blocked queue
    /// operation; a late marker simply becomes a no-op.
    static func waitForFinalization(
        timeout: TimeInterval,
        schedule: (@escaping () -> Void) -> Bool
    ) async -> STTFinalizationStatus {
        await withCheckedContinuation { continuation in
            let resolver = SherpaFinalizationResolver(continuation)
            let scheduled = schedule {
                resolver.resume(returning: .completed)
            }
            guard scheduled else {
                resolver.resume(returning: .completed)
                return
            }
            guard timeout.isFinite, timeout > 0 else {
                resolver.resume(returning: .finalizeTimedOut)
                return
            }

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                resolver.resume(returning: .finalizeTimedOut)
            }
        }
    }

    // MARK: - Audio handling (runs on workQueue)

    static func ringBufferRemovalCount(forSampleCount sampleCount: Int) -> Int {
        let trimThreshold = fallbackDecodeSampleLimit + ringBufferTrimSlackSamples
        guard sampleCount > trimThreshold else { return 0 }
        return max(0, sampleCount - fallbackDecodeSampleLimit)
    }

    private func processIncomingBytes(
        _ data: Data,
        runtime: SherpaOnnxRuntime,
        generation: UInt64
    ) {
        guard sessionGate.isCurrent(generation), sessionGeneration == generation else { return }
        let sampleCount = data.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return }

        var floats = [Float](repeating: 0, count: sampleCount)
        data.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.bindMemory(to: Int16.self).baseAddress else { return }
            let scale: Float = 1.0 / Float(Int16.max)
            for i in 0..<sampleCount {
                floats[i] = Float(base[i]) * scale
            }
        }

        guard sessionGate.isCurrent(generation), sessionGeneration == generation else { return }
        totalSamplesIngested += sampleCount
        ringBuffer.append(contentsOf: floats)
        let removalCount = Self.ringBufferRemovalCount(forSampleCount: ringBuffer.count)
        if removalCount > 0 {
            // Keep a small slack window so `removeFirst` moves the retained samples only
            // every few seconds rather than once for every 20 ms audio packet.
            ringBuffer.removeFirst(removalCount)
        }

        runtime.acceptWaveform(floats)
        drainCompletedSegments(runtime: runtime, force: false, generation: generation)
    }

    private func drainCompletedSegments(
        runtime: SherpaOnnxRuntime,
        force: Bool,
        generation: UInt64
    ) {
        guard sessionGate.isCurrent(generation), sessionGeneration == generation else { return }
        let segmentsBeforeDrain = emittedSegmentCount
        while sessionGate.isCurrent(generation),
              sessionGeneration == generation,
              let segment = runtime.nextCompletedSegment(force: force) {
            guard sessionGate.isCurrent(generation), sessionGeneration == generation else { return }
            vadSpeechSamples += segment.samples.count
            handle(
                segment: segmentWithLeadingContext(segment, runtime: runtime),
                runtime: runtime,
                generation: generation
            )
        }
        if force,
           sessionGate.isCurrent(generation),
           sessionGeneration == generation,
           emittedSegmentCount == segmentsBeforeDrain,
           let segment = makeUnemittedFallbackSegment(runtime: runtime) {
            // 兜底解码用于捕捉 VAD 没切出来的尾音。但停止时若上一轮 drain 已发出该段
            // （例如补静音封口了 VAD 段），fallback 会从段尾重解码同一句语音、时间戳却不同，
            // 导致重复转写。文本与上一条已发出 final 相同则跳过。
            let fallbackText = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !fallbackText.isEmpty, fallbackText != lastEmittedText else { return }
            fallbackDecodeCount += 1
            handle(segment: segment, runtime: runtime, generation: generation)
        }
    }

    private func makeUnemittedFallbackSegment(runtime: SherpaOnnxRuntime) -> SherpaOnnxRuntime.Segment? {
        guard !ringBuffer.isEmpty else { return nil }

        let historyStartOffset = totalSamplesIngested - ringBuffer.count
        // The buffer may temporarily hold the 30-second decode window plus trim slack.
        // Never feed that slack to the fallback recognizer; it exists only to amortize
        // array compaction.
        let boundedWindowStartOffset = max(
            historyStartOffset,
            totalSamplesIngested - Self.fallbackDecodeSampleLimit
        )
        let fallbackStartOffset = max(boundedWindowStartOffset, lastEmittedEndSampleOffset)
        let startIndex = fallbackStartOffset - historyStartOffset
        guard startIndex >= 0, startIndex < ringBuffer.count else { return nil }

        let tailSamples = Array(ringBuffer[startIndex...])
        return runtime.decodeFallbackSegment(
            samples: tailSamples,
            startSampleOffset: fallbackStartOffset
        )
    }

    private func segmentWithLeadingContext(
        _ segment: SherpaOnnxRuntime.Segment,
        runtime: SherpaOnnxRuntime
    ) -> SherpaOnnxRuntime.Segment {
        let historyStartOffset = totalSamplesIngested - ringBuffer.count
        let contextStartOffset = max(
            historyStartOffset,
            lastEmittedEndSampleOffset,
            segment.startSampleOffset - Self.leadingContextSamples
        )
        guard contextStartOffset < segment.startSampleOffset else {
            return segment
        }

        let prefixStartIndex = contextStartOffset - historyStartOffset
        let prefixEndIndex = segment.startSampleOffset - historyStartOffset
        guard prefixStartIndex >= 0,
              prefixEndIndex <= ringBuffer.count,
              prefixStartIndex < prefixEndIndex else {
            return segment
        }

        let expandedSamples = Array(ringBuffer[prefixStartIndex..<prefixEndIndex]) + segment.samples
        let expanded = runtime.decodeFallbackSegment(
            samples: expandedSamples,
            startSampleOffset: contextStartOffset
        )
        return expanded.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? segment : expanded
    }

    private func handle(
        segment: SherpaOnnxRuntime.Segment,
        runtime: SherpaOnnxRuntime,
        generation: UInt64
    ) {
        guard sessionGate.isCurrent(generation), sessionGeneration == generation else { return }
        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            emptyDecodeCount += 1
            return
        }

        let embedding = runtime.embedding(for: segment.samples)
        guard sessionGate.isCurrent(generation), sessionGeneration == generation else { return }

        emittedSegmentCount += 1
        lastEmittedEndSampleOffset = max(lastEmittedEndSampleOffset, segment.endSampleOffset)
        lastEmittedText = text
        let speakerId = SpeakerClustering.assignOnline(
            embedding: embedding,
            centroids: &speakerCentroids
        )

        let startMs = Int(Double(segment.startSampleOffset) * 1000.0 / Double(Self.sampleRate))
        let endMs = Int(Double(segment.endSampleOffset) * 1000.0 / Double(Self.sampleRate))
        let tag = speakerId.map { Self.speakerTag(forId: $0) }

        // The embedding extractor can transiently return an empty vector while it
        // is not ready. Keep the transcript, but exclude that segment from speaker
        // refinement because it has no reliable diarization data.
        if let speakerId {
            segmentLedger.append(SegmentRecord(
                startMs: startMs,
                endMs: endMs,
                embedding: embedding,
                provisionalSpeakerId: speakerId
            ))
        }

        let update = STTTranscriptUpdate(
            text: text,
            isFinal: true,
            speakerTag: tag,
            speakerId: speakerId,
            startTime: startMs,
            endTime: endMs
        )

        let callback = sessionCallbacks?.transcriptUpdate
        DispatchQueue.main.async { [weak self] in
            guard let self, self.sessionGate.isCurrent(generation) else { return }
            callback?(update)
        }
    }

    private static func speakerTag(forId id: Int) -> String {
        let displayId = id + 1
        return LanguageManager.shared.t("发言人 \(displayId)", "Speaker \(displayId)")
    }
}

final class SherpaSTTProviderFactory: STTProviderFactory {
    private let kind: SherpaRecognizerKind

    init(kind: SherpaRecognizerKind = .senseVoice) {
        self.kind = kind
    }

    func makeProvider() -> STTProvider {
        SherpaSTTProvider(kind: kind)
    }
}
