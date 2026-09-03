import CryptoKit
import Foundation

/// Manages the local sherpa-onnx model files (SenseVoice, Silero VAD, speaker embedding)
/// that back the `.sherpaSenseVoice` STT engine. Mirrors `SpeechModelInstaller` so the
/// settings UI can stay symmetrical between engines.
@MainActor
final class SherpaModelManager: ObservableObject {
    static let shared = SherpaModelManager()

    @Published var isReady = false
    @Published var isDownloading = false
    @Published var downloadProgress: Double?
    @Published var installError: String?

    struct ModelFile: Sendable {
        let key: String              // logical identifier used by the provider
        let fileName: String         // on-disk name (under modelDirectory)
        let urls: [URL]              // remote sources, tried in order
        let approximateBytes: Int64  // for weighted progress aggregation
        let sha256: String?          // optional integrity check, nil to skip
    }

    /// File list is intentionally small: SenseVoice (model + tokens), Silero VAD,
    /// and a CAM++-style speaker embedding extractor. Mirrors what
    /// `SherpaSTTProvider` will load at connect time.
    static let senseVoiceModel = ModelFile(
        key: "sense_voice_model",
        fileName: "sense-voice-small.int8.onnx",
        urls: [
            URL(string: "https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/2365baeacb507f821a0c8120fcee3d484dba7a07/model.int8.onnx")!,
            URL(string: "https://hf-mirror.com/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/2365baeacb507f821a0c8120fcee3d484dba7a07/model.int8.onnx")!,
            URL(string: "https://file.348580.xyz/drive/MeetMemo-SenseVoice-models/sense-voice-small.int8.onnx")!,
        ],
        approximateBytes: 239_233_841,
        sha256: "c71f0ce00bec95b07744e116345e33d8cbbe08cef896382cf907bf4b51a2cd51"
    )

    static let tokensModelFile = ModelFile(
        key: "sense_voice_tokens",
        fileName: "tokens.txt",
        urls: [
            URL(string: "https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/2365baeacb507f821a0c8120fcee3d484dba7a07/tokens.txt")!,
            URL(string: "https://hf-mirror.com/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/2365baeacb507f821a0c8120fcee3d484dba7a07/tokens.txt")!,
            URL(string: "https://file.348580.xyz/drive/MeetMemo-SenseVoice-models/tokens.txt")!,
        ],
        approximateBytes: 315_894,
        sha256: "f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc"
    )

    /// Silero VAD — shared by both the SenseVoice and Fun-ASR-Nano pipelines.
    static let vadModelFile = ModelFile(
        key: "vad",
        fileName: "silero-vad.onnx",
        urls: [
            URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx")!,
            URL(string: "https://file.348580.xyz/drive/MeetMemo-SenseVoice-models/silero-vad.onnx")!,
        ],
        approximateBytes: 643_854,
        sha256: "9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6"
    )

    /// CAM++ speaker embedding extractor — shared for diarization in both pipelines.
    static let speakerEmbeddingModelFile = ModelFile(
        key: "speaker_embedding",
        fileName: "3dspeaker-cam-plus.onnx",
        urls: [
            URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx")!,
            URL(string: "https://file.348580.xyz/drive/MeetMemo-SenseVoice-models/3dspeaker-cam-plus.onnx")!,
        ],
        approximateBytes: 28_281_138,
        sha256: "f682b514c05d947ee3fa91cd6ec6c5c7543479a128373fa29b1faedccd21fd11"
    )

    static let sharedModelFiles: [ModelFile] = [
        tokensModelFile,
        vadModelFile,
        speakerEmbeddingModelFile,
    ]

    /// Fun-ASR-Nano (int8) real-time STT engine model. The ASR weights live under
    /// a `funasr-nano/` subdirectory; Silero VAD + CAM++ are reused from the shared set so
    /// diarization comes for free. ~1 GB total.
    private static let funASRNanoRevision = "6f16bd378457e13f36ccf3910df9017f96c346fb"

    static func funASRNanoFile(
        _ name: String,
        _ approximateBytes: Int64,
        sha256: String
    ) -> ModelFile {
        let repository = "csukuangfj/sherpa-onnx-funasr-nano-int8-2025-12-30"
        return ModelFile(
            key: "funasr_nano_\(name)",
            fileName: "funasr-nano/\(name)",
            urls: [
                URL(string: "https://huggingface.co/\(repository)/resolve/\(funASRNanoRevision)/\(name)")!,
                URL(string: "https://hf-mirror.com/\(repository)/resolve/\(funASRNanoRevision)/\(name)")!,
            ],
            approximateBytes: approximateBytes,
            sha256: sha256
        )
    }

    static let funASRNanoModelFiles: [ModelFile] = [
        funASRNanoFile(
            "encoder_adaptor.int8.onnx",
            237_792_748,
            sha256: "f36dea2e30fbc33b5db1d7a7265cc976c5e5586c77b042d5adb1ad27c72db422"
        ),
        funASRNanoFile(
            "embedding.int8.onnx",
            155_584_380,
            sha256: "95e61cd0c9c3b9543339a4cf973c95c116815e745ccc1e0285cbd81f76d18644"
        ),
        funASRNanoFile(
            "llm.int8.onnx",
            600_356_593,
            sha256: "dfbf9aa3be41bccc257587f151e15c63fbe1b549f2b517f5ccd5bdce3bf4322a"
        ),
        funASRNanoFile(
            "Qwen3-0.6B/tokenizer.json",
            11_422_654,
            sha256: "aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4"
        ),
        funASRNanoFile(
            "Qwen3-0.6B/vocab.json",
            2_776_833,
            sha256: "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"
        ),
        funASRNanoFile(
            "Qwen3-0.6B/merges.txt",
            1_671_853,
            sha256: "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5"
        ),
        vadModelFile,
        speakerEmbeddingModelFile,
    ]

    /// Qwen3-ASR-0.6B INT8 exported for sherpa-onnx. ModelScope is first because it
    /// provides a fast mainland-China CDN and supports HTTP Range requests. hf-mirror
    /// and the upstream Hugging Face repository are deterministic fallbacks containing
    /// the exact same, SHA-verified artifacts.
    private static func qwen3ASRFile(
        localName: String,
        remoteName: String,
        approximateBytes: Int64,
        sha256: String
    ) -> ModelFile {
        let upstreamRepository = "csukuangfj2/sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25"
        let upstreamRevision = "68818b2313fe77bd06f6a7c5068ff3ef59d02b8a"
        let modelScopeRevision = "9c182309f7bb075f241424441add9e16c5086dfb"
        return ModelFile(
            key: "qwen3_asr_\(localName.replacingOccurrences(of: "/", with: "_"))",
            fileName: "qwen3-asr/\(localName)",
            urls: [
                URL(string: "https://modelscope.cn/models/zengshuishui/Qwen3-ASR-onnx/resolve/\(modelScopeRevision)/\(remoteName)")!,
                URL(string: "https://hf-mirror.com/\(upstreamRepository)/resolve/\(upstreamRevision)/\(localName)")!,
                URL(string: "https://huggingface.co/\(upstreamRepository)/resolve/\(upstreamRevision)/\(localName)")!,
            ],
            approximateBytes: approximateBytes,
            sha256: sha256
        )
    }

    static let qwen3ASRCoreModelFiles: [ModelFile] = [
        qwen3ASRFile(
            localName: "conv_frontend.onnx",
            remoteName: "model_0.6B/conv_frontend.onnx",
            approximateBytes: 44_148_281,
            sha256: "d22dc4423e0940e49884e903d2ea2f7e5567c14fc1aed97e4e26d6b8f208ef9e"
        ),
        qwen3ASRFile(
            localName: "encoder.int8.onnx",
            remoteName: "model_0.6B/encoder.int8.onnx",
            approximateBytes: 182_491_662,
            sha256: "60748d3e6744a57c9c91e1b17424a6c2990567e8adceb0783940c03ed98fa9d9"
        ),
        qwen3ASRFile(
            localName: "decoder.int8.onnx",
            remoteName: "model_0.6B/decoder.int8.onnx",
            approximateBytes: 755_914_231,
            sha256: "4f6885be5959ae26af3089d38ee7972c5fafbeeb1cf8d5e76eab6d8b61ca5771"
        ),
        qwen3ASRFile(
            localName: "tokenizer/merges.txt",
            remoteName: "tokenizer/merges.txt",
            approximateBytes: 1_671_853,
            sha256: "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5"
        ),
        qwen3ASRFile(
            localName: "tokenizer/tokenizer_config.json",
            remoteName: "tokenizer/tokenizer_config.json",
            approximateBytes: 12_487,
            sha256: "4942d005604266809309cabc9f4e9cb89ce855d59b14681fdc0e1cc62ea26c4c"
        ),
        qwen3ASRFile(
            localName: "tokenizer/vocab.json",
            remoteName: "tokenizer/vocab.json",
            approximateBytes: 2_776_833,
            sha256: "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"
        ),
    ]

    /// Qwen is generative, so its local installation also guarantees that the existing
    /// non-generative SenseVoice recognizer and Silero VAD are present for quality-gate
    /// recovery. Every file in this set has an exact size; Qwen, SenseVoice and VAD also
    /// have pinned SHA-256 digests before any model is loaded by the native runtime.
    static let qwen3ASRModelFiles: [ModelFile] = qwen3ASRCoreModelFiles + [
        senseVoiceModel,
        tokensModelFile,
        vadModelFile,
    ]

    /// Absolute path to the directory holding the Fun-ASR-Nano weights + tokenizer.
    var funASRNanoDirectory: URL {
        modelDirectory.appendingPathComponent("funasr-nano", isDirectory: true)
    }

    /// Absolute path to Qwen3-ASR's ONNX weights and tokenizer.
    var qwen3ASRDirectory: URL {
        modelDirectory.appendingPathComponent("qwen3-asr", isDirectory: true)
    }

    static let senseVoiceModelFiles: [ModelFile] = [senseVoiceModel] + sharedModelFiles

    let modelDirectory: URL
    private var activeDownloadSession: URLSession?
    private var isModelSetDownloadInProgress = false

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.modelDirectory = base.appendingPathComponent("MeetMemo/sherpa-onnx", isDirectory: true)
        try? FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        Task { await self.refreshReadiness() }
    }

    func localURL(forKey key: String) -> URL? {
        guard let model = Self.senseVoiceModelFiles.first(where: { $0.key == key }) else { return nil }
        return modelDirectory.appendingPathComponent(model.fileName)
    }

    var activeSenseVoiceModelFileName: String {
        Self.senseVoiceModel.fileName
    }

    var activeApproximateBytes: Int64 {
        Self.senseVoiceModelFiles.reduce(Int64(0)) { $0 + $1.approximateBytes }
    }

    /// Pure check: are all the given files present on disk (and SHA-matched, if provided)?
    func modelFilesReady(_ files: [ModelFile]) -> Bool {
        Self.modelFilesReady(files, at: modelDirectory)
    }

    /// Thread-safe model verification used by large model managers off the main actor.
    /// Full SHA-256 validation is intentionally performed here: merely checking a path or
    /// byte count would allow a truncated/corrupted ONNX file to crash native code later.
    nonisolated static func modelFilesReady(_ files: [ModelFile], at directory: URL) -> Bool {
        for model in files {
            let url = directory.appendingPathComponent(model.fileName)
            guard FileManager.default.fileExists(atPath: url.path) else { return false }
            guard let actualBytes = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  Int64(actualBytes) == model.approximateBytes else {
                return false
            }
            if let expected = model.sha256 {
                if (try? Self.sha256Hex(of: url)) != expected.lowercased() {
                    return false
                }
            }
        }
        return true
    }

    /// Re-checks whether every required SenseVoice file is present on disk.
    func refreshReadiness() async {
        let directory = modelDirectory
        let files = Self.senseVoiceModelFiles
        isReady = await Task.detached(priority: .utility) {
            Self.modelFilesReady(files, at: directory)
        }.value
    }

    /// Guarantees every model file is on disk and (optionally) hash-verified.
    /// Throws if the user cancels or any file download fails.
    func ensureReadyForUse() async throws {
        await refreshReadiness()
        if isReady { return }
        try await installModelsIfNeeded()
        await refreshReadiness()
        guard isReady else {
            throw SherpaModelError.notReady
        }
    }

    /// Public entry point for the Settings UI "Install" button (SenseVoice).
    func installModelsIfNeeded() async throws {
        if isDownloading {
            while isDownloading { try? await Task.sleep(for: .milliseconds(250)) }
            return
        }

        isDownloading = true
        downloadProgress = 0
        installError = nil
        defer {
            isDownloading = false
            downloadProgress = nil
        }

        try await downloadModelFiles(Self.senseVoiceModelFiles) { [weak self] progress in
            self?.downloadProgress = progress
        }
    }

    /// Generic downloader shared by the SenseVoice and Fun-ASR-Nano pipelines. Reports
    /// aggregate [0, 1] progress through `onProgress` instead of mutating `self`, so each
    /// caller (with its own `@Published` state) stays isolated. Sets `installError` and
    /// throws on the first failed file.
    func downloadModelFiles(
        _ files: [ModelFile],
        onProgress: @escaping @MainActor (Double) -> Void
    ) async throws {
        // All model managers share the same destination tree and active URL session.
        // Serialize complete installs so two Settings buttons cannot race over `.part`
        // files or cancel each other's URLSession.
        while isModelSetDownloadInProgress {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(200))
        }
        isModelSetDownloadInProgress = true
        defer { isModelSetDownloadInProgress = false }

        let totalBytes = files.reduce(Int64(0)) { $0 + $1.approximateBytes }
        var completedBytes: Int64 = 0

        for model in files {
            let destination = modelDirectory.appendingPathComponent(model.fileName)
            if FileManager.default.fileExists(atPath: destination.path) {
                let actualBytes = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                let sizeMatches = actualBytes.map { Int64($0) == model.approximateBytes } ?? false
                let hashMatches: Bool
                if let expected = model.sha256,
                   sizeMatches {
                    hashMatches = await Task.detached(priority: .utility) {
                        (try? Self.sha256Hex(of: destination)) == expected.lowercased()
                    }.value
                } else {
                    hashMatches = false
                }
                if model.sha256 != nil, sizeMatches, hashMatches {
                    completedBytes += model.approximateBytes
                    onProgress(Double(completedBytes) / Double(totalBytes))
                    continue
                } else if model.sha256 == nil, sizeMatches {
                    completedBytes += model.approximateBytes
                    onProgress(Double(completedBytes) / Double(totalBytes))
                    continue
                } else {
                    try? FileManager.default.removeItem(at: destination)
                }
            }

            do {
                try await downloadFile(
                    model: model,
                    destination: destination,
                    completedBaseBytes: completedBytes,
                    totalBytes: totalBytes,
                    onProgress: onProgress
                )
                completedBytes += model.approximateBytes
                onProgress(Double(completedBytes) / Double(totalBytes))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let message = LanguageManager.shared.t(
                    "下载 \(model.fileName) 失败:\(error.localizedDescription)",
                    "Failed to download \(model.fileName): \(error.localizedDescription)"
                )
                installError = message
                throw SherpaModelError.downloadFailed(model.fileName, error.localizedDescription)
            }
        }
    }

    func cancelDownload() {
        activeDownloadSession?.invalidateAndCancel()
        activeDownloadSession = nil
    }

    // MARK: - Private

    private func downloadFile(
        model: ModelFile,
        destination: URL,
        completedBaseBytes: Int64,
        totalBytes: Int64,
        onProgress: @escaping @MainActor (Double) -> Void
    ) async throws {
        var lastError: Error?
        for url in model.urls {
            do {
                try await downloadFile(
                    from: url,
                    model: model,
                    destination: destination,
                    completedBaseBytes: completedBaseBytes,
                    totalBytes: totalBytes,
                    onProgress: onProgress
                )
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if let urlError = error as? URLError, urlError.code == .cancelled {
                    throw CancellationError()
                }
                lastError = error
            }
        }
        throw lastError ?? SherpaModelError.downloadFailed(model.fileName, "No download source available")
    }

    private func downloadFile(
        from url: URL,
        model: ModelFile,
        destination: URL,
        completedBaseBytes: Int64,
        totalBytes: Int64,
        onProgress: @escaping @MainActor (Double) -> Void
    ) async throws {
        // Files may live in subdirectories (e.g. funasr-nano/Qwen3-0.6B/tokenizer.json).
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let temp = destination.appendingPathExtension("part")
        var resumeOffset = (try? FileManager.default.attributesOfItem(atPath: temp.path)[.size] as? Int64) ?? 0

        // A previous run may have downloaded and verified every byte but been terminated
        // before the final atomic rename. Finish that install locally instead of issuing an
        // invalid `Range: bytes=<size>-` request (which normally returns HTTP 416).
        if resumeOffset == model.approximateBytes {
            let isVerified: Bool
            if let expectedSha = model.sha256 {
                let actualSha = try await Task.detached(priority: .utility) {
                    try Self.sha256Hex(of: temp)
                }.value
                isVerified = actualSha == expectedSha.lowercased()
            } else {
                // Legacy Fun-ASR artifacts do not publish digests in this manifest;
                // their exact pinned byte size is still enforced before installation.
                isVerified = true
            }
            if isVerified {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: temp, to: destination)
                return
            }
            try? FileManager.default.removeItem(at: temp)
            resumeOffset = 0
        }

        if resumeOffset < 0 || resumeOffset > model.approximateBytes {
            try? FileManager.default.removeItem(at: temp)
            resumeOffset = 0
        }

        let delegate = ModelDownloadDelegate(
            tempURL: temp,
            resumeOffset: resumeOffset,
            maximumTotalBytes: model.approximateBytes
        ) { receivedBytes, expectedBytes in
            let expected = max(expectedBytes, model.approximateBytes)
            let fraction = (Double(completedBaseBytes) + Double(receivedBytes) * Double(model.approximateBytes) / Double(max(1, expected))) / Double(totalBytes)
            Task { @MainActor in
                onProgress(min(0.99, max(0, fraction)))
            }
        }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 60 * 60
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: queue)
        activeDownloadSession = session
        defer {
            if activeDownloadSession === session {
                activeDownloadSession = nil
            }
            session.finishTasksAndInvalidate()
        }

        var request = URLRequest(url: url)
        if resumeOffset > 0 {
            request.setValue("bytes=\(resumeOffset)-", forHTTPHeaderField: "Range")
        }

        let response = try await delegate.download(request, using: session)
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            // URLSessionDownloadDelegate has already moved the response body. A 4xx/5xx
            // HTML page must not become the prefix for a Range request to the next mirror.
            try? FileManager.default.removeItem(at: temp)
            throw SherpaModelError.httpError((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        if resumeOffset > 0, httpResponse.statusCode == 206 {
            let expectedPrefix = "bytes \(resumeOffset)-"
            guard httpResponse.value(forHTTPHeaderField: "Content-Range")?.lowercased()
                .hasPrefix(expectedPrefix.lowercased()) == true else {
                try? FileManager.default.removeItem(at: temp)
                throw SherpaModelError.invalidContentRange(model.fileName)
            }
        }

        let downloadedBytes = Int64(
            (try temp.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
        )
        guard downloadedBytes == model.approximateBytes else {
            try? FileManager.default.removeItem(at: temp)
            throw SherpaModelError.unexpectedFileSize(
                model.fileName,
                expected: model.approximateBytes,
                actual: downloadedBytes
            )
        }
        if let expectedSha = model.sha256 {
            let actual = try await Task.detached(priority: .utility) {
                try Self.sha256Hex(of: temp)
            }.value
            if actual != expectedSha.lowercased() {
                try? FileManager.default.removeItem(at: temp)
                throw SherpaModelError.integrityCheckFailed(model.fileName)
            }
        }

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temp, to: destination)
    }

    nonisolated private static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = handle.readData(ofLength: 1024 * 1024)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private final class ModelDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let tempURL: URL
    private let resumeOffset: Int64
    private let maximumTotalBytes: Int64
    private let progressHandler: @Sendable (Int64, Int64) -> Void
    private var continuation: CheckedContinuation<URLResponse?, Error>?
    private var fileMoveError: Error?

    init(
        tempURL: URL,
        resumeOffset: Int64,
        maximumTotalBytes: Int64,
        progressHandler: @escaping @Sendable (Int64, Int64) -> Void
    ) {
        self.tempURL = tempURL
        self.resumeOffset = resumeOffset
        self.maximumTotalBytes = maximumTotalBytes
        self.progressHandler = progressHandler
    }

    func download(_ request: URLRequest, using session: URLSession) async throws -> URLResponse? {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                session.downloadTask(with: request).resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let responseBase = (downloadTask.response as? HTTPURLResponse)?.statusCode == 206
            ? resumeOffset
            : 0
        let (total, totalOverflow) = responseBase.addingReportingOverflow(totalBytesWritten)
        guard !totalOverflow, total >= 0, total <= maximumTotalBytes else {
            fileMoveError = SherpaModelError.unexpectedFileSize(
                tempURL.lastPathComponent,
                expected: maximumTotalBytes,
                actual: totalOverflow ? Int64.max : total
            )
            downloadTask.cancel()
            return
        }
        let expectedFromServer = max(0, totalBytesExpectedToWrite)
        let (expectedTotal, expectedOverflow) = responseBase.addingReportingOverflow(expectedFromServer)
        progressHandler(total, expectedOverflow ? maximumTotalBytes : expectedTotal)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            let statusCode = (downloadTask.response as? HTTPURLResponse)?.statusCode
            if resumeOffset > 0, statusCode == 206 {
                let input = try FileHandle(forReadingFrom: location)
                defer { try? input.close() }
                let output = try FileHandle(forWritingTo: tempURL)
                defer { try? output.close() }
                try output.seekToEnd()
                while true {
                    let chunk = input.readData(ofLength: 1024 * 1024)
                    if chunk.isEmpty { break }
                    output.write(chunk)
                }
            } else {
                try? FileManager.default.removeItem(at: tempURL)
                try FileManager.default.moveItem(at: location, to: tempURL)
            }
        } catch {
            fileMoveError = error
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let fileMoveError {
            continuation?.resume(throwing: fileMoveError)
        } else if let error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume(returning: task.response)
        }
        continuation = nil
    }
}

enum SherpaModelError: LocalizedError {
    case notReady
    case downloadFailed(String, String)
    case httpError(Int)
    case integrityCheckFailed(String)
    case invalidContentRange(String)
    case unexpectedFileSize(String, expected: Int64, actual: Int64)

    var errorDescription: String? {
        let lang = LanguageManager.shared
        switch self {
        case .notReady:
            return lang.t(
                "SenseVoice 模型尚未就绪,请先在设置中下载本地语音识别模型。",
                "SenseVoice models are not ready. Download the local speech recognition models from Settings first."
            )
        case .downloadFailed(let file, let detail):
            return lang.t("下载 \(file) 失败:\(detail)", "Failed to download \(file): \(detail)")
        case .httpError(let code):
            return lang.t("下载失败,HTTP \(code)", "Download failed with HTTP \(code)")
        case .integrityCheckFailed(let file):
            return lang.t("\(file) 校验失败,可能损坏。请重试。", "\(file) failed integrity check; please retry.")
        case .invalidContentRange(let file):
            return lang.t(
                "\(file) 的断点续传响应无效，已清理临时文件，请重试。",
                "Invalid resume response for \(file). The partial file was removed; please retry."
            )
        case .unexpectedFileSize(let file, let expected, let actual):
            return lang.t(
                "\(file) 文件大小异常（期望 \(expected) 字节，实际 \(actual) 字节），已停止下载。",
                "Unexpected size for \(file) (expected \(expected) bytes, got \(actual)); download stopped."
            )
        }
    }
}
