import Combine
import Foundation

struct AliyunCloudTranscriptionStatus: Hashable, Sendable {
    let artifactID: UUID
    let engine: AccurateTranscriptionEngine
    let phase: AliyunCloudTranscriptionPhase
    let message: String?
}

/// Bridges completed local recording artifacts to the optional cloud-accurate workflow.
/// The local live transcript is never cleared up front: it is replaced only after a complete,
/// validated cloud result has been atomically persisted for this artifact's timeline range.
@MainActor
final class AliyunPostRecordingTranscriptionService: ObservableObject {
    static let shared = AliyunPostRecordingTranscriptionService()

    private enum ActiveTaskKind: Equatable {
        case cloud
        case local
    }

    private struct ActiveTranscriptionTask {
        let meetingID: UUID
        let kind: ActiveTaskKind
        let generation: UUID
        var effectiveEngine: AccurateTranscriptionEngine
        let task: Task<Void, Never>
    }

    @Published private(set) var statusByMeetingID: [UUID: AliyunCloudTranscriptionStatus] = [:]

    private let notificationCenter: NotificationCenter
    private var observers: [NSObjectProtocol] = []
    private var activeTasksByArtifactID: [UUID: ActiveTranscriptionTask] = [:]
    /// Only the newest status run for a meeting may update its single UI banner.
    /// Accurate transcript ranges still persist independently when continuation jobs
    /// finish out of order; this fence affects presentation only.
    private var latestStatusGenerationByMeetingID: [UUID: UUID] = [:]
    private var recoveredArtifactsByMeetingID: [UUID: RecordingArtifact] = [:]
    private var retryLookupMeetingIDs = Set<UUID>()
    /// A mode switch may need to await several cancelled tasks before their
    /// persisted cloud jobs can be reconciled. Keep Retry disabled for those
    /// meetings so it cannot start a new remote task that an older cleanup pass
    /// would then accidentally cancel or delete.
    private var modeTransitionTokenByMeetingID: [UUID: UUID] = [:]
    /// Invalidates an in-flight local-mode cleanup as soon as the user changes
    /// the setting again. This makes the most recent mode selection authoritative.
    private var cloudModeChangeEpoch: UInt64 = 0
    /// Every reconciliation pass gets an epoch. A pass that suspended on disk I/O
    /// may inspect an older meeting snapshot, but it can no longer commit status
    /// after a newer pass has started.
    private var statusReconciliationEpoch: UInt64 = 0

    private init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
        observers.append(notificationCenter.addObserver(
            forName: .meetingRecordingArtifactReady,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let artifact = notification.object as? RecordingArtifact else { return }
            Task { @MainActor [weak self] in
                self?.handleCompletedArtifact(artifact)
            }
        })
        observers.append(notificationCenter.addObserver(
            forName: .meetingRecordingArtifactRecovered,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let artifact = notification.object as? RecordingArtifact else { return }
            Task { @MainActor [weak self] in
                self?.handleRecoveredArtifact(artifact)
            }
        })
        for name in [Notification.Name.meetingWillDelete, .meetingDeleted] {
            observers.append(notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let meeting = notification.object as? Meeting else { return }
                Task { @MainActor [weak self] in
                    self?.handleMeetingDeletion(meeting.id)
                }
            })
        }
        observers.append(notificationCenter.addObserver(
            forName: .cloudTranscriptionModeChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let mode = notification.object as? CloudTranscriptionMode else { return }
            Task { @MainActor [weak self] in
                self?.handleCloudTranscriptionModeChanged(mode)
            }
        })
        Task { @MainActor [weak self] in
            await self?.restorePersistedJobStatuses()
        }
    }

    deinit {
        observers.forEach { notificationCenter.removeObserver($0) }
    }

    func retryLatest(for meetingID: UUID) {
        guard !activeTasksByArtifactID.values.contains(where: { $0.meetingID == meetingID }),
              !retryLookupMeetingIDs.contains(meetingID),
              modeTransitionTokenByMeetingID[meetingID] == nil else { return }
        let requestedArtifactID = statusByMeetingID[meetingID]?.artifactID
        guard let meeting = LocalStorageManager.shared.loadMeeting(id: meetingID) else { return }

        if let requestedArtifactID,
           meeting.accurateTranscriptReceipts.contains(where: { $0.artifactID == requestedArtifactID }) {
            // Startup cleanup and a user click can race. Prefer the already durable
            // receipt and remove the stale warning rather than reprocessing it.
            statusByMeetingID[meetingID] = nil
            latestStatusGenerationByMeetingID[meetingID] = UUID()
            return
        }

        if UserDefaultsManager.shared.cloudTranscriptionMode == .localOnly {
            guard let artifact = artifactForRetry(
                meeting: meeting,
                requestedArtifactID: requestedArtifactID
            ) else {
                setStatus(
                    meetingID: meetingID,
                    artifactID: requestedArtifactID ?? UUID(),
                    engine: .localQwen3,
                    phase: .failed,
                    message: "找不到这次任务对应的本地录音，没有改动当前原文。"
                )
                return
            }
            startLocalQwenTranscription(artifact: artifact, meeting: meeting)
            return
        }

        guard retryLookupMeetingIDs.insert(meetingID).inserted else { return }
        let expectedStatusGeneration = latestStatusGenerationByMeetingID[meetingID]

        Task { [weak self] in
            guard let self else { return }
            defer { self.retryLookupMeetingIDs.remove(meetingID) }
            do {
                let coordinator = try self.makeCoordinator()
                guard UserDefaultsManager.shared.cloudTranscriptionMode == .aliyunAccurate,
                      let currentMeeting = LocalStorageManager.shared.loadMeeting(id: meetingID) else { return }

                // A restored banner refers to one exact artifact. Never silently
                // redirect its Retry button to a newer continuation recording, which
                // could cause an unexpected second upload and replace the wrong range.
                if let requestedArtifactID {
                    if currentMeeting.accurateTranscriptReceipts.contains(where: {
                        $0.artifactID == requestedArtifactID
                    }) {
                        self.statusByMeetingID[meetingID] = nil
                        self.latestStatusGenerationByMeetingID[meetingID] = UUID()
                        return
                    }
                    if let job = try await coordinator.persistedJob(artifactID: requestedArtifactID),
                       job.meetingID == meetingID {
                        guard UserDefaultsManager.shared.cloudTranscriptionMode == .aliyunAccurate else { return }
                        self.runRetry(job: job, coordinator: coordinator)
                        return
                    }
                    if let artifact = self.artifactForRetry(
                        meeting: currentMeeting,
                        requestedArtifactID: requestedArtifactID
                    ) {
                        guard UserDefaultsManager.shared.cloudTranscriptionMode == .aliyunAccurate else { return }
                        self.startCloudTranscription(artifact: artifact, meeting: currentMeeting)
                        return
                    }
                    self.setStatus(
                        meetingID: meetingID,
                        artifactID: requestedArtifactID,
                        engine: .aliyunCloud,
                        phase: .failed,
                        message: "找不到这次任务对应的本地录音或云端任务，没有改动当前原文。"
                    )
                    return
                }

                if let artifact = self.artifactForRetry(
                    meeting: currentMeeting,
                    requestedArtifactID: nil
                ) {
                    if let job = try await coordinator.persistedJob(artifactID: artifact.sessionID),
                       job.meetingID == meetingID {
                        guard UserDefaultsManager.shared.cloudTranscriptionMode == .aliyunAccurate,
                              LocalStorageManager.shared.loadMeeting(id: meetingID) != nil else { return }
                        self.runRetry(job: job, coordinator: coordinator)
                        return
                    }
                    guard UserDefaultsManager.shared.cloudTranscriptionMode == .aliyunAccurate,
                          LocalStorageManager.shared.loadMeeting(id: meetingID) != nil else { return }
                    self.startCloudTranscription(artifact: artifact, meeting: currentMeeting)
                    return
                }

                if let job = try await coordinator.latestPersistedJob(meetingID: meetingID) {
                    guard !currentMeeting.accurateTranscriptReceipts.contains(where: {
                        $0.artifactID == job.artifactID
                    }) else {
                        try? await AliyunCloudTranscriptionJobStore().delete(artifactID: job.artifactID)
                        self.statusByMeetingID[meetingID] = nil
                        return
                    }
                    guard UserDefaultsManager.shared.cloudTranscriptionMode == .aliyunAccurate,
                          LocalStorageManager.shared.loadMeeting(id: meetingID) != nil else { return }
                    self.runRetry(job: job, coordinator: coordinator)
                } else {
                    self.setStatus(
                        meetingID: meetingID,
                        artifactID: UUID(),
                        engine: .aliyunCloud,
                        phase: .failed,
                        message: "没有可重试的本地录音或云端转写任务。"
                    )
                }
            } catch {
                guard UserDefaultsManager.shared.cloudTranscriptionMode == .aliyunAccurate,
                      self.latestStatusGenerationByMeetingID[meetingID] == expectedStatusGeneration,
                      !self.activeTasksByArtifactID.values.contains(where: {
                          $0.meetingID == meetingID
                      }),
                      self.modeTransitionTokenByMeetingID[meetingID] == nil,
                      let currentMeeting = LocalStorageManager.shared.loadMeeting(id: meetingID) else {
                    return
                }
                let failureArtifactID = requestedArtifactID
                    ?? self.statusByMeetingID[meetingID]?.artifactID
                    ?? UUID()
                guard !currentMeeting.accurateTranscriptReceipts.contains(where: {
                    $0.artifactID == failureArtifactID
                }) else { return }
                self.setStatus(
                    meetingID: meetingID,
                    artifactID: failureArtifactID,
                    engine: .aliyunCloud,
                    phase: .failed,
                    message: Self.safeUserMessage(error)
                )
            }
        }
    }

    func cancel(artifactID: UUID) {
        // The owning task removes itself in its defer block. Keeping the entry until
        // then prevents a retry from starting while cancellation is still unwinding.
        activeTasksByArtifactID[artifactID]?.task.cancel()
    }

    private func handleCompletedArtifact(_ artifact: RecordingArtifact) {
        guard let meeting = LocalStorageManager.shared.loadMeeting(id: artifact.meetingID) else { return }
        recoveredArtifactsByMeetingID[artifact.meetingID] = nil

        if UserDefaultsManager.shared.cloudTranscriptionMode == .localOnly {
            startLocalQwenTranscription(artifact: artifact, meeting: meeting)
            return
        }

        startCloudTranscription(artifact: artifact, meeting: meeting)
    }

    private func handleRecoveredArtifact(_ artifact: RecordingArtifact) {
        guard LocalStorageManager.shared.loadMeeting(id: artifact.meetingID) != nil else { return }
        if let existing = recoveredArtifactsByMeetingID[artifact.meetingID],
           existing.timelineEndOffsetMilliseconds > artifact.timelineEndOffsetMilliseconds {
            return
        }
        recoveredArtifactsByMeetingID[artifact.meetingID] = artifact
        setStatus(
            meetingID: artifact.meetingID,
            artifactID: artifact.sessionID,
            engine: UserDefaultsManager.shared.cloudTranscriptionMode == .localOnly
                ? .localQwen3
                : .aliyunCloud,
            phase: .failed,
            message: "中断录音已恢复并保存在本地，不会自动上传；点击“重试”后才会继续转写。"
        )
    }

    private func startCloudTranscription(artifact: RecordingArtifact, meeting: Meeting) {
        recoveredArtifactsByMeetingID[artifact.meetingID] = nil

        cancel(artifactID: artifact.sessionID)
        let generation = UUID()
        beginStatusRun(
            meetingID: artifact.meetingID,
            artifactID: artifact.sessionID,
            engine: .aliyunCloud,
            phase: .waiting,
            message: "录音已安全保存在本机，正在准备阿里云会后精准转写…",
            generation: generation
        )
        do {
            let coordinator = try makeCoordinator()
            let request = AliyunCloudTranscriptionRequest(
                meetingID: artifact.meetingID,
                recordingSessionID: artifact.sessionID,
                artifactID: artifact.sessionID,
                audioFileURL: artifact.stereoFileURL,
                // Aliyun adds the meeting-timeline offset to this origin. Derive
                // timeline zero from the session's real wall-clock start so a meeting
                // created yesterday but recorded today does not receive yesterday's dates.
                meetingStart: artifact.transcriptTimelineOrigin,
                timelineBaseOffsetMilliseconds: artifact.timelineBaseOffsetMilliseconds,
                recordingDurationMilliseconds: Self.durationMilliseconds(for: artifact),
                context: Self.transcriptionContext(for: meeting),
                vocabulary: Self.interviewVocabulary(for: meeting)
            )
            let task = Task { [weak self] in
                guard let self else { return }
                defer {
                    self.finishActiveTask(
                        artifactID: artifact.sessionID,
                        generation: generation
                    )
                }
                do {
                    let delivery = try await coordinator.start(
                        request: request,
                        progress: self.progressHandler(
                            meetingID: artifact.meetingID,
                            artifactID: artifact.sessionID,
                            generation: generation
                        )
                    )
                    try Task.checkCancellation()
                    await self.apply(delivery, generation: generation)
                } catch {
                    guard !Task.isCancelled else { return }
                    await self.runLocalQwenFallback(
                        artifact: artifact,
                        meeting: meeting,
                        cloudError: error,
                        generation: generation
                    )
                }
            }
            activeTasksByArtifactID[artifact.sessionID] = ActiveTranscriptionTask(
                meetingID: artifact.meetingID,
                kind: .cloud,
                generation: generation,
                effectiveEngine: .aliyunCloud,
                task: task
            )
        } catch {
            setStatus(
                meetingID: artifact.meetingID,
                artifactID: artifact.sessionID,
                engine: .aliyunCloud,
                phase: .failed,
                message: Self.safeUserMessage(error),
                generation: generation
            )
        }
    }

    private func startLocalQwenTranscription(artifact: RecordingArtifact, meeting: Meeting) {
        recoveredArtifactsByMeetingID[artifact.meetingID] = nil
        cancel(artifactID: artifact.sessionID)
        let generation = UUID()
        beginStatusRun(
            meetingID: artifact.meetingID,
            artifactID: artifact.sessionID,
            engine: .localQwen3,
            phase: .polling,
            message: "正在使用本地 Qwen3-ASR 进行会后精准转写…",
            generation: generation
        )
        let task = Task { [weak self] in
            guard let self else { return }
                defer {
                    self.finishActiveTask(
                    artifactID: artifact.sessionID,
                    generation: generation
                )
            }
            await self.runLocalQwenFallback(
                artifact: artifact,
                meeting: meeting,
                cloudError: nil,
                generation: generation
            )
        }
        activeTasksByArtifactID[artifact.sessionID] = ActiveTranscriptionTask(
            meetingID: artifact.meetingID,
            kind: .local,
            generation: generation,
            effectiveEngine: .localQwen3,
            task: task
        )
    }

    private func runRetry(
        job: AliyunCloudTranscriptionJob,
        coordinator: AliyunCloudTranscriptionCoordinator
    ) {
        cancel(artifactID: job.artifactID)
        let generation = UUID()
        beginStatusRun(
            meetingID: job.meetingID,
            artifactID: job.artifactID,
            engine: .aliyunCloud,
            phase: .waiting,
            message: "正在恢复阿里云会后精准转写任务…",
            generation: generation
        )
        let task = Task { [weak self] in
            guard let self else { return }
                defer {
                    self.finishActiveTask(
                    artifactID: job.artifactID,
                    generation: generation
                )
            }
            do {
                let delivery = try await coordinator.resumeOrRetry(
                    artifactID: job.artifactID,
                    progress: self.progressHandler(
                        meetingID: job.meetingID,
                        artifactID: job.artifactID,
                        generation: generation
                    )
                )
                try Task.checkCancellation()
                await self.apply(delivery, generation: generation)
            } catch {
                guard !Task.isCancelled else { return }
                if let meeting = LocalStorageManager.shared.loadMeeting(id: job.meetingID),
                   let artifact = MeetingRecordingStore.shared.artifact(
                       for: job.meetingID,
                       sessionID: job.recordingSessionID
                   ) {
                    await self.runLocalQwenFallback(
                        artifact: artifact,
                        meeting: meeting,
                        cloudError: error,
                        generation: generation
                    )
                } else {
                    self.setStatus(
                        meetingID: job.meetingID,
                        artifactID: job.artifactID,
                        engine: .aliyunCloud,
                        phase: .failed,
                        message: Self.safeUserMessage(error),
                        generation: generation
                    )
                }
            }
        }
        activeTasksByArtifactID[job.artifactID] = ActiveTranscriptionTask(
            meetingID: job.meetingID,
            kind: .cloud,
            generation: generation,
            effectiveEngine: .aliyunCloud,
            task: task
        )
    }

    private func apply(
        _ delivery: AliyunCloudTranscriptionDelivery,
        generation: UUID
    ) async {
        do {
            try await waitUntilMeetingIdleForAccurateApply(
                meetingID: delivery.meetingID,
                artifactID: delivery.artifactID,
                engine: delivery.engine,
                generation: generation
            )
        } catch {
            return
        }
        guard let savedMeeting = LocalStorageManager.shared.applyAliyunCloudTranscription(delivery) else {
            setStatus(
                meetingID: delivery.meetingID,
                artifactID: delivery.artifactID,
                engine: delivery.engine,
                phase: .failed,
                message: "精准结果未能安全写入，本地实时转写已保留。",
                generation: generation
            )
            return
        }

        setStatus(
            meetingID: delivery.meetingID,
            artifactID: delivery.artifactID,
            engine: delivery.engine,
            phase: .succeeded,
            message: "阿里云精准转写已完成；未被云端覆盖的少量片段会继续保留本地实时文字。",
            generation: generation
        )
        NotificationCenter.default.post(
            name: .meetingAccurateTranscriptSaved,
            object: MeetingAccurateTranscriptUpdate(persistedMeeting: savedMeeting)
        )
        NotificationCenter.default.post(name: .meetingSaved, object: savedMeeting)
        // The receipt is already durable at this point. Await deletion so a normal
        // shutdown cannot leave a succeeded job that would be restored as a false
        // failure banner on the next launch. Startup reconciliation remains the
        // second line of defense if deletion itself fails.
        try? await AliyunCloudTranscriptionJobStore().delete(artifactID: delivery.artifactID)
    }

    private func runLocalQwenFallback(
        artifact: RecordingArtifact,
        meeting: Meeting,
        cloudError: Error?,
        generation: UUID
    ) async {
        updateEffectiveEngine(
            artifactID: artifact.sessionID,
            generation: generation,
            engine: .localQwen3
        )
        let hotwords = Self.localQwenHotwords(for: meeting)
        setStatus(
            meetingID: artifact.meetingID,
            artifactID: artifact.sessionID,
            engine: .localQwen3,
            phase: .polling,
            message: cloudError == nil
                ? "正在使用本地 Qwen3-ASR 进行会后精准转写…"
                : "阿里云转写未完成，正在自动切换到本地 Qwen3-ASR 兜底…",
            generation: generation
        )
        do {
            try Task.checkCancellation()
            let localResult = try await AudioFileTranscriber.shared.transcribeTracksWithQwen3([
                AudioTrackTranscriptionRequest(
                    url: artifact.micFileURL,
                    source: .mic,
                    timelineOffsetMilliseconds: artifact.timelineBaseOffsetMilliseconds,
                    hotwords: hotwords
                ),
                AudioTrackTranscriptionRequest(
                    url: artifact.systemFileURL,
                    source: .system,
                    timelineOffsetMilliseconds: artifact.timelineBaseOffsetMilliseconds,
                    hotwords: hotwords
                )
            ])
            try Task.checkCancellation()
            let taggedChunks = localResult.chunks.map { chunk in
                let tag = chunk.source == .mic ? "candidate" : "interviewer"
                let timestamp = artifact.wallClockTimestamp(
                    forMeetingTimelineMilliseconds: chunk.startTime
                )
                return TranscriptChunk(
                    id: chunk.id,
                    timestamp: timestamp,
                    source: chunk.source,
                    text: chunk.text,
                    isFinal: chunk.isFinal,
                    speakerTag: tag,
                    speakerId: nil,
                    startTime: chunk.startTime,
                    endTime: chunk.endTime,
                    isLowConfidence: chunk.isLowConfidence
                )
            }
            let result = AliyunFileTranscriptionResult(
                chunks: taggedChunks,
                speakerNameMappings: [
                    "MIC:candidate": "候选人",
                    "SYS:interviewer": "面试官"
                ],
                originalDurationMilliseconds: Self.durationMilliseconds(for: artifact)
            )
            let delivery = AliyunCloudTranscriptionDelivery(
                meetingID: artifact.meetingID,
                recordingSessionID: artifact.sessionID,
                artifactID: artifact.sessionID,
                engine: .localQwen3,
                modelName: "Qwen3-ASR-0.6B INT8",
                replacementStartMilliseconds: artifact.timelineBaseOffsetMilliseconds,
                replacementEndMilliseconds: artifact.timelineEndOffsetMilliseconds,
                result: result
            )
            try await waitUntilMeetingIdleForAccurateApply(
                meetingID: artifact.meetingID,
                artifactID: artifact.sessionID,
                engine: .localQwen3,
                generation: generation
            )
            guard let savedMeeting = LocalStorageManager.shared.applyAliyunCloudTranscription(delivery) else {
                throw AliyunFileTranscriptionError.noTranscript
            }
            setStatus(
                meetingID: artifact.meetingID,
                artifactID: artifact.sessionID,
                engine: .localQwen3,
                phase: .succeeded,
                message: cloudError == nil
                    ? "本地 Qwen3-ASR 会后精准转写已完成。"
                    : "阿里云转写未完成，已自动使用本地 Qwen3-ASR 完成精准转写。",
                generation: generation
            )
            NotificationCenter.default.post(
                name: .meetingAccurateTranscriptSaved,
                object: MeetingAccurateTranscriptUpdate(persistedMeeting: savedMeeting)
            )
            NotificationCenter.default.post(name: .meetingSaved, object: savedMeeting)
            try? await AliyunCloudTranscriptionJobStore().delete(artifactID: artifact.sessionID)
        } catch {
            guard !Task.isCancelled else { return }
            let localMessage = Self.safeLocalFallbackMessage(error)
            let prefix = cloudError.map { Self.safeUserMessage($0) + " " } ?? ""
            setStatus(
                meetingID: artifact.meetingID,
                artifactID: artifact.sessionID,
                engine: .localQwen3,
                phase: .failed,
                message: "\(prefix)\(localMessage) 本地实时转写已保留。",
                generation: generation
            )
        }
    }

    private func artifactForRetry(
        meeting: Meeting,
        requestedArtifactID: UUID?
    ) -> RecordingArtifact? {
        let processedArtifactIDs = Set(meeting.accurateTranscriptReceipts.map(\.artifactID))
        if let requestedArtifactID {
            guard !processedArtifactIDs.contains(requestedArtifactID) else { return nil }
            if let recovered = recoveredArtifactsByMeetingID[meeting.id],
               recovered.sessionID == requestedArtifactID {
                return recovered
            }
            return MeetingRecordingStore.shared.artifact(
                for: meeting.id,
                sessionID: requestedArtifactID
            )
        }

        if let recovered = recoveredArtifactsByMeetingID[meeting.id],
           !processedArtifactIDs.contains(recovered.sessionID) {
            return recovered
        }
        return MeetingRecordingStore.shared.pendingAccurateTranscriptionArtifacts()
            .filter {
                $0.meetingID == meeting.id && !processedArtifactIDs.contains($0.sessionID)
            }
            .max { lhs, rhs in
                if lhs.timelineEndOffsetMilliseconds != rhs.timelineEndOffsetMilliseconds {
                    return lhs.timelineEndOffsetMilliseconds < rhs.timelineEndOffsetMilliseconds
                }
                return lhs.recordingStartedAt < rhs.recordingStartedAt
            }
    }

    private func finishActiveTask(artifactID: UUID, generation: UUID) {
        guard let completed = activeTasksByArtifactID[artifactID],
              completed.generation == generation else { return }
        activeTasksByArtifactID[artifactID] = nil
        let remainingForMeeting = activeTasksByArtifactID.first(where: {
            $0.value.meetingID == completed.meetingID
        })
        if let (remainingArtifactID, remaining) = remainingForMeeting {
            // If the status-owning task just ended, immediately hand the banner to
            // another active continuation range. This prevents a transient green
            // "complete" state while older/newer audio is still being refined.
            if latestStatusGenerationByMeetingID[completed.meetingID] == generation {
                latestStatusGenerationByMeetingID[completed.meetingID] = remaining.generation
                setStatus(
                    meetingID: completed.meetingID,
                    artifactID: remainingArtifactID,
                    engine: remaining.effectiveEngine,
                    phase: .polling,
                    message: remaining.effectiveEngine == .aliyunCloud
                        ? "另有一段续录仍在阿里云转写中；当前原文会在各段完整结果就绪后分别安全合并。"
                        : "另有一段续录仍在本地 Qwen3-ASR 精转中；完成后会安全合并对应区间。",
                    generation: remaining.generation
                )
            }
            return
        }
        guard modeTransitionTokenByMeetingID[completed.meetingID] == nil else {
            // Mode-transition cleanup owns the final status for this meeting.
            return
        }

        // Defer cannot await. Re-check that no replacement task started before the
        // scheduled reconciliation runs, then converge success/failure/cancellation
        // onto a durable receipt or the next exact retryable artifact.
        Task { @MainActor [weak self] in
            guard let self,
                  !self.activeTasksByArtifactID.values.contains(where: {
                      $0.meetingID == completed.meetingID
                  }),
                  self.modeTransitionTokenByMeetingID[completed.meetingID] == nil else {
                return
            }
            await self.reconcileStatusAfterLastTaskEnded(meetingID: completed.meetingID)
        }
    }

    private func reconcileStatusAfterLastTaskEnded(meetingID: UUID) async {
        guard !activeTasksByArtifactID.values.contains(where: { $0.meetingID == meetingID }),
              modeTransitionTokenByMeetingID[meetingID] == nil,
              LocalStorageManager.shared.loadMeeting(id: meetingID) != nil else { return }

        let previousStatus = statusByMeetingID[meetingID]
        latestStatusGenerationByMeetingID[meetingID] = UUID()
        statusByMeetingID[meetingID] = nil
        let expectedReconciliationEpoch = statusReconciliationEpoch &+ 1
        let expectedCloudModeEpoch = cloudModeChangeEpoch
        await restorePersistedJobStatuses()

        guard statusReconciliationEpoch == expectedReconciliationEpoch,
              cloudModeChangeEpoch == expectedCloudModeEpoch,
              !activeTasksByArtifactID.values.contains(where: { $0.meetingID == meetingID }),
              modeTransitionTokenByMeetingID[meetingID] == nil,
              let previousStatus,
              previousStatus.phase == .failed,
              let currentMeeting = LocalStorageManager.shared.loadMeeting(id: meetingID),
              !currentMeeting.accurateTranscriptReceipts.contains(where: {
                  $0.artifactID == previousStatus.artifactID
              }) else { return }

        // Keep the specific failure text when reconciliation selected the same
        // artifact (or found no durable candidate), but never let an older failure
        // hide a different, later pending continuation range.
        if statusByMeetingID[meetingID] == nil
            || (statusByMeetingID[meetingID]?.artifactID == previousStatus.artifactID
                && statusByMeetingID[meetingID]?.engine == previousStatus.engine) {
            setStatus(
                meetingID: meetingID,
                artifactID: previousStatus.artifactID,
                engine: previousStatus.engine,
                phase: .failed,
                message: previousStatus.message
            )
        }
    }

    private func handleMeetingDeletion(_ meetingID: UUID) {
        recoveredArtifactsByMeetingID[meetingID] = nil
        statusByMeetingID[meetingID] = nil
        latestStatusGenerationByMeetingID[meetingID] = nil
        retryLookupMeetingIDs.remove(meetingID)
        modeTransitionTokenByMeetingID[meetingID] = nil
        let tasks = cancelActiveTasks(meetingID: meetingID, kind: nil)

        // A cancelled coordinator records its final failed state before unwinding. Wait for
        // every task before removing persisted jobs so cancellation cannot recreate a JSON file
        // after deletion. This is idempotent because both will-delete and did-delete are observed.
        Task {
            for task in tasks {
                await task.value
            }
            let store = AliyunCloudTranscriptionJobStore()
            if let jobs = try? await store.loadAll() {
                for job in jobs where job.meetingID == meetingID {
                    await self.attemptRemoteCancellation(for: job)
                }
            }
            try? await store.delete(meetingID: meetingID)

            guard await self.waitForRecordingSessionToEnd(meetingID: meetingID) else {
                // Deleting a directory while its recorder still owns open file handles can
                // corrupt finalization. Preserve it for a later explicit cleanup on timeout.
                print("⚠️ Preserved recording files for deleted meeting because recording finalization timed out: \(meetingID)")
                return
            }
            // Recording finalization is asynchronous. Delete once more after post-processing
            // tasks unwind so a stop/delete race cannot leave a newly finalized directory behind.
            try? MeetingRecordingStore.shared.deleteRecordings(for: meetingID)
        }
    }

    private func waitForRecordingSessionToEnd(
        meetingID: UUID,
        timeout: TimeInterval = 30
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while RecordingSessionManager.shared.hasActiveSession(for: meetingID) {
            guard Date() < deadline else { return false }
            do {
                try await Task.sleep(nanoseconds: 100_000_000)
            } catch {
                return false
            }
        }
        return true
    }

    private func waitUntilMeetingIdleForAccurateApply(
        meetingID: UUID,
        artifactID: UUID,
        engine: AccurateTranscriptionEngine,
        generation: UUID
    ) async throws {
        var didPublishWaitingStatus = false
        while RecordingSessionManager.shared.hasActiveSession(for: meetingID) {
            try Task.checkCancellation()
            guard LocalStorageManager.shared.loadMeeting(id: meetingID) != nil else {
                throw CancellationError()
            }
            if !didPublishWaitingStatus {
                setStatus(
                    meetingID: meetingID,
                    artifactID: artifactID,
                    engine: engine,
                    phase: .polling,
                    message: "精准结果已就绪，等待当前续录结束后再安全合并…",
                    generation: generation
                )
                didPublishWaitingStatus = true
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try Task.checkCancellation()
        guard LocalStorageManager.shared.loadMeeting(id: meetingID) != nil else {
            throw CancellationError()
        }
    }

    private func restorePersistedJobStatuses() async {
        statusReconciliationEpoch &+= 1
        let reconciliationEpoch = statusReconciliationEpoch
        let store = AliyunCloudTranscriptionJobStore()
        let jobs: [AliyunCloudTranscriptionJob]
        do {
            jobs = try await store.loadAll()
        } catch {
            // A damaged cloud-job journal must not suppress recovery of intact
            // local recording manifests. Continue with an empty cloud set and let
            // the local scan below expose an explicit retry path.
            print("⚠️ Could not load persisted cloud jobs; continuing local artifact recovery: \(error.localizedDescription)")
            jobs = []
        }
        guard reconciliationEpoch == statusReconciliationEpoch else { return }

        let meetings = LocalStorageManager.shared.loadMeetings()
        let meetingsByID = Dictionary(
            meetings.map { ($0.id, $0) },
            uniquingKeysWith: { existing, duplicate in
                if duplicate.transcriptRevision != existing.transcriptRevision {
                    return duplicate.transcriptRevision > existing.transcriptRevision
                        ? duplicate
                        : existing
                }
                return duplicate.date > existing.date ? duplicate : existing
            }
        )
        var latestByMeeting: [UUID: AliyunCloudTranscriptionJob] = [:]
        for job in jobs {
            guard let meeting = meetingsByID[job.meetingID] else { continue }

            // A receipt proves that the validated result was already merged and
            // persisted. A leftover job file can only be cleanup residue and must
            // never cover the durable green provenance state with a false warning.
            if meeting.accurateTranscriptReceipts.contains(where: { $0.artifactID == job.artifactID }) {
                try? await store.delete(artifactID: job.artifactID)
                guard reconciliationEpoch == statusReconciliationEpoch else { return }
                continue
            }

            if let existing = latestByMeeting[job.meetingID],
               !Self.cloudJob(job, isLaterThan: existing) {
                continue
            }
            latestByMeeting[job.meetingID] = job
        }

        // Cloud jobs are durable from their first network step, while local Qwen
        // has no remote job. The recording manifest therefore carries a hand-off
        // marker written before the ready notification is posted. If the process
        // dies in that tiny gap (or during local Qwen), surface an explicit retry
        // instead of silently leaving the newest recording with no state.
        let cloudJobArtifactIDs = Set(jobs.map(\.artifactID))
        let pendingArtifacts = await Task.detached(priority: .utility) {
            MeetingRecordingStore.shared.pendingAccurateTranscriptionArtifacts()
        }.value
            .sorted { lhs, rhs in
                if lhs.timelineEndOffsetMilliseconds != rhs.timelineEndOffsetMilliseconds {
                    return lhs.timelineEndOffsetMilliseconds < rhs.timelineEndOffsetMilliseconds
                }
                return lhs.recordingStartedAt < rhs.recordingStartedAt
            }
        guard reconciliationEpoch == statusReconciliationEpoch else { return }

        var latestPendingArtifactByMeeting: [UUID: RecordingArtifact] = [:]
        for artifact in pendingArtifacts {
            guard let meeting = meetingsByID[artifact.meetingID],
                  !meeting.accurateTranscriptReceipts.contains(where: { $0.artifactID == artifact.sessionID }),
                  !cloudJobArtifactIDs.contains(artifact.sessionID) else {
                continue
            }
            if let existing = latestPendingArtifactByMeeting[artifact.meetingID] {
                let artifactEnd = artifact.timelineEndOffsetMilliseconds
                let existingEnd = existing.timelineEndOffsetMilliseconds
                if artifactEnd < existingEnd
                    || (artifactEnd == existingEnd
                        && artifact.recordingStartedAt <= existing.recordingStartedAt) {
                    continue
                }
            }
            latestPendingArtifactByMeeting[artifact.meetingID] = artifact
        }

        let affectedMeetingIDs = Set(latestByMeeting.keys)
            .union(latestPendingArtifactByMeeting.keys)
        for meetingID in affectedMeetingIDs {
            guard reconciliationEpoch == statusReconciliationEpoch else { return }
            guard statusByMeetingID[meetingID] == nil,
                  !activeTasksByArtifactID.values.contains(where: {
                      $0.meetingID == meetingID
                  }),
                  let currentMeeting = LocalStorageManager.shared.loadMeeting(id: meetingID) else {
                continue
            }
            let job = latestByMeeting[meetingID]
            let artifact = latestPendingArtifactByMeeting[meetingID]
            let artifactIsLatest = artifact.map { artifact in
                guard let job else { return true }
                return artifact.timelineEndOffsetMilliseconds > Self.cloudJobTimelineEnd(job)
            } ?? false
            if let artifact, artifactIsLatest {
                guard !currentMeeting.accurateTranscriptReceipts.contains(where: {
                    $0.artifactID == artifact.sessionID
                }) else { continue }
                recoveredArtifactsByMeetingID[meetingID] = artifact
                let usesLocal = UserDefaultsManager.shared.cloudTranscriptionMode == .localOnly
                setStatus(
                    meetingID: meetingID,
                    artifactID: artifact.sessionID,
                    engine: usesLocal ? .localQwen3 : .aliyunCloud,
                    phase: .failed,
                    message: usesLocal
                        ? "上次退出发生在本地 Qwen3-ASR 精转完成之前；双声道录音和临时文字已保留，点击“重试”继续。"
                        : "双声道录音已安全保存，但上次退出发生在云端任务登记前；为避免意外上传，请点击“重试”手动继续。"
                )
                continue
            }

            guard let job else { continue }
            if currentMeeting.accurateTranscriptReceipts.contains(where: {
                $0.artifactID == job.artifactID
            }) {
                try? await store.delete(artifactID: job.artifactID)
                guard reconciliationEpoch == statusReconciliationEpoch else { return }
                continue
            }
            let usesLocal = UserDefaultsManager.shared.cloudTranscriptionMode == .localOnly
            let message: String
            if usesLocal {
                message = "发现上次中断的会后任务；录音仍在本机，点击“重试”将使用本地 Qwen3-ASR，不会上传。"
            } else if job.phase == .succeeded {
                message = "阿里云已生成完整结果，但上次退出发生在写入会议之前；点击“重试”会重新下载、校验并安全合并。"
            } else {
                message = "发现上次未完成的阿里云精准转写；不会在启动时自动上传，点击“重试”后才会继续。"
            }
            setStatus(
                meetingID: meetingID,
                artifactID: job.artifactID,
                engine: usesLocal ? .localQwen3 : .aliyunCloud,
                phase: .failed,
                message: message
            )
        }
    }

    private static func cloudJobTimelineEnd(_ job: AliyunCloudTranscriptionJob) -> Int {
        let base = max(0, job.timelineBaseOffsetMilliseconds)
        guard let duration = job.recordingDurationMilliseconds else { return base }
        let (end, overflow) = base.addingReportingOverflow(max(0, duration))
        return overflow ? Int.max : end
    }

    private static func cloudJob(
        _ candidate: AliyunCloudTranscriptionJob,
        isLaterThan existing: AliyunCloudTranscriptionJob
    ) -> Bool {
        let candidateEnd = cloudJobTimelineEnd(candidate)
        let existingEnd = cloudJobTimelineEnd(existing)
        if candidateEnd != existingEnd { return candidateEnd > existingEnd }
        if candidate.timelineBaseOffsetMilliseconds != existing.timelineBaseOffsetMilliseconds {
            return candidate.timelineBaseOffsetMilliseconds > existing.timelineBaseOffsetMilliseconds
        }
        return candidate.updatedAt > existing.updatedAt
    }

    private func handleCloudTranscriptionModeChanged(_ mode: CloudTranscriptionMode) {
        cloudModeChangeEpoch &+= 1
        guard mode == .localOnly else { return }
        cancelCloudTranscriptionsForLocalMode(epoch: cloudModeChangeEpoch)
    }

    private func cancelCloudTranscriptionsForLocalMode(epoch: UInt64) {
        let activeCloudTasks = activeTasksByArtifactID.compactMap { artifactID, active -> (UUID, ActiveTranscriptionTask)? in
            active.effectiveEngine == .aliyunCloud ? (artifactID, active) : nil
        }
        guard !activeCloudTasks.isEmpty else { return }

        let meetingIDs = Set(activeCloudTasks.map { $0.1.meetingID })
        let transitionToken = UUID()
        for meetingID in meetingIDs {
            modeTransitionTokenByMeetingID[meetingID] = transitionToken
        }
        for (_, active) in activeCloudTasks {
            active.task.cancel()
        }

        Task {
            for (_, active) in activeCloudTasks {
                await active.task.value
            }

            // The user may have switched back to cloud mode (or started a newer
            // local-mode cleanup) while cancellation was unwinding. Only the
            // newest still-local pass is allowed to touch remote/persisted jobs.
            let shouldCancelAndDeleteCloudJobs = self.cloudModeChangeEpoch == epoch
                && UserDefaultsManager.shared.cloudTranscriptionMode == .localOnly
            let store = AliyunCloudTranscriptionJobStore()
            if shouldCancelAndDeleteCloudJobs {
                for (artifactID, _) in activeCloudTasks {
                    guard self.cloudModeChangeEpoch == epoch,
                          UserDefaultsManager.shared.cloudTranscriptionMode == .localOnly else {
                        break
                    }
                    if let job = try? await store.load(artifactID: artifactID) {
                        let alreadyApplied = LocalStorageManager.shared
                            .loadMeeting(id: job.meetingID)?
                            .accurateTranscriptReceipts
                            .contains(where: { $0.artifactID == artifactID }) == true
                        if !alreadyApplied {
                            await self.attemptRemoteCancellation(for: job)
                        }
                    }
                    guard self.cloudModeChangeEpoch == epoch,
                          UserDefaultsManager.shared.cloudTranscriptionMode == .localOnly else {
                        break
                    }
                    try? await store.delete(artifactID: artifactID)
                }
            }

            for meetingID in meetingIDs {
                guard self.modeTransitionTokenByMeetingID[meetingID] == transitionToken else {
                    continue
                }
                self.modeTransitionTokenByMeetingID[meetingID] = nil
                guard !self.activeTasksByArtifactID.values.contains(where: {
                    $0.meetingID == meetingID
                }), let meeting = LocalStorageManager.shared.loadMeeting(id: meetingID) else {
                    continue
                }
                let settledMode = UserDefaultsManager.shared.cloudTranscriptionMode
                let pendingArtifactID = self.artifactForRetry(
                    meeting: meeting,
                    requestedArtifactID: nil
                )?.sessionID
                let unfinishedCapturedArtifactID = activeCloudTasks.first(where: { captured in
                    captured.1.meetingID == meetingID
                        && !meeting.accurateTranscriptReceipts.contains(where: { receipt in
                            receipt.artifactID == captured.0
                        })
                })?.0
                guard let retryArtifactID = pendingArtifactID ?? unfinishedCapturedArtifactID else {
                    // Cancellation can race only with the final journal cleanup after
                    // a transcript receipt has already been saved. In that case the
                    // receipt is authoritative and the UI must remain green.
                    self.latestStatusGenerationByMeetingID[meetingID] = UUID()
                    self.statusByMeetingID[meetingID] = nil
                    continue
                }
                self.setStatus(
                    meetingID: meetingID,
                    artifactID: retryArtifactID,
                    engine: settledMode == .localOnly ? .localQwen3 : .aliyunCloud,
                    phase: .failed,
                    message: settledMode == .localOnly
                        ? "已停止本机等待，并尝试取消云任务；运行中的远端任务可能无法取消。录音保留在本机，可点击“重试”使用本地 Qwen3-ASR。"
                        : "云端转写已因刚才的模式切换停止；录音和任务记录均已保留，可点击“重试”继续阿里云转写。"
                )
            }
        }
    }

    private func attemptRemoteCancellation(for job: AliyunCloudTranscriptionJob) async {
        guard let taskID = job.taskID, !taskID.isEmpty,
              job.phase != .succeeded else { return }
        do {
            let apiKey = try KeychainAliyunAPIKeyProvider().apiKey()
            try await AliyunFileTranscriptionClient(configuration: .mainlandChina).cancel(
                taskID: taskID,
                apiKey: apiKey
            )
        } catch {
            // DashScope only permits canceling PENDING tasks. A RUNNING-task rejection is
            // expected and must not overwrite the user's retained local transcript/status.
        }
    }

    private func updateEffectiveEngine(
        artifactID: UUID,
        generation: UUID,
        engine: AccurateTranscriptionEngine
    ) {
        guard var active = activeTasksByArtifactID[artifactID],
              active.generation == generation else { return }
        active.effectiveEngine = engine
        activeTasksByArtifactID[artifactID] = active
    }

    private func cancelActiveTasks(
        meetingID: UUID,
        kind: ActiveTaskKind?
    ) -> [Task<Void, Never>] {
        let matches = activeTasksByArtifactID.compactMap { artifactID, active -> (UUID, ActiveTranscriptionTask)? in
            guard active.meetingID == meetingID,
                  kind == nil || active.kind == kind else { return nil }
            return (artifactID, active)
        }
        for (artifactID, active) in matches {
            activeTasksByArtifactID[artifactID] = nil
            active.task.cancel()
        }
        return matches.map { $0.1.task }
    }

    private func progressHandler(
        meetingID: UUID,
        artifactID: UUID,
        generation: UUID
    ) -> AliyunCloudTranscriptionCoordinator.Progress {
        { [weak self] job in
            Task { @MainActor [weak self] in
                guard let self,
                      job.artifactID == artifactID,
                      let active = self.activeTasksByArtifactID[artifactID],
                      active.generation == generation,
                      active.effectiveEngine == .aliyunCloud else {
                    return
                }
                // The coordinator marks its remote job succeeded before the result is
                // merged into the meeting file. Publish success only after the atomic
                // local save in `apply` so the UI never claims completion prematurely.
                guard job.phase != .succeeded else { return }
                self.setStatus(
                    meetingID: meetingID,
                    artifactID: job.artifactID,
                    engine: .aliyunCloud,
                    phase: job.phase,
                    message: job.lastError,
                    generation: generation
                )
            }
        }
    }

    private func setStatus(
        meetingID: UUID,
        artifactID: UUID,
        engine: AccurateTranscriptionEngine,
        phase: AliyunCloudTranscriptionPhase,
        message: String?,
        generation: UUID? = nil
    ) {
        if let generation {
            guard latestStatusGenerationByMeetingID[meetingID] == generation else { return }
        } else {
            // Standalone failures/recovery notices supersede any stale callbacks from
            // a previous run for this meeting.
            latestStatusGenerationByMeetingID[meetingID] = UUID()
        }
        statusByMeetingID[meetingID] = AliyunCloudTranscriptionStatus(
            artifactID: artifactID,
            engine: engine,
            phase: phase,
            message: message
        )
    }

    private func beginStatusRun(
        meetingID: UUID,
        artifactID: UUID,
        engine: AccurateTranscriptionEngine,
        phase: AliyunCloudTranscriptionPhase,
        message: String?,
        generation: UUID
    ) {
        latestStatusGenerationByMeetingID[meetingID] = generation
        setStatus(
            meetingID: meetingID,
            artifactID: artifactID,
            engine: engine,
            phase: phase,
            message: message,
            generation: generation
        )
    }

    private func makeCoordinator() throws -> AliyunCloudTranscriptionCoordinator {
        return AliyunCloudTranscriptionCoordinator(
            client: AliyunFileTranscriptionClient(configuration: .mainlandChina)
        )
    }

    private static func transcriptionContext(for meeting: Meeting) -> String? {
        let meetingContext = meeting.formattedMeetingContext
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let userBackground = UserDefaultsManager.shared.userBlurb
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let combined = [meetingContext, userBackground]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return AliyunCloudTranscriptionJob.normalizedPersistedContext(combined)
    }

    private static func durationMilliseconds(for artifact: RecordingArtifact) -> Int {
        let base = max(0, artifact.timelineBaseOffsetMilliseconds)
        return max(0, artifact.timelineEndOffsetMilliseconds - base)
    }

    private static let stableInterviewTerms = [
            "KV Cache", "PagedAttention", "Prefix Caching", "Prefix Hash", "TTFT",
            "Prefill", "Checkpoint", "NVDEC", "PyTorch", "Manifest", "RowVersion",
            "MySQL", "Redis", "Casbin", "Kafka", "Kubernetes", "Raft", "DBaaS",
            "RDS", "ReAct", "RAG", "MCP", "pgvector", "SenseVoice", "Qwen3-ASR"
    ]

    private static func interviewVocabulary(for meeting: Meeting) -> [String: Int] {
        var result = Dictionary(uniqueKeysWithValues: stableInterviewTerms.map { ($0, 5) })

        // Pick identifier-like English technical terms from the per-meeting JD/context.
        // Do not upload arbitrary long strings as hotwords; the full text is already supplied
        // through the length-limited context field.
        let source = meeting.formattedMeetingContext
        let pattern = #"[A-Za-z][A-Za-z0-9_+.#/-]{2,39}"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let range = NSRange(source.startIndex..<source.endIndex, in: source)
            for match in regex.matches(in: source, range: range).prefix(200) {
                guard let swiftRange = Range(match.range, in: source) else { continue }
                result[String(source[swiftRange])] = 4
            }
        }
        return result
    }

    /// Qwen's 512-token context also contains audio placeholders. Keep the local prompt
    /// deliberately small so a long JD/resume cannot crowd out audio tokens. The cloud API
    /// has a separate, much larger vocabulary budget and continues to use the full set.
    private static func localQwenHotwords(for meeting: Meeting) -> String {
        let context = [
            meeting.formattedMeetingContext,
            UserDefaultsManager.shared.userBlurb
        ].joined(separator: "\n")
        let loweredContext = context.lowercased()

        var contextTerms: [String] = []
        let pattern = #"[A-Za-z][A-Za-z0-9_+.#/-]{2,39}"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let range = NSRange(context.startIndex..<context.endIndex, in: context)
            for match in regex.matches(in: context, range: range).prefix(80) {
                guard let swiftRange = Range(match.range, in: context) else { continue }
                contextTerms.append(String(context[swiftRange]))
            }
        }

        let orderedTerms = stableInterviewTerms.filter {
            loweredContext.contains($0.lowercased())
        } + contextTerms + stableInterviewTerms
        return boundedLocalQwenHotwords(from: orderedTerms)
    }

    nonisolated static func boundedLocalQwenHotwords(
        from orderedTerms: [String],
        maximumCharacters: Int = 160,
        maximumTerms: Int = 16
    ) -> String {
        let characterBudget = max(0, maximumCharacters)
        let termBudget = max(0, maximumTerms)
        guard characterBudget > 0, termBudget > 0 else { return "" }

        var seen = Set<String>()
        var accepted: [String] = []
        var usedCharacters = 0
        for rawTerm in orderedTerms {
            let term = rawTerm.trimmingCharacters(in: .whitespacesAndNewlines)
            let identity = term.lowercased()
            guard !term.isEmpty,
                  term.count <= 40,
                  seen.insert(identity).inserted,
                  accepted.count < termBudget else { continue }
            let addedCharacters = term.count + (accepted.isEmpty ? 0 : 1)
            guard usedCharacters + addedCharacters <= characterBudget else { continue }
            accepted.append(term)
            usedCharacters += addedCharacters
        }
        return accepted.joined(separator: ",")
    }

    private static func safeUserMessage(_ error: Error) -> String {
        if let known = error as? AliyunFileTranscriptionError {
            return AliyunCloudTranscriptionErrorSanitizer.description(for: known)
        }
        if error is CancellationError {
            return "云端转写已取消，本地转写已保留。"
        }
        if let urlError = error as? URLError {
            return "网络请求失败（\(urlError.code.rawValue)），本地转写已保留，可稍后重试。"
        }
        return "云端转写失败，本地转写已保留，可稍后重试。"
    }

    private static func safeLocalFallbackMessage(_ error: Error) -> String {
        if let error = error as? Qwen3ASRError {
            return error.localizedDescription
        }
        if error is CancellationError {
            return "本地 Qwen3-ASR 兜底已取消。"
        }
        return "本地 Qwen3-ASR 兜底暂不可用。"
    }
}
