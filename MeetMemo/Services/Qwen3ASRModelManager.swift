import Foundation

/// Installs and verifies the sherpa-onnx Qwen3-ASR-0.6B INT8 model used for
/// post-recording accurate transcription and offline cloud-failure recovery.
///
/// Qwen is deliberately not a live meeting `STTEngine`: `AudioManager` owns one
/// provider per source, and loading two 1 GB generative recognizers would waste memory
/// on 16 GB Macs. Post-recording callers process mic and system tracks sequentially.
@MainActor
final class Qwen3ASRModelManager: ObservableObject {
    static let shared = Qwen3ASRModelManager()

    @Published private(set) var isPreparing = false
    @Published private(set) var isReady = false
    @Published private(set) var downloadProgress: Double?
    @Published var errorMessage: String?

    private init() {
        Task { await refreshReadiness() }
    }

    func refreshReadiness() async {
        let directory = SherpaModelManager.shared.modelDirectory
        let files = SherpaModelManager.qwen3ASRModelFiles
        isReady = await Task.detached(priority: .utility) {
            SherpaModelManager.modelFilesReady(files, at: directory)
        }.value
    }

    func ensureReadyForUse() async throws {
        if isReady { return }
        await refreshReadiness()
        guard isReady else { throw Qwen3ASRError.modelsNotReady }
    }

    func prepareModels() async {
        guard !isPreparing else { return }
        isPreparing = true
        downloadProgress = 0
        errorMessage = nil
        defer {
            isPreparing = false
            downloadProgress = nil
        }

        do {
            try await SherpaModelManager.shared.downloadModelFiles(
                SherpaModelManager.qwen3ASRModelFiles
            ) { [weak self] progress in
                self?.downloadProgress = progress
            }
            await refreshReadiness()
            if !isReady {
                errorMessage = LanguageManager.shared.t(
                    "Qwen3-ASR 模型下载后完整性校验未通过，请重试。",
                    "Qwen3-ASR models failed integrity verification after download. Please retry."
                )
            }
        } catch is CancellationError {
            errorMessage = LanguageManager.shared.t(
                "Qwen3-ASR 模型下载已暂停，下次会从断点继续。",
                "Qwen3-ASR download paused. The next attempt will resume it."
            )
        } catch {
            isReady = false
            errorMessage = ErrorHandler.shared.handleError(error)
        }
    }

    var cacheSizeText: String {
        let bytes = Self.directorySize(SherpaModelManager.shared.qwen3ASRDirectory)
        guard bytes > 0 else { return "0 MB" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    var installSizeText: String {
        let bytes = SherpaModelManager.qwen3ASRModelFiles.reduce(Int64(0)) {
            $0 + $1.approximateBytes
        }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(size)
        }
        return total
    }
}

enum Qwen3ASRError: LocalizedError {
    case modelsNotReady

    var errorDescription: String? {
        switch self {
        case .modelsNotReady:
            return LanguageManager.shared.t(
                "Qwen3-ASR 模型尚未就绪。请先在设置中下载并校验本地模型。",
                "Qwen3-ASR models are not ready. Download and verify them in Settings first."
            )
        }
    }
}
