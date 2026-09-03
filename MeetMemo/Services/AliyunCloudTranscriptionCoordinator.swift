import Foundation

enum CloudTranscriptionMode: String, CaseIterable, Codable, Hashable, Sendable {
    case localOnly = "local"
    case aliyunAccurate = "aliyun-accurate"
}

enum AliyunCloudTranscriptionPhase: String, Codable, Hashable, Sendable {
    case waiting
    case requestingUploadPolicy
    case uploading
    case submitting
    case polling
    case downloadingResult
    case succeeded
    case failed
}

struct AliyunCloudTranscriptionJob: Codable, Hashable, Sendable {
    static let maximumPersistedContextCharacters = 400

    let meetingID: UUID
    let recordingSessionID: UUID
    let artifactID: UUID
    var audioFilePath: String
    var meetingStart: Date
    var timelineBaseOffsetMilliseconds: Int
    var recordingDurationMilliseconds: Int?
    var context: String?
    var vocabulary: [String: Int]
    var phase: AliyunCloudTranscriptionPhase
    var taskID: String?
    var temporaryOSSURL: String?
    var attemptCount: Int
    var lastError: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        meetingID: UUID,
        recordingSessionID: UUID,
        artifactID: UUID,
        audioFileURL: URL,
        meetingStart: Date,
        timelineBaseOffsetMilliseconds: Int = 0,
        recordingDurationMilliseconds: Int? = nil,
        context: String? = nil,
        vocabulary: [String: Int] = [:],
        now: Date = Date()
    ) {
        self.meetingID = meetingID
        self.recordingSessionID = recordingSessionID
        self.artifactID = artifactID
        self.audioFilePath = audioFileURL.path
        self.meetingStart = meetingStart
        self.timelineBaseOffsetMilliseconds = max(0, timelineBaseOffsetMilliseconds)
        self.recordingDurationMilliseconds = recordingDurationMilliseconds.map { max(0, $0) }
        self.context = Self.normalizedPersistedContext(context)
        self.vocabulary = vocabulary
        self.phase = .waiting
        self.taskID = nil
        self.temporaryOSSURL = nil
        self.attemptCount = 0
        self.lastError = nil
        self.createdAt = now
        self.updatedAt = now
    }

    var audioFileURL: URL {
        URL(fileURLWithPath: audioFilePath)
    }

    static func normalizedPersistedContext(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maximumPersistedContextCharacters))
    }

    static func isTrustedRecordingPath(
        _ fileURL: URL,
        meetingID: UUID,
        recordingSessionID: UUID,
        rootDirectory: URL = MeetingRecordingStore.defaultRootDirectory
    ) -> Bool {
        let expected = rootDirectory
            .appendingPathComponent(meetingID.uuidString, isDirectory: true)
            .appendingPathComponent(recordingSessionID.uuidString, isDirectory: true)
            .appendingPathComponent(SynchronizedDualTrackRecorder.wavFileName)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let candidate = fileURL.standardizedFileURL.resolvingSymlinksInPath()
        return candidate.path == expected.path
    }

    var hasTrustedRecordingPath: Bool {
        Self.isTrustedRecordingPath(
            audioFileURL,
            meetingID: meetingID,
            recordingSessionID: recordingSessionID
        )
    }
}

struct AliyunCloudTranscriptionRequest: Hashable, Sendable {
    let meetingID: UUID
    let recordingSessionID: UUID
    let artifactID: UUID
    let audioFileURL: URL
    let meetingStart: Date
    let timelineBaseOffsetMilliseconds: Int
    let recordingDurationMilliseconds: Int?
    let context: String?
    let vocabulary: [String: Int]

    init(
        meetingID: UUID,
        recordingSessionID: UUID,
        artifactID: UUID,
        audioFileURL: URL,
        meetingStart: Date,
        timelineBaseOffsetMilliseconds: Int,
        recordingDurationMilliseconds: Int? = nil,
        context: String? = nil,
        vocabulary: [String: Int] = [:]
    ) {
        self.meetingID = meetingID
        self.recordingSessionID = recordingSessionID
        self.artifactID = artifactID
        self.audioFileURL = audioFileURL
        self.meetingStart = meetingStart
        self.timelineBaseOffsetMilliseconds = max(0, timelineBaseOffsetMilliseconds)
        self.recordingDurationMilliseconds = recordingDurationMilliseconds.map { max(0, $0) }
        self.context = AliyunCloudTranscriptionJob.normalizedPersistedContext(context)
        self.vocabulary = vocabulary
    }
}

struct AliyunCloudTranscriptionDelivery: Hashable, Sendable {
    let meetingID: UUID
    let recordingSessionID: UUID
    let artifactID: UUID
    let engine: AccurateTranscriptionEngine
    let modelName: String
    let replacementStartMilliseconds: Int
    let replacementEndMilliseconds: Int?
    /// These chunks are already shifted onto the absolute meeting timeline.
    /// Callers must not add `replacementStartMilliseconds` a second time.
    let result: AliyunFileTranscriptionResult

    init(
        meetingID: UUID,
        recordingSessionID: UUID,
        artifactID: UUID,
        engine: AccurateTranscriptionEngine = .aliyunCloud,
        modelName: String = "qwen-audio-3.0-asr-flash-filetrans",
        replacementStartMilliseconds: Int,
        replacementEndMilliseconds: Int?,
        result: AliyunFileTranscriptionResult
    ) {
        self.meetingID = meetingID
        self.recordingSessionID = recordingSessionID
        self.artifactID = artifactID
        self.engine = engine
        self.modelName = modelName
        self.replacementStartMilliseconds = max(0, replacementStartMilliseconds)
        self.replacementEndMilliseconds = replacementEndMilliseconds
        self.result = result
    }
}

protocol AliyunCloudTranscriptionJobPersisting: Sendable {
    func save(_ job: AliyunCloudTranscriptionJob) async throws
    func load(artifactID: UUID) async throws -> AliyunCloudTranscriptionJob?
    func loadLatest(meetingID: UUID, recordingSessionID: UUID?) async throws -> AliyunCloudTranscriptionJob?
    func delete(artifactID: UUID) async throws
    func delete(meetingID: UUID) async throws
}

actor AliyunCloudTranscriptionJobStore: AliyunCloudTranscriptionJobPersisting {
    private let directoryURL: URL
    private let fileManager: FileManager

    init(
        directoryURL: URL = AliyunCloudTranscriptionJobStore.defaultDirectoryURL(),
        fileManager: FileManager = .default
    ) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
    }

    func save(_ job: AliyunCloudTranscriptionJob) throws {
        try ensureDirectory()
        var sanitizedJob = job
        sanitizedJob.context = AliyunCloudTranscriptionJob.normalizedPersistedContext(job.context)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(sanitizedJob)
        try data.write(to: fileURL(for: job.artifactID), options: .atomic)
    }

    func load(artifactID: UUID) throws -> AliyunCloudTranscriptionJob? {
        let url = fileURL(for: artifactID)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AliyunCloudTranscriptionJob.self, from: data)
    }

    func loadLatest(meetingID: UUID, recordingSessionID: UUID? = nil) throws -> AliyunCloudTranscriptionJob? {
        try loadAll().filter { job in
            job.meetingID == meetingID
                && (recordingSessionID == nil || job.recordingSessionID == recordingSessionID)
        }
        .max { $0.updatedAt < $1.updatedAt }
    }

    func loadAll() throws -> [AliyunCloudTranscriptionJob] {
        guard fileManager.fileExists(atPath: directoryURL.path) else { return [] }
        let urls = try fileManager.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return urls.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(AliyunCloudTranscriptionJob.self, from: data)
        }
    }

    func delete(artifactID: UUID) throws {
        let url = fileURL(for: artifactID)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    func delete(meetingID: UUID) throws {
        guard fileManager.fileExists(atPath: directoryURL.path) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let urls = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }

        for url in urls {
            guard let data = try? Data(contentsOf: url),
                  let job = try? decoder.decode(AliyunCloudTranscriptionJob.self, from: data),
                  job.meetingID == meetingID else {
                continue
            }
            try fileManager.removeItem(at: url)
        }
    }

    private func ensureDirectory() throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    private func fileURL(for artifactID: UUID) -> URL {
        directoryURL.appendingPathComponent("\(artifactID.uuidString).json")
    }

    private static func defaultDirectoryURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("MeetMemo", isDirectory: true)
            .appendingPathComponent("CloudTranscriptionJobs", isDirectory: true)
    }
}

protocol AliyunAPIKeyProviding: Sendable {
    func apiKey() throws -> String
}

struct KeychainAliyunAPIKeyProvider: AliyunAPIKeyProviding, @unchecked Sendable {
    func apiKey() throws -> String {
        let key = KeychainHelper.shared.getAliyunDashScopeAPIKey()?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !key.isEmpty else { throw AliyunFileTranscriptionError.missingAPIKey }
        return key
    }
}

actor AliyunCloudTranscriptionCoordinator {
    typealias Sleep = @Sendable (UInt64) async throws -> Void
    typealias Now = @Sendable () -> Date
    typealias Progress = @Sendable (AliyunCloudTranscriptionJob) -> Void

    private let client: AliyunFileTranscriptionClient
    private let store: any AliyunCloudTranscriptionJobPersisting
    private let credentialProvider: any AliyunAPIKeyProviding
    private let pollingIntervalNanoseconds: UInt64
    private let timeout: TimeInterval
    private let sleep: Sleep
    private let now: Now

    init(
        client: AliyunFileTranscriptionClient = AliyunFileTranscriptionClient(),
        store: any AliyunCloudTranscriptionJobPersisting = AliyunCloudTranscriptionJobStore(),
        credentialProvider: any AliyunAPIKeyProviding = KeychainAliyunAPIKeyProvider(),
        pollingIntervalNanoseconds: UInt64 = 2_000_000_000,
        timeout: TimeInterval = 60 * 60,
        sleep: @escaping Sleep = { try await Task.sleep(nanoseconds: $0) },
        now: @escaping Now = { Date() }
    ) {
        self.client = client
        self.store = store
        self.credentialProvider = credentialProvider
        self.pollingIntervalNanoseconds = pollingIntervalNanoseconds
        self.timeout = timeout
        self.sleep = sleep
        self.now = now
    }

    func start(
        request: AliyunCloudTranscriptionRequest,
        progress: Progress? = nil
    ) async throws -> AliyunCloudTranscriptionDelivery {
        guard AliyunCloudTranscriptionJob.isTrustedRecordingPath(
            request.audioFileURL,
            meetingID: request.meetingID,
            recordingSessionID: request.recordingSessionID
        ) else {
            throw AliyunFileTranscriptionError.untrustedSourceFile
        }
        var job = AliyunCloudTranscriptionJob(
            meetingID: request.meetingID,
            recordingSessionID: request.recordingSessionID,
            artifactID: request.artifactID,
            audioFileURL: request.audioFileURL,
            meetingStart: request.meetingStart,
            timelineBaseOffsetMilliseconds: request.timelineBaseOffsetMilliseconds,
            recordingDurationMilliseconds: request.recordingDurationMilliseconds,
            context: request.context,
            vocabulary: request.vocabulary,
            now: now()
        )
        job.attemptCount = 1
        return try await executeNewJob(&job, progress: progress)
    }

    func resumeOrRetry(artifactID: UUID, progress: Progress? = nil) async throws -> AliyunCloudTranscriptionDelivery {
        guard var job = try await store.load(artifactID: artifactID) else {
            throw AliyunFileTranscriptionError.sourceFileMissing
        }
        // Jobs written by earlier builds used the meeting creation date as their
        // wall-clock origin. Reconcile every retry from the trusted recording
        // manifest so a meeting created yesterday and recorded today cannot keep
        // producing yesterday's absolute transcript timestamps.
        if let artifact = MeetingRecordingStore.shared.artifact(
            for: job.meetingID,
            sessionID: job.recordingSessionID
        ) {
            job.audioFilePath = artifact.stereoFileURL.path
            job.meetingStart = artifact.transcriptTimelineOrigin
            job.timelineBaseOffsetMilliseconds = artifact.timelineBaseOffsetMilliseconds
            job.recordingDurationMilliseconds = max(
                0,
                artifact.timelineEndOffsetMilliseconds - artifact.timelineBaseOffsetMilliseconds
            )
            try await store.save(job)
        }
        guard job.hasTrustedRecordingPath else {
            throw AliyunFileTranscriptionError.untrustedSourceFile
        }

        if job.phase != .failed, let taskID = job.taskID, !taskID.isEmpty {
            return try await pollAndDownload(job: &job, taskID: taskID, progress: progress)
        }

        job.taskID = nil
        job.temporaryOSSURL = nil
        job.lastError = nil
        job.phase = .waiting
        job.attemptCount += 1
        return try await executeNewJob(&job, progress: progress)
    }

    func latestPersistedJob(
        meetingID: UUID,
        recordingSessionID: UUID? = nil
    ) async throws -> AliyunCloudTranscriptionJob? {
        try await store.loadLatest(meetingID: meetingID, recordingSessionID: recordingSessionID)
    }

    func persistedJob(artifactID: UUID) async throws -> AliyunCloudTranscriptionJob? {
        try await store.load(artifactID: artifactID)
    }

    private func executeNewJob(
        _ job: inout AliyunCloudTranscriptionJob,
        progress: Progress?
    ) async throws -> AliyunCloudTranscriptionDelivery {
        do {
            guard job.hasTrustedRecordingPath else {
                throw AliyunFileTranscriptionError.untrustedSourceFile
            }
            let apiKey = try credentialProvider.apiKey()
            try await transition(&job, to: .requestingUploadPolicy, progress: progress)
            let policy = try await client.requestUploadPolicy(apiKey: apiKey)

            try await transition(&job, to: .uploading, progress: progress)
            let uploadedFile = try await client.upload(fileURL: job.audioFileURL, using: policy)
            job.temporaryOSSURL = uploadedFile.ossURL
            try await persist(&job, progress: progress)

            try await transition(&job, to: .submitting, progress: progress)
            let options = options(for: job)
            let submission = try await client.submit(
                uploadedFile: uploadedFile,
                apiKey: apiKey,
                options: options
            )
            job.taskID = submission.taskID
            try await transition(&job, to: .polling, progress: progress)
            return try await pollAndDownload(job: &job, taskID: submission.taskID, progress: progress)
        } catch {
            try? await markFailed(&job, error: error, progress: progress)
            throw error
        }
    }

    private func pollAndDownload(
        job: inout AliyunCloudTranscriptionJob,
        taskID: String,
        progress: Progress?
    ) async throws -> AliyunCloudTranscriptionDelivery {
        do {
            let apiKey = try credentialProvider.apiKey()
            try await transition(&job, to: .polling, progress: progress)
            let deadline = now().addingTimeInterval(timeout)

            while now() < deadline {
                try Task.checkCancellation()
                let snapshot = try await client.query(taskID: taskID, apiKey: apiKey)

                switch snapshot.state {
                case .pending, .running, .unknown:
                    try await sleep(pollingIntervalNanoseconds)
                case .failed:
                    throw AliyunFileTranscriptionError.taskFailed(code: snapshot.result?.errorCode)
                case .canceled:
                    throw AliyunFileTranscriptionError.taskCanceled
                case .succeeded:
                    guard let resultReference = snapshot.result else {
                        throw AliyunFileTranscriptionError.malformedResponse
                    }
                    guard resultReference.status == .succeeded else {
                        throw AliyunFileTranscriptionError.taskFailed(code: resultReference.errorCode)
                    }
                    guard let resultURL = resultReference.transcriptionURL else {
                        throw AliyunFileTranscriptionError.malformedResponse
                    }
                    try await transition(&job, to: .downloadingResult, progress: progress)
                    let result = try await client.downloadResult(
                        from: resultURL,
                        options: options(for: job),
                        meetingStart: job.meetingStart,
                        timelineBaseOffsetMilliseconds: job.timelineBaseOffsetMilliseconds
                    )
                    job.lastError = nil
                    try await transition(&job, to: .succeeded, progress: progress)
                    return delivery(job: job, result: result)
                }
            }

            throw AliyunFileTranscriptionError.taskTimedOut
        } catch {
            try? await markFailed(&job, error: error, progress: progress)
            throw error
        }
    }

    private func options(for job: AliyunCloudTranscriptionJob) -> AliyunFileTranscriptionOptions {
        AliyunFileTranscriptionOptions(context: job.context, vocabulary: job.vocabulary)
    }

    private func delivery(
        job: AliyunCloudTranscriptionJob,
        result: AliyunFileTranscriptionResult
    ) -> AliyunCloudTranscriptionDelivery {
        let inferredEnd = job.recordingDurationMilliseconds.map {
            Self.safeTimelineEnd(
                baseMilliseconds: job.timelineBaseOffsetMilliseconds,
                durationMilliseconds: $0
            )
        } ?? result.originalDurationMilliseconds.map {
            Self.safeTimelineEnd(
                baseMilliseconds: job.timelineBaseOffsetMilliseconds,
                durationMilliseconds: $0
            )
        } ?? result.chunks.compactMap(\.endTime).max()
        return AliyunCloudTranscriptionDelivery(
            meetingID: job.meetingID,
            recordingSessionID: job.recordingSessionID,
            artifactID: job.artifactID,
            engine: .aliyunCloud,
            modelName: "qwen-audio-3.0-asr-flash-filetrans",
            replacementStartMilliseconds: job.timelineBaseOffsetMilliseconds,
            replacementEndMilliseconds: inferredEnd,
            result: result
        )
    }

    private static func safeTimelineEnd(
        baseMilliseconds: Int,
        durationMilliseconds: Int
    ) -> Int {
        let base = max(0, baseMilliseconds)
        let duration = max(0, durationMilliseconds)
        let (end, overflow) = base.addingReportingOverflow(duration)
        return overflow ? Int.max : end
    }

    private func transition(
        _ job: inout AliyunCloudTranscriptionJob,
        to phase: AliyunCloudTranscriptionPhase,
        progress: Progress?
    ) async throws {
        job.phase = phase
        job.updatedAt = now()
        try await store.save(job)
        progress?(job)
    }

    private func persist(_ job: inout AliyunCloudTranscriptionJob, progress: Progress?) async throws {
        job.updatedAt = now()
        try await store.save(job)
        progress?(job)
    }

    private func markFailed(
        _ job: inout AliyunCloudTranscriptionJob,
        error: Error,
        progress: Progress?
    ) async throws {
        job.phase = .failed
        job.lastError = Self.safeErrorDescription(error)
        job.updatedAt = now()
        try await store.save(job)
        progress?(job)
    }

    private static func safeErrorDescription(_ error: Error) -> String {
        if let known = error as? AliyunFileTranscriptionError {
            return AliyunCloudTranscriptionErrorSanitizer.description(for: known)
        }
        if error is CancellationError {
            return "任务已取消，可稍后重试。"
        }
        if let urlError = error as? URLError {
            return "网络请求失败（\(urlError.code.rawValue)），可稍后重试。"
        }
        return "云端转写遇到未知错误，可稍后重试。"
    }
}

enum AliyunCloudTranscriptionErrorSanitizer {
    static let maximumRemoteCodeCharacters = 64

    static func sanitizedRemoteCode(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }

        let lowered = trimmed.lowercased()
        guard !lowered.hasPrefix("sk-"),
              !lowered.contains("bearer"),
              !lowered.contains("authorization") else {
            return nil
        }

        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let characters = trimmed.unicodeScalars
            .prefix(maximumRemoteCodeCharacters)
            .map { allowed.contains($0) ? Character(String($0)) : "_" }
        let result = String(characters).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return result.isEmpty ? nil : result
    }

    static func description(for error: AliyunFileTranscriptionError) -> String {
        switch error {
        case .requestFailed(let statusCode, let code):
            let suffix = sanitizedRemoteCode(code).map { "（\($0)）" } ?? ""
            return "阿里云请求失败，HTTP \(statusCode)\(suffix)。"
        case .taskFailed(let code):
            let suffix = sanitizedRemoteCode(code).map { "（\($0)）" } ?? ""
            return "云端转写任务失败\(suffix)。"
        default:
            return error.localizedDescription
        }
    }
}

extension Notification.Name {
    static let cloudTranscriptionModeChanged = Notification.Name("CloudTranscriptionModeChanged")
}
