import Foundation

// MARK: - Public domain models

struct AliyunFileTranscriptionOptions: Hashable, Sendable {
    static let defaultModel = "qwen-audio-3.0-asr-flash-filetrans"

    var context: String?
    var vocabulary: [String: Int]
    var languageHints: [String]
    var channelRoles: [Int: AudioSource]

    init(
        context: String? = nil,
        vocabulary: [String: Int] = [:],
        languageHints: [String] = ["zh", "en"],
        channelRoles: [Int: AudioSource] = [0: .mic, 1: .system]
    ) {
        self.context = context
        self.vocabulary = vocabulary
        self.languageHints = languageHints
        self.channelRoles = channelRoles
    }
}

struct AliyunTaskSubmission: Hashable, Sendable {
    let taskID: String
    let status: String
}

enum AliyunTaskState: String, Codable, Hashable, Sendable {
    case pending = "PENDING"
    case running = "RUNNING"
    case succeeded = "SUCCEEDED"
    case failed = "FAILED"
    case canceled = "CANCELED"
    case unknown = "UNKNOWN"

    init(serverValue: String) {
        self = AliyunTaskState(rawValue: serverValue.uppercased()) ?? .unknown
    }

    var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .canceled:
            return true
        case .pending, .running, .unknown:
            return false
        }
    }
}

struct AliyunTaskResultReference: Hashable, Sendable {
    let status: AliyunTaskState
    let transcriptionURL: URL?
    let errorCode: String?
    let errorMessage: String?
}

struct AliyunTaskSnapshot: Hashable, Sendable {
    let taskID: String
    let state: AliyunTaskState
    let result: AliyunTaskResultReference?
}

struct AliyunFileTranscriptionResult: Hashable, Sendable {
    let chunks: [TranscriptChunk]
    let speakerNameMappings: [String: String]
    let originalDurationMilliseconds: Int?
}

struct AliyunUploadPolicy: Hashable, Sendable {
    let uploadHost: URL
    let uploadDirectory: String
    let accessKeyID: String
    let signature: String
    let policy: String
    let objectACL: String
    let forbidOverwrite: String
    let maximumFileSizeMB: Int?
}

struct AliyunUploadedFile: Hashable, Sendable {
    let ossURL: String
}

struct AliyunDashScopeConfiguration: Hashable, Sendable {
    var model: String
    var uploadPolicyURL: URL
    var transcriptionURL: URL
    var taskBaseURL: URL
    var allowedUploadHostSuffixes: [String]
    var allowedResultHostSuffixes: [String]

    static let mainlandChina = AliyunDashScopeConfiguration(
        model: AliyunFileTranscriptionOptions.defaultModel,
        uploadPolicyURL: URL(string: "https://dashscope.aliyuncs.com/api/v1/uploads")!,
        transcriptionURL: URL(string: "https://dashscope.aliyuncs.com/api/v1/services/audio/asr/transcription")!,
        taskBaseURL: URL(string: "https://dashscope.aliyuncs.com/api/v1/tasks")!,
        allowedUploadHostSuffixes: ["aliyuncs.com"],
        allowedResultHostSuffixes: ["aliyuncs.com"]
    )

    /// Uses Aliyun's recommended workspace-specific Beijing service host while
    /// keeping temporary-file policy acquisition on the legacy DashScope host.
    static func mainlandChina(workspaceID: String) throws -> AliyunDashScopeConfiguration {
        let trimmed = workspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        guard !trimmed.isEmpty,
              trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              let baseURL = URL(string: "https://\(trimmed).cn-beijing.maas.aliyuncs.com") else {
            throw AliyunFileTranscriptionError.invalidEndpoint
        }
        return try serviceBase(baseURL)
    }

    /// Advanced migration hook for future DashScope service domains. Only HTTPS
    /// endpoints are accepted; callers should expose this as an advanced setting.
    static func serviceBase(_ baseURL: URL) throws -> AliyunDashScopeConfiguration {
        guard baseURL.scheme?.lowercased() == "https",
              let host = baseURL.host?.lowercased(),
              host == "aliyuncs.com" || host.hasSuffix(".aliyuncs.com") else {
            throw AliyunFileTranscriptionError.invalidEndpoint
        }
        let normalizedBase = baseURL.absoluteString.hasSuffix("/")
            ? URL(string: String(baseURL.absoluteString.dropLast())) ?? baseURL
            : baseURL
        guard let transcriptionURL = URL(
            string: normalizedBase.absoluteString + "/api/v1/services/audio/asr/transcription"
        ), let taskBaseURL = URL(string: normalizedBase.absoluteString + "/api/v1/tasks") else {
            throw AliyunFileTranscriptionError.invalidEndpoint
        }
        var result = AliyunDashScopeConfiguration.mainlandChina
        result.transcriptionURL = transcriptionURL
        result.taskBaseURL = taskBaseURL
        return result
    }
}

enum AliyunFileTranscriptionError: LocalizedError, Equatable {
    case missingAPIKey
    case sourceFileMissing
    case sourceIsNotAFile
    case untrustedSourceFile
    case fileTooLarge(maximumMB: Int)
    case invalidEndpoint
    case untrustedUploadHost
    case untrustedResultHost
    case invalidVocabularyWeight(term: String)
    case invalidHTTPResponse
    case requestFailed(statusCode: Int, code: String?)
    case malformedResponse
    case uploadFailed(statusCode: Int)
    case taskFailed(code: String?)
    case taskCanceled
    case taskTimedOut
    case noTranscript

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "未配置阿里云百炼 API Key。"
        case .sourceFileMissing:
            return "待转写的本地录音不存在。"
        case .sourceIsNotAFile:
            return "待转写路径不是普通文件。"
        case .untrustedSourceFile:
            return "待转写文件不属于本次会议的本地录音目录，已停止上传。"
        case .fileTooLarge(let maximumMB):
            return "录音超过临时上传允许的大小（最大约 \(maximumMB) MB）。"
        case .invalidEndpoint:
            return "阿里云转写服务地址无效。"
        case .untrustedUploadHost:
            return "服务返回了不受信任的上传地址，已停止上传。"
        case .untrustedResultHost:
            return "服务返回了不受信任的结果地址，已停止下载。"
        case .invalidVocabularyWeight:
            return "热词权重无效，应为 1～5 或 50。"
        case .invalidHTTPResponse:
            return "服务返回了无法识别的网络响应。"
        case .requestFailed(let statusCode, let code):
            let suffix = code.map { "（\($0)）" } ?? ""
            return "阿里云请求失败，HTTP \(statusCode)\(suffix)。"
        case .malformedResponse:
            return "阿里云返回的数据格式不完整。"
        case .uploadFailed(let statusCode):
            return "录音上传失败，HTTP \(statusCode)。"
        case .taskFailed(let code):
            let suffix = code.map { "（\($0)）" } ?? ""
            return "云端转写任务失败\(suffix)。"
        case .taskCanceled:
            return "云端转写任务已取消。"
        case .taskTimedOut:
            return "等待云端转写结果超时，可稍后重试。"
        case .noTranscript:
            return "云端转写完成，但没有返回可用文字。"
        }
    }
}

// MARK: - Injectable HTTP transport

protocol AliyunHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
    func upload(for request: URLRequest, fromFile fileURL: URL) async throws -> (Data, HTTPURLResponse)
}

final class URLSessionAliyunHTTPTransport: AliyunHTTPTransport, @unchecked Sendable {
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(
                configuration: configuration,
                delegate: AliyunRejectRedirectsDelegate(),
                delegateQueue: nil
            )
        }
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AliyunFileTranscriptionError.invalidHTTPResponse
        }
        return (data, httpResponse)
    }

    func upload(for request: URLRequest, fromFile fileURL: URL) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.upload(for: request, fromFile: fileURL)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AliyunFileTranscriptionError.invalidHTTPResponse
        }
        return (data, httpResponse)
    }
}

/// Signed OSS URLs and upload requests must never be replayed to a redirect target.
/// Refusing redirects prevents a compromised endpoint/proxy from moving audio or
/// credentials outside the domains validated by the client.
private final class AliyunRejectRedirectsDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

// MARK: - Client

final class AliyunFileTranscriptionClient: @unchecked Sendable {
    private static let hardMaximumTemporaryUploadBytes: Int64 = 1_000_000_000
    private static let hardMaximumJSONResponseBytes = 64 * 1_024 * 1_024
    private let transport: any AliyunHTTPTransport
    private let configuration: AliyunDashScopeConfiguration
    private let fileManager: FileManager
    private let multipartDirectory: URL

    init(
        transport: any AliyunHTTPTransport = URLSessionAliyunHTTPTransport(),
        configuration: AliyunDashScopeConfiguration = .mainlandChina,
        fileManager: FileManager = .default,
        multipartDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        self.transport = transport
        self.configuration = configuration
        self.fileManager = fileManager
        self.multipartDirectory = multipartDirectory
        Self.removeStaleMultipartFiles(in: multipartDirectory, fileManager: fileManager)
    }

    func requestUploadPolicy(apiKey: String) async throws -> AliyunUploadPolicy {
        let key = try normalizedAPIKey(apiKey)
        guard var components = URLComponents(url: configuration.uploadPolicyURL, resolvingAgainstBaseURL: false) else {
            throw AliyunFileTranscriptionError.invalidEndpoint
        }
        components.queryItems = [
            URLQueryItem(name: "action", value: "getPolicy"),
            URLQueryItem(name: "model", value: configuration.model)
        ]
        guard let url = components.url else {
            throw AliyunFileTranscriptionError.invalidEndpoint
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await transport.data(for: request)
        guard isSameHTTPSHost(response.url ?? url, as: url) else {
            throw AliyunFileTranscriptionError.invalidEndpoint
        }
        try validate(response: response, data: data)
        let wire = try decode(WireUploadPolicyResponse.self, from: data)
        let policy = wire.data

        guard let uploadHost = URL(string: policy.uploadHost),
              isTrustedHTTPSHost(uploadHost, suffixes: configuration.allowedUploadHostSuffixes) else {
            throw AliyunFileTranscriptionError.untrustedUploadHost
        }

        return AliyunUploadPolicy(
            uploadHost: uploadHost,
            uploadDirectory: policy.uploadDirectory,
            accessKeyID: policy.accessKeyID,
            signature: policy.signature,
            policy: policy.policy,
            objectACL: policy.objectACL,
            forbidOverwrite: policy.forbidOverwrite,
            maximumFileSizeMB: policy.maximumFileSizeMB.map { min(1_000, max(0, $0.value)) }
        )
    }

    func upload(fileURL: URL, using policy: AliyunUploadPolicy) async throws -> AliyunUploadedFile {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw AliyunFileTranscriptionError.sourceFileMissing
        }
        let values = try fileManager.attributesOfItem(atPath: fileURL.path)
        guard let fileType = values[.type] as? FileAttributeType, fileType == .typeRegular else {
            throw AliyunFileTranscriptionError.sourceIsNotAFile
        }

        let byteCount = (values[.size] as? NSNumber)?.int64Value ?? 0
        if byteCount > Self.hardMaximumTemporaryUploadBytes {
            throw AliyunFileTranscriptionError.fileTooLarge(maximumMB: 1_000)
        }
        if let maximumMB = policy.maximumFileSizeMB {
            let boundedMaximumMB = min(1_000, max(0, maximumMB))
            let maximumBytes = Int64(boundedMaximumMB) * 1_000_000
            if byteCount > maximumBytes {
                throw AliyunFileTranscriptionError.fileTooLarge(maximumMB: boundedMaximumMB)
            }
        }

        let safeName = Self.sanitizedFileName(fileURL.lastPathComponent)
        let objectKey = "\(policy.uploadDirectory)/\(UUID().uuidString)-\(safeName)"
        let boundary = "MeetMemo-\(UUID().uuidString)"
        let multipartURL = multipartDirectory
            .appendingPathComponent("meetmemo-upload-\(UUID().uuidString).multipart")

        do {
            try AliyunMultipartFormWriter.write(
                to: multipartURL,
                boundary: boundary,
                fields: [
                    ("OSSAccessKeyId", policy.accessKeyID),
                    ("Signature", policy.signature),
                    ("policy", policy.policy),
                    ("x-oss-object-acl", policy.objectACL),
                    ("x-oss-forbid-overwrite", policy.forbidOverwrite),
                    ("key", objectKey),
                    ("success_action_status", "200")
                ],
                fileFieldName: "file",
                fileURL: fileURL,
                contentType: Self.mimeType(for: fileURL.pathExtension),
                fileManager: fileManager
            )
        } catch CocoaError.fileReadNoSuchFile {
            throw AliyunFileTranscriptionError.sourceFileMissing
        }
        defer { try? fileManager.removeItem(at: multipartURL) }

        var request = URLRequest(url: policy.uploadHost)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(String(try Self.fileSize(at: multipartURL, fileManager: fileManager)), forHTTPHeaderField: "Content-Length")

        let (_, response) = try await transport.upload(for: request, fromFile: multipartURL)
        guard isTrustedHTTPSHost(response.url ?? policy.uploadHost, suffixes: configuration.allowedUploadHostSuffixes) else {
            throw AliyunFileTranscriptionError.untrustedUploadHost
        }
        guard (200..<300).contains(response.statusCode) else {
            throw AliyunFileTranscriptionError.uploadFailed(statusCode: response.statusCode)
        }
        return AliyunUploadedFile(ossURL: "oss://\(objectKey)")
    }

    func submit(
        uploadedFile: AliyunUploadedFile,
        apiKey: String,
        options: AliyunFileTranscriptionOptions = AliyunFileTranscriptionOptions()
    ) async throws -> AliyunTaskSubmission {
        let key = try normalizedAPIKey(apiKey)
        let normalizedOptions = try Self.normalized(options)
        let channels = normalizedOptions.channelRoles.keys.sorted()
        guard !channels.isEmpty else {
            throw AliyunFileTranscriptionError.malformedResponse
        }

        let context: [WireContextMessage]?
        if let contextText = normalizedOptions.context, !contextText.isEmpty {
            context = [
                WireContextMessage(
                    role: "user",
                    content: [WireContextContent(type: "input_text", text: contextText)]
                )
            ]
        } else {
            context = nil
        }

        let body = WireSubmitRequest(
            model: configuration.model,
            input: WireSubmitInput(fileURLs: [uploadedFile.ossURL], context: context),
            parameters: WireSubmitParameters(
                vocabulary: normalizedOptions.vocabulary.isEmpty ? nil : normalizedOptions.vocabulary,
                channelID: channels,
                diarizationEnabled: false,
                languageHints: normalizedOptions.languageHints
            )
        )

        var request = URLRequest(url: configuration.transcriptionURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("enable", forHTTPHeaderField: "X-DashScope-Async")
        request.setValue("enable", forHTTPHeaderField: "X-DashScope-OssResourceResolve")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await transport.data(for: request)
        guard isSameHTTPSHost(response.url ?? configuration.transcriptionURL, as: configuration.transcriptionURL) else {
            throw AliyunFileTranscriptionError.invalidEndpoint
        }
        try validate(response: response, data: data)
        let wire = try decode(WireSubmitResponse.self, from: data)
        guard !wire.output.taskID.isEmpty else {
            throw AliyunFileTranscriptionError.malformedResponse
        }
        return AliyunTaskSubmission(taskID: wire.output.taskID, status: wire.output.taskStatus)
    }

    func query(taskID: String, apiKey: String) async throws -> AliyunTaskSnapshot {
        let key = try normalizedAPIKey(apiKey)
        let cleanTaskID = taskID.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowedTaskIDCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard !cleanTaskID.isEmpty,
              cleanTaskID.unicodeScalars.allSatisfy({ allowedTaskIDCharacters.contains($0) }) else {
            throw AliyunFileTranscriptionError.malformedResponse
        }
        let url = configuration.taskBaseURL.appendingPathComponent(cleanTaskID)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await transport.data(for: request)
        guard isSameHTTPSHost(response.url ?? url, as: url) else {
            throw AliyunFileTranscriptionError.invalidEndpoint
        }
        try validate(response: response, data: data)
        let wire = try decode(WireTaskResponse.self, from: data)
        let state = AliyunTaskState(serverValue: wire.output.taskStatus)
        let firstResult = wire.output.results?.first
        let result = firstResult.map {
            AliyunTaskResultReference(
                status: AliyunTaskState(serverValue: $0.subtaskStatus),
                transcriptionURL: $0.transcriptionURL.flatMap(URL.init(string:)),
                errorCode: $0.code,
                errorMessage: $0.message
            )
        }
        return AliyunTaskSnapshot(taskID: wire.output.taskID, state: state, result: result)
    }

    /// DashScope can cancel only tasks that are still PENDING. Callers should treat a
    /// rejection as best-effort: a RUNNING task may already have incurred processing cost.
    func cancel(taskID: String, apiKey: String) async throws {
        let key = try normalizedAPIKey(apiKey)
        let cleanTaskID = taskID.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowedTaskIDCharacters = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "-_")
        )
        guard !cleanTaskID.isEmpty,
              cleanTaskID.unicodeScalars.allSatisfy({ allowedTaskIDCharacters.contains($0) }) else {
            throw AliyunFileTranscriptionError.malformedResponse
        }
        let url = configuration.taskBaseURL
            .appendingPathComponent(cleanTaskID)
            .appendingPathComponent("cancel")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await transport.data(for: request)
        guard isSameHTTPSHost(response.url ?? url, as: url) else {
            throw AliyunFileTranscriptionError.invalidEndpoint
        }
        try validate(response: response, data: data)
    }

    func downloadResult(
        from url: URL,
        options: AliyunFileTranscriptionOptions = AliyunFileTranscriptionOptions(),
        meetingStart: Date,
        timelineBaseOffsetMilliseconds: Int = 0
    ) async throws -> AliyunFileTranscriptionResult {
        guard isTrustedHTTPSHost(url, suffixes: configuration.allowedResultHostSuffixes) else {
            throw AliyunFileTranscriptionError.untrustedResultHost
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let (data, response) = try await transport.data(for: request)
        guard isTrustedHTTPSHost(response.url ?? url, suffixes: configuration.allowedResultHostSuffixes) else {
            throw AliyunFileTranscriptionError.untrustedResultHost
        }
        try validate(response: response, data: data)
        let wire = try decode(WireTranscriptionResult.self, from: data)
        return try AliyunTranscriptMerger.merge(
            wire,
            options: options,
            meetingStart: meetingStart,
            timelineBaseOffsetMilliseconds: timelineBaseOffsetMilliseconds
        )
    }

    private func normalizedAPIKey(_ apiKey: String) throws -> String {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw AliyunFileTranscriptionError.missingAPIKey }
        return key
    }

    private func validate(response: HTTPURLResponse, data: Data) throws {
        guard data.count <= Self.hardMaximumJSONResponseBytes else {
            throw AliyunFileTranscriptionError.malformedResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            let error = try? JSONDecoder().decode(WireErrorResponse.self, from: data)
            throw AliyunFileTranscriptionError.requestFailed(
                statusCode: response.statusCode,
                code: error?.code ?? error?.output?.code
            )
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw AliyunFileTranscriptionError.malformedResponse
        }
    }

    private func isTrustedHTTPSHost(_ url: URL, suffixes: [String]) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else {
            return false
        }
        return suffixes.contains { suffix in
            let cleanSuffix = suffix.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return host == cleanSuffix || host.hasSuffix(".\(cleanSuffix)")
        }
    }

    /// Service API responses must remain on the exact HTTPS host that was requested.
    /// This supports both the legacy DashScope endpoint and workspace endpoints while
    /// preventing a redirect (or injected transport) from widening trust to a sibling host.
    private func isSameHTTPSHost(_ candidate: URL, as requestedURL: URL) -> Bool {
        guard candidate.scheme?.lowercased() == "https",
              requestedURL.scheme?.lowercased() == "https",
              let candidateHost = candidate.host?.lowercased(),
              let requestedHost = requestedURL.host?.lowercased() else {
            return false
        }
        return candidateHost == requestedHost
            && (candidate.port ?? 443) == (requestedURL.port ?? 443)
    }

    private static func normalized(_ options: AliyunFileTranscriptionOptions) throws -> AliyunFileTranscriptionOptions {
        var result = options
        let trimmedContext = options.context?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        result.context = trimmedContext.isEmpty ? nil : String(trimmedContext.prefix(400))
        result.languageHints = Array(options.languageHints
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
            .prefix(4))

        var vocabulary: [String: Int] = [:]
        var superHotwordCount = 0
        for term in options.vocabulary.keys.sorted() {
            let cleanTerm = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanTerm.isEmpty, vocabulary.count < 2_000 else { continue }
            guard let weight = options.vocabulary[term], (1...5).contains(weight) || weight == 50 else {
                throw AliyunFileTranscriptionError.invalidVocabularyWeight(term: cleanTerm)
            }
            if weight == 50 {
                guard superHotwordCount < 50 else { continue }
                superHotwordCount += 1
            }
            vocabulary[cleanTerm] = weight
        }
        result.vocabulary = vocabulary
        return result
    }

    private static func sanitizedFileName(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let scalars = raw.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "_" }
        let result = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return result.isEmpty ? "meeting.wav" : String(result.prefix(120))
    }

    private static func mimeType(for pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "wav": return "audio/wav"
        case "m4a": return "audio/mp4"
        case "mp3": return "audio/mpeg"
        case "aac": return "audio/aac"
        case "flac": return "audio/flac"
        case "ogg", "opus": return "audio/ogg"
        case "mp4", "mov": return "video/mp4"
        default: return "application/octet-stream"
        }
    }

    private static func fileSize(at url: URL, fileManager: FileManager) throws -> Int64 {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    private static func removeStaleMultipartFiles(in directory: URL, fileManager: FileManager) {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        for url in urls where url.lastPathComponent.hasPrefix("meetmemo-upload-")
            && url.pathExtension == "multipart" {
            let modifiedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if modifiedAt < cutoff {
                try? fileManager.removeItem(at: url)
            }
        }
    }
}

// MARK: - Multipart streaming-to-disk builder

enum AliyunMultipartFormWriter {
    static func write(
        to destinationURL: URL,
        boundary: String,
        fields: [(String, String)],
        fileFieldName: String,
        fileURL: URL,
        contentType: String,
        fileManager: FileManager = .default
    ) throws {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw AliyunFileTranscriptionError.sourceFileMissing
        }
        guard fileManager.createFile(atPath: destinationURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        // The multipart body contains the full interview audio and temporary OSS fields.
        // Keep it owner-readable/writable only while URLSession streams it.
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: destinationURL.path
        )
        let output = try FileHandle(forWritingTo: destinationURL)
        defer { try? output.close() }

        func append(_ string: String) throws {
            guard let data = string.data(using: .utf8) else {
                throw AliyunFileTranscriptionError.malformedResponse
            }
            try output.write(contentsOf: data)
        }

        for (name, value) in fields {
            try append("--\(boundary)\r\n")
            try append("Content-Disposition: form-data; name=\"\(escapedHeaderValue(name))\"\r\n\r\n")
            try append(value)
            try append("\r\n")
        }

        try append("--\(boundary)\r\n")
        try append(
            "Content-Disposition: form-data; name=\"\(escapedHeaderValue(fileFieldName))\"; " +
            "filename=\"\(escapedHeaderValue(fileURL.lastPathComponent))\"\r\n"
        )
        try append("Content-Type: \(contentType)\r\n\r\n")

        let input = try FileHandle(forReadingFrom: fileURL)
        defer { try? input.close() }
        while let data = try input.read(upToCount: 1_048_576), !data.isEmpty {
            try output.write(contentsOf: data)
        }
        try append("\r\n--\(boundary)--\r\n")
    }

    private static func escapedHeaderValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: "\"", with: "_")
            .replacingOccurrences(of: "\r", with: "_")
            .replacingOccurrences(of: "\n", with: "_")
    }
}

// MARK: - Wire models and deterministic transcript merge

private struct FlexibleInt: Decodable {
    let value: Int

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let int = try? container.decode(Int.self) {
            value = int
        } else if let string = try? container.decode(String.self), let int = Int(string) {
            value = int
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected integer or integer string")
        }
    }
}

private struct WireUploadPolicyResponse: Decodable {
    let data: WireUploadPolicy
}

private struct WireUploadPolicy: Decodable {
    let policy: String
    let signature: String
    let uploadDirectory: String
    let uploadHost: String
    let maximumFileSizeMB: FlexibleInt?
    let accessKeyID: String
    let objectACL: String
    let forbidOverwrite: String

    enum CodingKeys: String, CodingKey {
        case policy, signature
        case uploadDirectory = "upload_dir"
        case uploadHost = "upload_host"
        case maximumFileSizeMB = "max_file_size_mb"
        case accessKeyID = "oss_access_key_id"
        case objectACL = "x_oss_object_acl"
        case forbidOverwrite = "x_oss_forbid_overwrite"
    }
}

private struct WireSubmitRequest: Encodable {
    let model: String
    let input: WireSubmitInput
    let parameters: WireSubmitParameters
}

private struct WireSubmitInput: Encodable {
    let fileURLs: [String]
    let context: [WireContextMessage]?

    enum CodingKeys: String, CodingKey {
        case fileURLs = "file_urls"
        case context
    }
}

private struct WireContextMessage: Encodable {
    let role: String
    let content: [WireContextContent]
}

private struct WireContextContent: Encodable {
    let type: String
    let text: String
}

private struct WireSubmitParameters: Encodable {
    let vocabulary: [String: Int]?
    let channelID: [Int]
    let diarizationEnabled: Bool
    let languageHints: [String]

    enum CodingKeys: String, CodingKey {
        case vocabulary
        case channelID = "channel_id"
        case diarizationEnabled = "diarization_enabled"
        case languageHints = "language_hints"
    }
}

private struct WireSubmitResponse: Decodable {
    let output: WireSubmitOutput
}

private struct WireSubmitOutput: Decodable {
    let taskID: String
    let taskStatus: String

    enum CodingKeys: String, CodingKey {
        case taskID = "task_id"
        case taskStatus = "task_status"
    }
}

private struct WireTaskResponse: Decodable {
    let output: WireTaskOutput
}

private struct WireTaskOutput: Decodable {
    let taskID: String
    let taskStatus: String
    let results: [WireTaskResult]?

    enum CodingKeys: String, CodingKey {
        case taskID = "task_id"
        case taskStatus = "task_status"
        case results
    }
}

private struct WireTaskResult: Decodable {
    let transcriptionURL: String?
    let subtaskStatus: String
    let code: String?
    let message: String?

    enum CodingKeys: String, CodingKey {
        case transcriptionURL = "transcription_url"
        case subtaskStatus = "subtask_status"
        case code, message
    }
}

private struct WireErrorResponse: Decodable {
    let code: String?
    let output: WireNestedError?
}

private struct WireNestedError: Decodable {
    let code: String?
}

struct WireTranscriptionResult: Decodable {
    let properties: WireTranscriptionProperties?
    let transcripts: [WireTranscript]
}

struct WireTranscriptionProperties: Decodable {
    let originalDurationMilliseconds: Int?

    enum CodingKeys: String, CodingKey {
        case originalDurationMilliseconds = "original_duration_in_milliseconds"
    }
}

struct WireTranscript: Decodable {
    let channelID: Int
    let text: String
    let contentDurationMilliseconds: Int?
    let sentences: [WireSentence]

    enum CodingKeys: String, CodingKey {
        case channelID = "channel_id"
        case text
        case contentDurationMilliseconds = "content_duration_in_milliseconds"
        case sentences
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        channelID = try container.decode(Int.self, forKey: .channelID)
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        contentDurationMilliseconds = try container.decodeIfPresent(Int.self, forKey: .contentDurationMilliseconds)
        sentences = try container.decodeIfPresent([WireSentence].self, forKey: .sentences) ?? []
    }
}

struct WireSentence: Decodable {
    let beginTime: Int
    let endTime: Int
    let text: String

    enum CodingKeys: String, CodingKey {
        case beginTime = "begin_time"
        case endTime = "end_time"
        case text
    }
}

enum AliyunTranscriptMerger {
    private static let maximumSupportedDurationMilliseconds = 12 * 60 * 60 * 1_000

    static func merge(
        _ result: WireTranscriptionResult,
        options: AliyunFileTranscriptionOptions,
        meetingStart: Date,
        timelineBaseOffsetMilliseconds: Int = 0
    ) throws -> AliyunFileTranscriptionResult {
        var chunks: [TranscriptChunk] = []
        var mappings: [String: String] = [:]
        let baseOffset = max(0, timelineBaseOffsetMilliseconds)
        let reportedDuration = result.properties?.originalDurationMilliseconds
            .map { min(max(0, $0), maximumSupportedDurationMilliseconds) }
        guard baseOffset <= Int.max - (reportedDuration ?? maximumSupportedDurationMilliseconds) else {
            throw AliyunFileTranscriptionError.malformedResponse
        }

        for transcript in result.transcripts {
            guard let source = options.channelRoles[transcript.channelID] else { continue }
            let role = roleMetadata(for: source)
            mappings["\(source.rawValue):\(role.tag)"] = role.displayName

            if transcript.sentences.isEmpty {
                let text = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                chunks.append(TranscriptChunk(
                    timestamp: meetingStart.addingTimeInterval(Double(baseOffset) / 1_000),
                    source: source,
                    text: text,
                    isFinal: true,
                    speakerTag: role.tag,
                    startTime: baseOffset,
                    endTime: reportedDuration.map { baseOffset + $0 },
                    isLowConfidence: true
                ))
                continue
            }

            for sentence in transcript.sentences {
                let text = sentence.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let maximumDuration = reportedDuration ?? maximumSupportedDurationMilliseconds
                let begin = min(max(0, sentence.beginTime), maximumDuration)
                let end = min(max(begin, sentence.endTime), maximumDuration)
                let absoluteBegin = baseOffset + begin
                let absoluteEnd = baseOffset + end
                chunks.append(TranscriptChunk(
                    timestamp: meetingStart.addingTimeInterval(Double(absoluteBegin) / 1_000),
                    source: source,
                    text: text,
                    isFinal: true,
                    speakerTag: role.tag,
                    startTime: absoluteBegin,
                    endTime: absoluteEnd
                ))
            }
        }

        chunks.sortByTranscriptTimeline()
        guard !chunks.isEmpty else { throw AliyunFileTranscriptionError.noTranscript }
        return AliyunFileTranscriptionResult(
            chunks: chunks,
            speakerNameMappings: mappings,
            originalDurationMilliseconds: result.properties?.originalDurationMilliseconds
        )
    }

    private static func roleMetadata(for source: AudioSource) -> (tag: String, displayName: String) {
        switch source {
        case .mic:
            return ("candidate", "候选人")
        case .system:
            return ("interviewer", "面试官")
        }
    }
}
