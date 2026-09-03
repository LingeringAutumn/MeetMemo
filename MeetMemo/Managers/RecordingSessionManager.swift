import Foundation
import SwiftUI
import Combine

/// Captures the ownership of one debounced transcript write. The meeting/session identity
/// must travel with the chunks; looking up the current meeting after the debounce delay can
/// otherwise write a stopped meeting's last update into a newly started meeting.
struct RecordingTranscriptSaveRequest {
    let meetingID: UUID
    let sessionToken: UUID
    let chunks: [TranscriptChunk]

    func belongsTo(meetingID: UUID?, sessionToken: UUID?) -> Bool {
        self.meetingID == meetingID && self.sessionToken == sessionToken
    }
}

/// Manages recording sessions at the app level to persist across navigation
@MainActor
class RecordingSessionManager: ObservableObject {
    static let shared = RecordingSessionManager()
    
    @Published var isRecording = false
    @Published var isRecoveringSTT = false
    /// 点击结束录制后、await STT final flush 完成前的中间态。镜像自 AudioManager。
    @Published var isStoppingRecording = false
    @Published var activeMeetingId: UUID?
    @Published var errorMessage: String?
    @Published var warningMessage: String?
    @Published var activeRecordingTranscriptChunksUpdated: [TranscriptChunk] = []
    @Published var activeRecordingStartedAt: Date?
    /// Startup recovery finalizes any interrupted raw tracks before a new session
    /// may choose its timeline base. This prevents recovered and new ranges from
    /// overlapping when the user clicks Record immediately after launch.
    @Published private(set) var isRecoveringRecordings = true
    @Published private(set) var latestRecordingArtifact: RecordingArtifact?
    
    private let audioManager = AudioManager.shared
    private var cancellables = Set<AnyCancellable>()
    private let transcriptUpdateSubject = PassthroughSubject<RecordingTranscriptSaveRequest, Never>()
    private var isStoppingFromSessionManager = false
    private var hasObservedAudioRecordingStart = false
    private var activeSessionToken: UUID?

    // Store transcript chunks for the active recording session
    private var activeRecordingTranscriptChunks: [TranscriptChunk] = []

    private init() {
        setupAudioManagerBindings()
        setupDebouncedSaving()
        _ = AliyunPostRecordingTranscriptionService.shared
        recoverInterruptedRecordings()
    }
    
    private func setupAudioManagerBindings() {
        audioManager.$isStoppingRecording
            .sink { [weak self] value in
                guard let self else { return }
                let didFinishAutomaticStop = self.isStoppingRecording && !value
                self.isStoppingRecording = value

                guard didFinishAutomaticStop,
                      self.activeMeetingId != nil,
                      !self.isStoppingFromSessionManager,
                      self.hasObservedAudioRecordingStart else {
                    return
                }

                print("🧹 Audio manager finished an automatic stop. Saving the final transcript.")
                self.finishActiveSession(saveFinalTranscript: true)
            }
            .store(in: &cancellables)

        audioManager.$isRecoveringSTT
            .sink { [weak self] value in
                self?.isRecoveringSTT = value
            }
            .store(in: &cancellables)

        // Bind to audio manager state
        audioManager.$isRecording
            .sink { [weak self] isRecording in
                guard let self else { return }
                self.isRecording = isRecording

                if isRecording {
                    self.hasObservedAudioRecordingStart = true
                    return
                }

                guard self.activeMeetingId != nil,
                      !self.isStoppingFromSessionManager,
                      !self.audioManager.isStoppingRecording,
                      self.hasObservedAudioRecordingStart else {
                    return
                }

                print("🧹 Audio manager stopped unexpectedly. Cleaning up recording session.")
                self.finishActiveSession(saveFinalTranscript: true)
            }
            .store(in: &cancellables)
        
        audioManager.$errorMessage
            .sink { [weak self] errorMessage in
                guard let self else { return }
                self.errorMessage = errorMessage

                guard errorMessage != nil,
                      self.activeMeetingId != nil,
                      !self.isRecording,
                      !self.isStoppingFromSessionManager else {
                    return
                }

                print("🧹 Audio manager reported a startup error. Cleaning up recording session.")
                self.finishActiveSession(saveFinalTranscript: true)
            }
            .store(in: &cancellables)

        audioManager.$warningMessage
            .sink { [weak self] warningMessage in
                self?.warningMessage = warningMessage
            }
            .store(in: &cancellables)

        audioManager.$latestRecordingArtifact
            .compactMap { $0 }
            .sink { [weak self] artifact in
                self?.latestRecordingArtifact = artifact
            }
            .store(in: &cancellables)
        
        // When transcript chunks change, store them for the active recording and send to debouncer
        audioManager.$transcriptChunks
            .sink { [weak self] newChunks in
                guard let self,
                      self.activeMeetingId != nil,
                      self.isRecording || self.isStoppingRecording || self.isStoppingFromSessionManager else {
                    return
                }
                self.activeRecordingTranscriptChunks = newChunks
                self.activeRecordingTranscriptChunksUpdated = newChunks

                guard let meetingID = self.activeMeetingId,
                      let sessionToken = self.activeSessionToken else { return }
                self.transcriptUpdateSubject.send(RecordingTranscriptSaveRequest(
                    meetingID: meetingID,
                    sessionToken: sessionToken,
                    chunks: newChunks
                ))
            }
            .store(in: &cancellables)
    }

    private func setupDebouncedSaving() {
        transcriptUpdateSubject
            .debounce(for: .seconds(2), scheduler: DispatchQueue.main)
            .sink { [weak self] request in
                guard let self,
                      request.belongsTo(
                        meetingID: self.activeMeetingId,
                        sessionToken: self.activeSessionToken
                      ) else { return }
                print("💾 Debounced save triggered for meeting: \(request.meetingID.uuidString)")
                self.updateActiveMeetingTranscript(meetingId: request.meetingID, chunks: request.chunks)
            }
            .store(in: &cancellables)
    }
    
    func startRecording(for meetingId: UUID, existingChunks: [TranscriptChunk] = []) {
        guard !isRecoveringRecordings else {
            warningMessage = LanguageManager.shared.t(
                "正在检查并恢复上次中断的录音，请稍等片刻后再开始。",
                "Checking and recovering an interrupted recording. Please wait a moment before starting."
            )
            return
        }
        guard activeMeetingId == nil,
              !isRecording,
              !isStoppingRecording else {
            warningMessage = LanguageManager.shared.t(
                "已有录音正在进行或收尾，请先等待其完成。",
                "A recording is already active or finalizing. Wait for it to finish."
            )
            return
        }

        // 会议录音与语音输入互斥：开始录音前先静默停止正在进行的语音输入。
        VoiceInputManager.shared.cancelForRecording()
        print("🎙️ Starting recording for meeting: \(meetingId)")

        // The detail view can initially hold only a lightweight summary. Reload the
        // canonical meeting synchronously before reserving a timeline. When it exists,
        // the disk snapshot is authoritative as a whole: merging arbitrary missing IDs
        // from a stale detail view could resurrect local chunks already replaced by an
        // accurate post-recording transcript.
        let persistedMeeting = LocalStorageManager.shared.loadMeeting(id: meetingId)
        let resumableChunks = Self.resumableTranscriptChunks(
            inMemory: existingChunks,
            persistedMeeting: persistedMeeting
        )
        let persistedTimelineEnd = AudioManager.maximumPersistedMeetingTimelineEnd(
            in: persistedMeeting
        )
        activeRecordingTranscriptChunks = resumableChunks
        audioManager.transcriptChunks = resumableChunks

        activeMeetingId = meetingId
        activeSessionToken = UUID()
        activeRecordingStartedAt = Date()
        hasObservedAudioRecordingStart = false
        audioManager.startRecording(
            meetingID: meetingId,
            persistedMeetingTimelineEndMilliseconds: persistedTimelineEnd
        )
    }
    
    func stopRecording() {
        let stoppedMeetingId = activeMeetingId
        let stoppedSessionToken = activeSessionToken
        print("🛑 Stopping recording for meeting: \(stoppedMeetingId?.uuidString ?? "unknown")")

        isStoppingFromSessionManager = true
        audioManager.stopRecording { [weak self] in
            guard let self else { return }
            guard self.activeMeetingId == stoppedMeetingId,
                  self.activeSessionToken == stoppedSessionToken else {
                self.isStoppingFromSessionManager = false
                return
            }
            self.finishActiveSession(saveFinalTranscript: true)
            self.isStoppingFromSessionManager = false
        }
    }

    private func finishActiveSession(saveFinalTranscript: Bool) {
        if saveFinalTranscript, let activeMeetingId = activeMeetingId {
            updateActiveMeetingTranscript(meetingId: activeMeetingId, chunks: activeRecordingTranscriptChunks)
        }

        activeMeetingId = nil
        activeSessionToken = nil
        activeRecordingStartedAt = nil
        activeRecordingTranscriptChunks = []
        hasObservedAudioRecordingStart = false
    }
    
    func isRecordingMeeting(_ meetingId: UUID) -> Bool {
        return isRecording && activeMeetingId == meetingId
    }

    func activeSTTEngine(for meetingId: UUID) -> STTEngine? {
        guard isRecordingMeeting(meetingId) else { return nil }
        return audioManager.activeRecordingSTTEngine
    }

    func hasActiveSession(for meetingId: UUID) -> Bool {
        activeMeetingId == meetingId
    }
    
    private func updateActiveMeetingTranscript(meetingId: UUID, chunks: [TranscriptChunk]) {
        if var meeting = LocalStorageManager.shared.loadMeeting(id: meetingId) {
            meeting.transcriptChunks = chunks

            let success = LocalStorageManager.shared.saveMeeting(meeting)
            if success {
                print("✅ Saved meeting transcript: \(meetingId.uuidString)")
                NotificationCenter.default.post(name: .meetingSaved, object: meeting)
            } else {
                print("❌ Failed to save meeting transcript: \(meetingId.uuidString)")
            }
        }
    }
    
    func getActiveRecordingTranscriptChunks() -> [TranscriptChunk] {
        return activeRecordingTranscriptChunks
    }

    nonisolated static func resumableTranscriptChunks(
        inMemory: [TranscriptChunk],
        persistedMeeting: Meeting?
    ) -> [TranscriptChunk] {
        (persistedMeeting?.transcriptChunks ?? inMemory)
            .filter(\.isFinal)
            .sortedByTranscriptTimeline()
    }
    
    /// Get transcript chunks for a specific meeting, ensuring proper data separation
    func getTranscriptChunks(for meetingId: UUID) -> [TranscriptChunk] {
        if isRecording && activeMeetingId == meetingId {
            // Return live transcript chunks for the active recording
            return activeRecordingTranscriptChunks
        } else {
            // Load saved transcript chunks from storage for non-active meetings
            if let savedMeeting = LocalStorageManager.shared.loadMeeting(id: meetingId) {
                return savedMeeting.transcriptChunks
            }
            return []
        }
    }

    func latestRecordingArtifact(for meetingID: UUID) -> RecordingArtifact? {
        if latestRecordingArtifact?.meetingID == meetingID {
            return latestRecordingArtifact
        }
        return LocalStorageManager.shared.latestRecordingArtifact(for: meetingID)
    }

    private func recoverInterruptedRecordings() {
        Task.detached(priority: .utility) {
            let artifacts = MeetingRecordingStore.shared.recoverIncompleteRecordings()
            await MainActor.run { [weak self] in
                self?.isRecoveringRecordings = false
                for artifact in artifacts {
                    self?.latestRecordingArtifact = artifact
                    NotificationCenter.default.post(
                        name: .meetingRecordingArtifactRecovered,
                        object: artifact
                    )
                }
            }
        }
    }
}
