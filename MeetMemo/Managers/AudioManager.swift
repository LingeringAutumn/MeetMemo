// AudioManager.swift
// Unified audio manager for microphone and system audio capture

@preconcurrency import AVFoundation
import Combine
import Foundation
import SwiftUI

/// Manages audio capture from microphone and system audio and handles real-time transcription.
@MainActor
class AudioManager: NSObject, ObservableObject {
    static let shared = AudioManager()

    @Published var transcriptChunks: [TranscriptChunk] = []
    @Published var isRecording = false
    @Published var isRecoveringSTT = false
    /// 用户点击结束录制后、await STT final flush 完成前的中间态。
    /// 用于在 UI 上显示"处理中"指示，避免按钮看上去卡了几秒。
    @Published var isStoppingRecording: Bool = false
    @Published var errorMessage: String?
    @Published var warningMessage: String?
    @Published var micAudioLevel: Float = 0.0
    @Published var systemAudioLevel: Float = 0.0
    /// Published only after both capture pipelines and the incremental writer have drained and
    /// the stereo/mono WAV artifacts are complete.
    @Published private(set) var latestRecordingArtifact: RecordingArtifact?

    private var audioEngine = AVAudioEngine()
    private var sttProviderFactory: STTProviderFactory
    private var activeEngine: STTEngine

    /// Engine snapshot selected when the current recording session started.
    /// Settings can change while a meeting is recording, but the already-created
    /// providers continue to use this engine until the next session.
    var activeRecordingSTTEngine: STTEngine { activeEngine }
    private var micSTT: STTProvider?
    private var systemSTT: STTProvider?
    private var micAudioPipeline: AudioProcessingPipeline?
    private var systemAudioPipeline: AudioProcessingPipeline?
    private var startRecordingTask: Task<Void, Never>?
    private var micRestartTask: Task<Void, Never>?
    private var micRestartAttemptID: UUID?
    private let finalFlushTimeout: TimeInterval = 2.0
    private var recordingStartedAtUptime: TimeInterval?
    private var recordingBaseOffsetMilliseconds = 0
    private var recordingStateMachine = AudioRecordingStateMachine()
    private var isFinalizingStoppedRecording = false
    private var pendingStopCompletions: [UUID: [() -> Void]] = [:]
    private var synchronizedRecorder: SynchronizedDualTrackRecorder?
    private var recordingTimeline: MonotonicAudioTimeline?
    private var recordingMeetingID: UUID?
    private var recordingSpeakerMode: STTSpeakerMode = .diarized

    /// Tracks the active interim chunk id per source for replace-on-update semantics.
    private var activeInterimChunkId: [AudioSource: UUID] = [:]
    /// Wall-clock offset (ms) at the moment the first captured audio buffer arrives for each
    /// source. This anchors CMTime=0 to the correct position on the recording timeline, which
    /// is more accurate than capturing the offset at connectSTTProvider time.
    private var firstAudioOffsets: [AudioSource: Int] = [:]
    /// Number of 16 kHz mono frames actually sent or retained for each source since its
    /// current anchor. This lets a capture-device restart fill the exact wall-clock gap with
    /// silence instead of compressing that source's recognizer timeline.
    private var timelineAudioFrameCounts: [AudioSource: Int] = [:]
    /// Absolute 16 kHz sample position of each provider's first retained frame on the shared
    /// capture clock. Together with `timelineAudioFrameCounts`, this detects every later gap or
    /// overlap instead of only microphone device restarts.
    private var timelineAnchorSamplePositions: [AudioSource: Int64] = [:]

    /// True while the system-audio STT runtime is being connected lazily after capture begins.
    /// Prevents duplicate concurrent connects.
    private var systemSTTConnectingSessionID: UUID?
    private var systemSTTConnectTask: Task<Void, Never>?
    /// Recognizer failures are isolated from capture so recoverable raw audio keeps recording.
    private var micSTTUnavailableSessionID: UUID?
    private var systemSTTUnavailableSessionID: UUID?
    /// Serializes mic recognizer cold-start within one recording session. A device-change
    /// restart can otherwise launch a second multi-gigabyte runtime while the first connects.
    private var micSTTConnectingSessionID: UUID?

    /// Mic audio captured while the mic STT provider is still connecting (e.g. Fun-ASR's
    /// ~2 s model load). Ring-buffered up to `VoiceInputTiming.maxPendingAudioBytes` and
    /// flushed into the provider once connected, so cold start doesn't eat the opening speech.
    private var micPendingAudioChunks: [Data] = []
    private var micPendingAudioByteCount = 0
    /// System audio captured while the second local recognizer is loading. Keeping this
    /// bounded pre-connect queue prevents the interviewer's opening sentence from being
    /// discarded and keeps its STT clock aligned with the recording clock.
    private var systemPendingAudioChunks: [Data] = []
    private var systemPendingAudioByteCount = 0

    // Unique identifier for the current recording session
    private var sessionID = UUID()

    // ProcessTap properties
    private var processTap: ProcessTap?
    private let permission = AudioRecordingPermission()
    private let tapQueue = DispatchQueue(label: "io.meetmemo.audiotap", qos: .userInitiated)
    private var isTapActive = false
    private var isTearingDownRecording = false

    private var micRetryCount = 0
    private let maxMicRetries = 3

    /// `NotificationCenter.addObserver(forName:object:queue:using:)` returns an opaque token
    /// that must be passed back to `removeObserver`. We need to drop and re-register this
    /// each time `audioEngine` is replaced, because the observer is filtered by sender.
    private var audioEngineConfigObserver: NSObjectProtocol?
    private var willSleepObserver: NSObjectProtocol?
    private var didWakeObserver: NSObjectProtocol?

    private override init() {
        let initialEngine = UserDefaultsManager.shared.sttEngine
        self.activeEngine = initialEngine
        self.sttProviderFactory = Self.factory(for: initialEngine)
        super.init()
        registerAudioEngineConfigObserver()
        registerSystemPowerObservers()
    }

    deinit {
        let center = NotificationCenter.default
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        if let audioEngineConfigObserver {
            center.removeObserver(audioEngineConfigObserver)
        }
        if let willSleepObserver {
            workspaceCenter.removeObserver(willSleepObserver)
        }
        if let didWakeObserver {
            workspaceCenter.removeObserver(didWakeObserver)
        }
    }

    private var isStoppingOrTearingDown: Bool {
        isStoppingRecording || isTearingDownRecording
    }

    private func publishRecordingActivityState() {
        isRecording = recordingStateMachine.state.isRecordingVisible
        isRecoveringSTT = recordingStateMachine.state.isRecovering
        AudioLevelManager.shared.updateRecordingState(isRecording)
    }

    private func registerAudioEngineConfigObserver() {
        if let audioEngineConfigObserver {
            NotificationCenter.default.removeObserver(audioEngineConfigObserver)
        }
        audioEngineConfigObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.handleAudioEngineConfigurationChange()
            }
        }
    }

    /// macOS posts `willSleepNotification` *before* sleep takes effect. We finalize the
    /// recording proactively so the user gets a clean final transcript instead of having
    /// the engine die mid-stream while the lid closes. We do not auto-resume on wake.
    private func registerSystemPowerObservers() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        willSleepObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRecording, !self.isStoppingOrTearingDown else { return }
                print("💤 System will sleep — finalizing recording before suspend.")
                self.errorMessage = "系统即将进入睡眠，已自动结束录音。"
                self.stopRecording()
            }
        }
        didWakeObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            print("☀️ System woke up. Recording was stopped at sleep; user must start again manually.")
            Task { @MainActor in
                SpeechModelInstaller.shared.handleSystemDidWake()
            }
        }
    }

    func startRecording(
        meetingID: UUID,
        persistedMeetingTimelineEndMilliseconds: Int = 0
    ) {
        print("Starting recording...")

        guard !isStoppingRecording, !isFinalizingStoppedRecording else {
            warningMessage = LanguageManager.shared.t(
                "上一段录音仍在收尾，请稍候再开始。",
                "The previous recording is still finalizing. Please wait before starting again."
            )
            return
        }

        abortRecording()
        refreshSTTFactoryFromSettings()
        sessionID = UUID()
        let startedSessionID = sessionID
        recordingStateMachine.start(sessionID: startedSessionID)
        errorMessage = nil
        warningMessage = nil
        transcriptChunks = transcriptChunks.filter(\.isFinal)
        let transcriptEnd = Self.maximumTranscriptEndTime(in: transcriptChunks)
        let minimumTimelineEnd = max(
            transcriptEnd,
            max(0, persistedMeetingTimelineEndMilliseconds)
        )
        recordingStartedAtUptime = ProcessInfo.processInfo.systemUptime
        let timeline = MonotonicAudioTimeline(sampleRate: 16_000)
        do {
            let reservation = try MeetingRecordingStore.shared.reserveRecorder(
                meetingID: meetingID,
                sessionID: startedSessionID,
                timeline: timeline,
                minimumTimelineEndMilliseconds: minimumTimelineEnd
            )
            synchronizedRecorder = reservation.recorder
            recordingBaseOffsetMilliseconds = reservation.timelineBaseOffsetMilliseconds
        } catch {
            recordingStateMachine.reset()
            recordingStartedAtUptime = nil
            recordingBaseOffsetMilliseconds = 0
            errorMessage = LanguageManager.shared.t(
                "无法创建可恢复的本地录音：\(error.localizedDescription)",
                "Could not create the recoverable local recording: \(error.localizedDescription)"
            )
            return
        }
        recordingTimeline = timeline
        recordingMeetingID = meetingID
        // Live meeting capture has a physical identity contract even in mic-only fallback:
        // mic = candidate, system = interviewer. Diarization remains available only to the
        // imported/mixed-file transcription path.
        recordingSpeakerMode = .fixedByAudioSource
        latestRecordingArtifact = nil
        activeInterimChunkId.removeAll()
        micSTTConnectingSessionID = nil
        systemSTTConnectingSessionID = nil
        micSTTUnavailableSessionID = nil
        systemSTTUnavailableSessionID = nil

        startRecordingTask?.cancel()
        startRecordingTask = Task { [weak self] in
            guard let self else { return }
            guard !Task.isCancelled else { return }

            if UserDefaultsManager.shared.enableSystemAudioSTT {
                // Install both capture taps immediately. The system PCM is buffered until the
                // mic recognizer is ready, so model cold-start cannot eat the interviewer's
                // opening sentence and the two large local runtimes do not load concurrently.
                async let systemTapStart: Void = self.startSystemAudioTap(sessionToken: startedSessionID)
                _ = await self.startMicrophoneTap(sessionToken: startedSessionID)
                await systemTapStart
            } else {
                _ = await self.startMicrophoneTap(sessionToken: startedSessionID)
            }
        }
    }

    /// Immediately tears down the current recording session without waiting for final STT output.
    /// Use only for hard resets and startup failures; normal user stops should call `stopRecording`.
    private func abortRecording() {
        print("Internal cleanup...")

        isTearingDownRecording = true
        defer { isTearingDownRecording = false }
        isFinalizingStoppedRecording = false

        stopStartRecordingTask()
        stopMicRestartTask()
        stopAudioPipelines()
        let stoppedSessionID = sessionID
        let recorderToPreserve = synchronizedRecorder
        synchronizedRecorder = nil
        recordingTimeline = nil
        recordingMeetingID = nil
        if let recorderToPreserve {
            Task.detached(priority: .utility) {
                await recorderToPreserve.preserveForRecovery(reason: "Recording session was aborted before final export.")
            }
        }
        recordingStateMachine.stop(sessionID: stoppedSessionID)
        sessionID = UUID()
        isRecording = false
        recordingStartedAtUptime = nil
        recordingBaseOffsetMilliseconds = 0
        AudioLevelManager.shared.updateRecordingState(false)

        if isTapActive {
            systemAudioPipeline?.stop()
            systemAudioPipeline = nil
            processTap?.invalidate()
            processTap = nil
            isTapActive = false
            print("System audio tap invalidated")
        }

        firstAudioOffsets.removeAll()
        timelineAudioFrameCounts.removeAll()
        timelineAnchorSamplePositions.removeAll()
        cleanupAudioEngine()
        disconnectSTTProviders()
        recordingStateMachine.reset()
        isRecoveringSTT = false
        isStoppingRecording = false
        micSTTConnectingSessionID = nil
        systemSTTConnectingSessionID = nil
        completePendingStopCallbacks(for: stoppedSessionID)

        print("Internal cleanup completed")
    }

    private func restartMicrophone() {
        guard isRecording, !isStoppingOrTearingDown else { return }
        // One recovery owns the detached pipeline until it has drained. Repeated device
        // notifications during that short window are coalesced into the same restart.
        guard micRestartTask == nil else { return }

        guard micRetryCount < maxMicRetries else {
            let message = "Microphone failed to recover after \(maxMicRetries) attempts."
            print("⛔️ \(message) Stopping recording.")
            errorMessage = message
            stopRecording()
            return
        }

        print("🔄 Restarting microphone capture (attempt \(micRetryCount + 1))")
        micRetryCount += 1
        let restartSessionID = sessionID
        let restartAttemptID = UUID()
        micRestartAttemptID = restartAttemptID

        // Stop the producer first, but retain and gracefully drain every buffer already
        // copied by the old tap. `cleanupAudioEngine` sees a nil property and therefore
        // cannot hard-stop this retained pipeline.
        let previousMicPipeline = micAudioPipeline
        micAudioPipeline = nil

        cleanupAudioEngine()
        recordingStateMachine.markRecovering(sessionID: restartSessionID)
        publishRecordingActivityState()

        micRestartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.micRestartAttemptID == restartAttemptID {
                    self.micRestartAttemptID = nil
                    self.micRestartTask = nil
                }
            }
            if let previousMicPipeline {
                await previousMicPipeline.drainAndStop()
            }
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
            guard !Task.isCancelled,
                  self.isActiveSession(restartSessionID),
                  !self.isStoppingOrTearingDown else { return }
            await self.startMicrophoneTapAfterRestart(sessionToken: restartSessionID)
        }
    }

    private func startMicrophoneTapAfterRestart(sessionToken: UUID) async {
        guard isActiveSession(sessionToken), isRecording else { return }
        _ = await startMicrophoneTap(sessionToken: sessionToken)
    }

    /// Starts a microphone tap using the STT provider.
    private func startMicrophoneTap(sessionToken: UUID) async -> Bool {
        print("🎤 Starting microphone tap...")

        guard isActiveSession(sessionToken),
              !Task.isCancelled,
              !isStoppingOrTearingDown else { return false }

        do {
            let inputNode = audioEngine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)

            guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                                   sampleRate: 16_000,
                                                   channels: 1,
                                                   interleaved: false) else {
                print("❌ Failed to create target audio format for mic tap")
                restartMicrophone()
                return false
            }

            // Start the audio engine and install the tap *before* awaiting the STT
            // connection, so mic audio is captured from t=0. Audio arriving while the
            // provider is still loading (e.g. Fun-ASR's ~2 s model load) is ring-buffered
            // and flushed on connect, instead of being lost during the connect window.
            audioEngine.prepare()
            try audioEngine.start()
            guard isActiveSession(sessionToken) else {
                cleanupAudioEngine()
                return false
            }
            fillTimelineGapWithSilenceIfNeeded(for: .mic, sessionToken: sessionToken)
            markRecordingActive(sessionToken: sessionToken)

            guard let pipeline = makeAudioPipeline(
                source: .mic,
                sessionToken: sessionToken,
                inputFormat: recordingFormat,
                targetFormat: targetFormat
            ) else {
                print("❌ Failed to create audio pipeline for mic tap")
                restartMicrophone()
                return false
            }
            micAudioPipeline?.stop()
            micAudioPipeline = pipeline

            let captureTimeline = recordingTimeline

            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self, pipeline, captureTimeline] buffer, when in
                guard buffer.frameLength > 0 else {
                    print("❌ Invalid mic buffer detected - restarting")
                    Task { @MainActor [weak self] in
                        self?.restartMicrophone()
                    }
                    return
                }

                let samplePosition: Int64?
                if let captureTimeline {
                    let callbackHostTime = AudioGetCurrentHostTime()
                    samplePosition = captureTimeline.captureStartSamplePosition(
                        hostTime: when.isHostTimeValid ? when.hostTime : nil,
                        frameCount: Int(buffer.frameLength),
                        sourceSampleRate: buffer.format.sampleRate,
                        callbackHostTime: callbackHostTime
                    )
                } else {
                    samplePosition = nil
                }
                pipeline.enqueue(buffer, startingAtSample: samplePosition)
            }

            do {
                _ = try await connectSTTProvider(
                    for: .mic,
                    offsetMilliseconds: elapsedRecordingMilliseconds(),
                    sessionToken: sessionToken
                )
            } catch {
                guard isActiveSession(sessionToken),
                      !Task.isCancelled,
                      !isStoppingOrTearingDown else { return false }
                disableSTTOnly(
                    for: .mic,
                    message: LanguageManager.shared.t(
                        "麦克风实时转录不可用，但麦克风原声仍会继续保存。",
                        "Microphone transcription is unavailable, but its raw audio will keep recording."
                    )
                )
                print("⚠️ Microphone STT connection failed while capture remains active: \(error)")
            }
            guard isActiveSession(sessionToken),
                  !Task.isCancelled,
                  !isStoppingOrTearingDown else { return false }

            print("✅ Microphone tap started successfully")
            micRetryCount = 0
            return true
        } catch {
            guard isActiveSession(sessionToken),
                  !Task.isCancelled,
                  !isStoppingOrTearingDown,
                  !isFinalizingStoppedRecording else { return false }
            print("❌ Failed to start microphone tap: \(error)")
            errorMessage = ErrorHandler.shared.handleError(error)
            abortRecording()
            return false
        }
    }

    private func cleanupAudioEngine() {
        print("🧹 Cleaning up audio engine...")

        if audioEngine.isRunning {
            audioEngine.stop()
            print("⏹️ Audio engine stopped")
        }

        micAudioPipeline?.stop()
        micAudioPipeline = nil

        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: 0)
        print("🔇 Input tap removed")

        audioEngine.reset()
        print("🔄 Audio engine reset")

        audioEngine = AVAudioEngine()
        registerAudioEngineConfigObserver()
        print("✨ Fresh audio engine created")
    }

    private func startSystemAudioTap(sessionToken: UUID? = nil) async {
        print("🎧 Resolving supported meeting audio processes...")
        let activeSessionToken = sessionToken ?? sessionID

        guard isActiveSession(activeSessionToken),
              !Task.isCancelled,
              !isStoppingOrTearingDown else { return }

        let meetingProcesses: [AudioProcess]
        do {
            meetingProcesses = try AudioProcessController.resolveSupportedMeetingAudioProcesses()
        } catch {
            guard isActiveSession(activeSessionToken) else { return }
            print("❌ Failed to read the Core Audio process list: \(error.localizedDescription)")
            degradeSystemAudioToMicOnly(LanguageManager.shared.t(
                "无法读取会议软件的音频进程。为保护隐私，本次不会录制其他系统声音，已继续仅麦克风模式。请确认腾讯会议或飞书已经启动后重试。",
                "Could not read meeting-app audio processes. To protect privacy, no other system audio will be captured; recording continues in mic-only mode. Make sure Tencent Meeting or Feishu is running, then try again."
            ))
            return
        }

        let meetingProcessObjectIDs = AudioProcessController.supportedMeetingProcessObjectIDs(
            in: meetingProcesses
        )
        guard !meetingProcessObjectIDs.isEmpty else {
            guard isActiveSession(activeSessionToken) else { return }
            degradeSystemAudioToMicOnly(LanguageManager.shared.t(
                "未检测到腾讯会议、WeMeet、VooV 或飞书/Lark 的音频进程。请先打开会议软件、加入会议并确认能听到声音，再重新开始录制；为保护隐私，本次不会录制其他系统声音，已继续仅麦克风模式。",
                "No Tencent Meeting, WeMeet, VooV, Feishu, or Lark audio process was found. Open and join the meeting, confirm that you can hear it, then start recording again. To protect privacy, no other system audio will be captured; recording continues in mic-only mode."
            ))
            return
        }

        let matchedNames = meetingProcesses.map(\.name).joined(separator: ", ")
        print("🎯 Meeting audio allowlist: \(matchedNames) [\(meetingProcessObjectIDs)]")

        let hasSystemAudioPermission = await checkSystemAudioPermissions()
        guard !Task.isCancelled, !isStoppingOrTearingDown else { return }
        guard hasSystemAudioPermission else {
            guard isActiveSession(activeSessionToken) else { return }
            print("⚠️ System audio recording permission denied; keeping microphone recording active.")
            degradeSystemAudioToMicOnly(LanguageManager.shared.t(
                "未授予系统音频权限，已继续使用仅麦克风模式。",
                "System audio permission was not granted; continuing in mic-only mode."
            ))
            return
        }

        guard isActiveSession(activeSessionToken) else { return }

        // Capture only the Core Audio objects resolved from the supported meeting-app
        // allowlist. Never use a global tap: unrelated notifications, music, or calls must not
        // enter the interview recording.
        let target = TapTarget.systemAudio(processObjectIDs: meetingProcessObjectIDs)
        let newTap = ProcessTap(target: target)
        newTap.activate()

        guard isActiveSession(activeSessionToken),
              !Task.isCancelled,
              !isStoppingOrTearingDown else {
            newTap.invalidate()
            return
        }

        if let tapError = newTap.errorMessage {
            newTap.invalidate()
            guard isActiveSession(activeSessionToken) else { return }
            let errorMsg = "Failed to activate system audio tap: \(tapError)"
            print("❌ \(errorMsg)")
            degradeSystemAudioToMicOnly("系统音频捕获不可用，已自动切换为仅麦克风模式。")
            return
        }

        processTap = newTap
        isTapActive = true

        do {
            try startTapIO(newTap, sessionToken: activeSessionToken)
            guard isActiveSession(activeSessionToken),
                  !Task.isCancelled,
                  !isStoppingOrTearingDown else {
                newTap.invalidate()
                if processTap === newTap {
                    processTap = nil
                }
                isTapActive = false
                return
            }

            markRecordingActive(sessionToken: activeSessionToken)
            print("✅ Meeting-app audio tap started successfully")
        } catch {
            guard isActiveSession(activeSessionToken) else { return }
            let errorMsg = "Failed to start system audio tap IO: \(error.localizedDescription)"
            print("❌ \(errorMsg)")
            newTap.invalidate()
            isTapActive = false
            degradeSystemAudioToMicOnly("系统音频捕获不可用，已自动切换为仅麦克风模式。")
        }
    }

    private func degradeSystemAudioToMicOnly(_ message: String) {
        systemAudioPipeline?.stop()
        systemAudioPipeline = nil
        processTap?.invalidate()
        processTap = nil
        isTapActive = false
        systemAudioLevel = 0
        AudioLevelManager.shared.updateSystemLevel(0)

        systemSTT?.disconnect()
        systemSTT = nil
        systemPendingAudioChunks.removeAll(keepingCapacity: false)
        systemPendingAudioByteCount = 0
        systemSTTConnectTask?.cancel()
        systemSTTConnectTask = nil
        systemSTTConnectingSessionID = nil

        print("⚠️ \(message)")
        warningMessage = message
    }

    @MainActor
    private func checkSystemAudioPermissions() async -> Bool {
        if permission.status == .authorized {
            return true
        }

        permission.request()

        for _ in 0..<10 {
            guard !Task.isCancelled, !isStoppingOrTearingDown else { return false }
            if permission.status == .authorized {
                return true
            }
            do {
                try await Task.sleep(nanoseconds: 500_000_000)
            } catch {
                return false
            }
        }

        return !Task.isCancelled && permission.status == .authorized
    }

    private func startTapIO(_ tap: ProcessTap, sessionToken: UUID) throws {
        guard var streamDescription = tap.tapStreamDescription else {
            throw NSError(domain: "AudioManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to get audio format from tap."])
        }

        guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
            throw NSError(domain: "AudioManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create AVAudioFormat from tap."])
        }

        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                               sampleRate: 16_000,
                                               channels: 1,
                                               interleaved: false) else {
            throw NSError(domain: "AudioManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create target audio format for system tap."])
        }

        guard let pipeline = makeAudioPipeline(
            source: .system,
            sessionToken: sessionToken,
            inputFormat: format,
            targetFormat: targetFormat
        ) else {
            throw NSError(domain: "AudioManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create audio pipeline for system tap."])
        }
        systemAudioPipeline?.stop()
        systemAudioPipeline = pipeline

        let captureTimeline = recordingTimeline
        try tap.run(on: tapQueue) { [pipeline, captureTimeline] _, inInputData, inInputTime, _, _ in
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                bufferListNoCopy: inInputData,
                deallocator: nil
            ) else {
                return
            }

            let samplePosition: Int64?
            if let captureTimeline {
                let callbackHostTime = AudioGetCurrentHostTime()
                let timestamp = inInputTime.pointee
                samplePosition = captureTimeline.captureStartSamplePosition(
                    hostTime: timestamp.mFlags.contains(.hostTimeValid) ? timestamp.mHostTime : nil,
                    frameCount: Int(buffer.frameLength),
                    sourceSampleRate: buffer.format.sampleRate,
                    callbackHostTime: callbackHostTime
                )
            } else {
                samplePosition = nil
            }
            pipeline.enqueue(buffer, startingAtSample: samplePosition)

        } invalidationHandler: { [weak self, weak tap] _ in
            Task { @MainActor [weak self, weak tap] in
                guard let self, let tap, self.processTap === tap,
                      !self.isStoppingOrTearingDown else { return }
                print("⚠️ System audio tap became unavailable; continuing with microphone only.")
                self.degradeSystemAudioToMicOnly(LanguageManager.shared.t(
                    "系统音频捕获意外中断，已继续使用仅麦克风模式。",
                    "System audio capture stopped unexpectedly; continuing in mic-only mode."
                ))
            }
        }
    }

    func stopRecording(completion: (() -> Void)? = nil) {
        let requestedSessionID = sessionID
        if let completion {
            pendingStopCompletions[requestedSessionID, default: []].append(completion)
        }
        guard !isStoppingRecording, !isFinalizingStoppedRecording else {
            return
        }
        guard isRecording
            || micSTT != nil
            || systemSTT != nil
            || isTapActive
            || recordingStateMachine.state.sessionID != nil else {
            completePendingStopCallbacks(for: requestedSessionID)
            return
        }

        let stoppedSessionID = sessionID
        // Freeze the intended audio end before hardware teardown and STT finalization. Using a
        // later clock reading would append seconds of artificial silence while recognizers flush.
        let recordingStopSamplePosition = recordingTimeline?.currentSamplePosition()
        let recorderToFinish = synchronizedRecorder
        isStoppingRecording = true
        // A graceful stop must not cancel a recognizer that is still loading: captured mic
        // PCM is buffered for it. Startup methods check the stopping flag after every await,
        // so keeping this task alive cannot reinstall capture hardware during teardown.
        let startupTask = startRecordingTask
        startRecordingTask = nil
        let restartTask = micRestartTask
        micRestartTask = nil
        micRestartAttemptID = nil
        restartTask?.cancel()
        print("Stopping recording...")

        micAudioLevel = 0.0
        systemAudioLevel = 0.0
        AudioLevelManager.shared.updateMicLevel(0.0)
        AudioLevelManager.shared.updateSystemLevel(0.0)

        // Detach the pipelines before stopping the hardware producers. Buffers that were
        // already copied stay owned by these local references and are drained below; capture
        // callbacks racing with teardown can no longer enqueue new work.
        let micPipeline = micAudioPipeline
        let systemPipeline = systemAudioPipeline
        micAudioPipeline = nil
        systemAudioPipeline = nil

        if isTapActive {
            processTap?.invalidate()
            processTap = nil
            isTapActive = false
            print("System audio tap invalidated")
        }

        cleanupAudioEngine()
        micRetryCount = 0
        isFinalizingStoppedRecording = true
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            // Normal stop is graceful: every buffer accepted by either capture callback is
            // converted and delivered before providers see end-of-stream.
            await withTaskGroup(of: Void.self) { group in
                if let micPipeline {
                    group.addTask { await micPipeline.drainAndStop() }
                }
                if let systemPipeline {
                    group.addTask { await systemPipeline.drainAndStop() }
                }
                for await _ in group {}
            }

            // A configuration-change recovery may own the previous mic pipeline rather than
            // `micAudioPipeline`. Cancellation prevents it from reinstalling capture; awaiting
            // it ensures that retained pipeline has delivered its tail before STT finalization.
            if let restartTask {
                await restartTask.value
            }

            var completedRecordingArtifact: RecordingArtifact?
            if let recorderToFinish {
                let result = await recorderToFinish.finish(
                    atSamplePosition: recordingStopSamplePosition
                )
                switch result {
                case .success(let artifact):
                    completedRecordingArtifact = artifact
                case .failure(let error):
                    let message = LanguageManager.shared.t(
                        "本地双轨录音导出失败；原始音频已保留，可在下次启动时恢复。",
                        "Dual-track export failed. Raw audio was preserved for recovery on next launch."
                    )
                    print("⚠️ \(message) \(error.localizedDescription)")
                    self.warningMessage = message
                }
            }

            guard self.sessionID == stoppedSessionID else {
                self.completePendingStopCallbacks(for: stoppedSessionID)
                return
            }

            if let startupTask {
                await startupTask.value
            }

            guard self.sessionID == stoppedSessionID else {
                self.completePendingStopCallbacks(for: stoppedSessionID)
                return
            }

            // If stop races with the lazy system recognizer's cold start, let that connection
            // finish so the buffered opening/tail audio can still be flushed in order.
            if !self.systemPendingAudioChunks.isEmpty {
                self.ensureSystemSTTConnectedLazily(sessionToken: stoppedSessionID)
            }
            if let systemSTTConnectTask = self.systemSTTConnectTask {
                await systemSTTConnectTask.value
            }

            guard self.sessionID == stoppedSessionID else {
                self.completePendingStopCallbacks(for: stoppedSessionID)
                return
            }

            self.recordingStateMachine.stop(sessionID: stoppedSessionID)
            self.publishRecordingActivityState()
            self.sendFinalAudioToSTTProviders()

            let micProvider = self.micSTT
            let systemProvider = self.systemSTT
            let timeout = self.finalFlushTimeout

            var micFinalizationStatus: STTFinalizationStatus?
            var systemFinalizationStatus: STTFinalizationStatus?
            if let micProvider {
                micFinalizationStatus = await micProvider.awaitPendingFinalization(timeout: timeout)
            }
            if let systemProvider {
                systemFinalizationStatus = await systemProvider.awaitPendingFinalization(timeout: timeout)
            }
            await self.awaitMainQueueBarrier()

            let finalizationStatuses = [micFinalizationStatus, systemFinalizationStatus].compactMap { $0 }

            if finalizationStatuses.contains(where: \.mayHaveMissedTailAudio) {
                let message = "语音识别收尾超时，最后几秒转录可能未完成。"
                print("⚠️ \(message)")
                self.warningMessage = message
            } else if finalizationStatuses.contains(.resultDrainTimedOut) {
                let message = "语音识别结果流关闭较慢，已保存已收到的转录内容。"
                print("ℹ️ \(message)")
                self.warningMessage = message
            }

            // Offline corrections (e.g. sherpa-onnx speaker diarization refinement)
            // run while still on this stopped session so any speakerId/Tag updates
            // land before we tear the providers down.
            if let micProvider,
               micProvider.capabilities.supportsCorrections,
               micFinalizationStatus == .completed {
                await micProvider.applyOfflineRefinement()
            }
            if let systemProvider,
               systemProvider.capabilities.supportsCorrections,
               systemFinalizationStatus == .completed {
                await systemProvider.applyOfflineRefinement()
            }
            await self.awaitMainQueueBarrier()

            guard self.sessionID == stoppedSessionID else {
                self.isFinalizingStoppedRecording = false
                self.completePendingStopCallbacks(for: stoppedSessionID)
                return
            }

            self.disconnectSTTProviders()
            let shutdownTimeout: TimeInterval = 30
            if let micProvider {
                _ = await micProvider.awaitShutdown(timeout: shutdownTimeout)
            }
            if let systemProvider {
                _ = await systemProvider.awaitShutdown(timeout: shutdownTimeout)
            }
            self.synchronizedRecorder = nil
            self.recordingTimeline = nil
            self.recordingMeetingID = nil
            if let completedRecordingArtifact {
                self.latestRecordingArtifact = completedRecordingArtifact
                NotificationCenter.default.post(
                    name: .meetingRecordingArtifactReady,
                    object: completedRecordingArtifact
                )
            }
            self.firstAudioOffsets.removeAll()
            self.timelineAudioFrameCounts.removeAll()
            self.timelineAnchorSamplePositions.removeAll()
            self.recordingStateMachine.reset()
            self.isRecording = false
            self.isRecoveringSTT = false
            self.recordingStartedAtUptime = nil
            self.recordingBaseOffsetMilliseconds = 0
            AudioLevelManager.shared.updateRecordingState(false)
            self.isFinalizingStoppedRecording = false
            self.isStoppingRecording = false
            print("Recording stopped")
            self.completePendingStopCallbacks(for: stoppedSessionID)
        }
    }

    private func completePendingStopCallbacks(for sessionID: UUID) {
        let callbacks = pendingStopCompletions.removeValue(forKey: sessionID) ?? []
        callbacks.forEach { $0() }
    }

    private func makeAudioPipeline(
        source: AudioSource,
        sessionToken: UUID,
        inputFormat: AVAudioFormat,
        targetFormat: AVAudioFormat
    ) -> AudioProcessingPipeline? {
        AudioProcessingPipeline(
            source: source,
            inputFormat: inputFormat,
            targetFormat: targetFormat,
            onTimedAudioData: { [weak self] data, source, samplePosition in
                DispatchQueue.main.async { [weak self] in
                    self?.sendAudioData(
                        data,
                        source: source,
                        sessionToken: sessionToken,
                        samplePosition: samplePosition
                    )
                }
            },
            onAudioLevel: { [weak self] level, source in
                DispatchQueue.main.async { [weak self] in
                    self?.updateAudioLevel(level, source: source, sessionToken: sessionToken)
                }
            }
        )
    }

    private func markRecordingActive(sessionToken: UUID) {
        guard isActiveSession(sessionToken) else { return }
        recordingStateMachine.markRecording(sessionID: sessionToken)
        publishRecordingActivityState()
        micRetryCount = 0
    }

    private func updateAudioLevel(_ level: Float, source: AudioSource, sessionToken: UUID) {
        guard isRecording, isActiveSession(sessionToken) else { return }
        switch source {
        case .mic:
            micAudioLevel = level
            AudioLevelManager.shared.updateMicLevel(level)
        case .system:
            systemAudioLevel = level
            AudioLevelManager.shared.updateSystemLevel(level)
        }
    }

    private func stopAudioPipelines() {
        micAudioPipeline?.stop()
        micAudioPipeline = nil
        systemAudioPipeline?.stop()
        systemAudioPipeline = nil
    }

    private func sendAudioData(
        _ data: Data,
        source: AudioSource,
        sessionToken: UUID,
        samplePosition: Int64? = nil
    ) {
        guard isActiveSession(sessionToken) else { return }
        let recorderSamplePosition: Int64
        if let samplePosition {
            recorderSamplePosition = max(0, samplePosition)
        } else {
            let anchor = max(0, timelineAnchorSamplePositions[source] ?? 0)
            let frames = Int64(max(0, timelineAudioFrameCounts[source] ?? 0))
            let (position, overflow) = anchor.addingReportingOverflow(frames)
            recorderSamplePosition = overflow ? Int64.max : position
        }
        synchronizedRecorder?.append(
            data,
            source: source,
            atSamplePosition: recorderSamplePosition
        )
        if timelineAnchorSamplePositions[source] == nil {
            let anchor = max(0, samplePosition ?? recorderSamplePosition)
            timelineAnchorSamplePositions[source] = anchor
            firstAudioOffsets[source] = Self.saturatedTimelineAddition(
                recordingBaseOffsetMilliseconds,
                Self.milliseconds(forSamplePosition: anchor)
            )
            timelineAudioFrameCounts[source] = 0
        }

        let incomingFrames = data.count / MemoryLayout<Int16>.size
        guard incomingFrames > 0 else { return }
        let deliveredFrames = timelineAudioFrameCounts[source] ?? 0
        let anchor = timelineAnchorSamplePositions[source] ?? 0
        let relativeStart = samplePosition.map { max(0, $0 - anchor) }
            ?? Int64(deliveredFrames)
        let missingFrames = max(0, relativeStart - Int64(deliveredFrames))
        if missingFrames > 0 {
            deliverSilenceToSTT(
                frameCount: missingFrames,
                source: source,
                sessionToken: sessionToken
            )
        }

        let currentFrames = Int64(timelineAudioFrameCounts[source] ?? 0)
        let overlapFrames = max(0, currentFrames - relativeStart)
        let trimmedFrames = min(Int64(incomingFrames), overlapFrames)
        guard trimmedFrames < Int64(incomingFrames) else { return }
        let byteOffset = Int(trimmedFrames) * MemoryLayout<Int16>.size
        deliverAudioToSTT(
            byteOffset == 0 ? data : data.subdata(in: byteOffset..<data.count),
            source: source,
            sessionToken: sessionToken
        )
    }

    private func deliverSilenceToSTT(
        frameCount: Int64,
        source: AudioSource,
        sessionToken: UUID
    ) {
        var remaining = frameCount
        while remaining > 0 {
            let frames = Int(min(remaining, 16_000))
            deliverAudioToSTT(
                Data(repeating: 0, count: frames * MemoryLayout<Int16>.size),
                source: source,
                sessionToken: sessionToken
            )
            remaining -= Int64(frames)
        }
    }

    private func deliverAudioToSTT(
        _ data: Data,
        source: AudioSource,
        sessionToken: UUID
    ) {
        guard isActiveSession(sessionToken), !data.isEmpty else { return }
        timelineAudioFrameCounts[source, default: 0] += data.count / MemoryLayout<Int16>.size
        switch source {
        case .mic:
            if let micSTT {
                micSTT.sendAudio(data)
            } else if micSTTUnavailableSessionID == sessionToken {
                return
            } else {
                // Provider still connecting (cold model load): buffer so the opening
                // speech isn't lost; flushed in connectSTTProvider once micSTT is set.
                bufferPendingMicAudio(data)
            }
        case .system:
            if let systemSTT {
                systemSTT.sendAudio(data)
            } else if systemSTTUnavailableSessionID == sessionToken {
                return
            } else {
                // Keep all audio received during the recognizer's cold start. Dropping it
                // would lose the interviewer's opening sentence and compress this source's
                // timestamps relative to the microphone.
                bufferPendingSystemAudio(data)
                // Load the second large recognizer only after the mic recognizer is ready.
                // Capture is already active, so this sequencing saves memory without losing
                // the beginning of the system track.
                if micSTT != nil || micSTTUnavailableSessionID == sessionToken {
                    ensureSystemSTTConnectedLazily(sessionToken: sessionToken)
                }
            }
        }
    }

    private func ensureSystemSTTConnectedLazily(sessionToken: UUID) {
        guard isActiveSession(sessionToken) else { return }
        guard systemSTTUnavailableSessionID != sessionToken else { return }
        guard systemSTT == nil, systemSTTConnectingSessionID == nil else { return }
        systemSTTConnectingSessionID = sessionToken
        let offset = firstAudioOffsets[.system] ?? elapsedRecordingMilliseconds()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.systemSTTConnectingSessionID == sessionToken {
                    self.systemSTTConnectingSessionID = nil
                    self.systemSTTConnectTask = nil
                }
            }
            do {
                guard self.isActiveSession(sessionToken) else { return }
                _ = try await self.connectSTTProvider(
                    for: .system,
                    offsetMilliseconds: offset,
                    sessionToken: sessionToken
                )
            } catch {
                guard self.isActiveSession(sessionToken) else { return }
                print("⚠️ Lazy system STT connect failed: \(ErrorHandler.shared.handleError(error))")
                self.disableSTTOnly(
                    for: .system,
                    message: LanguageManager.shared.t(
                        "系统音频转录不可用，但系统原声仍会继续保存。",
                        "System audio transcription is unavailable, but its raw audio will keep recording."
                    )
                )
            }
        }
        systemSTTConnectTask = task
    }

    private func stopStartRecordingTask() {
        startRecordingTask?.cancel()
        startRecordingTask = nil
    }

    private func connectSTTProvider(
        for source: AudioSource,
        offsetMilliseconds: Int,
        sessionToken: UUID? = nil
    ) async throws -> STTProvider {
        if let existing = provider(for: source) {
            return existing
        }

        let providerSessionID = sessionToken ?? sessionID
        guard isActiveSession(providerSessionID) else {
            throw URLError(.cancelled)
        }

        if source == .mic, micSTTConnectingSessionID == providerSessionID {
            return try await awaitInFlightMicSTT(sessionToken: providerSessionID)
        }
        if source == .mic {
            micSTTConnectingSessionID = providerSessionID
        }
        defer {
            if source == .mic, micSTTConnectingSessionID == providerSessionID {
                micSTTConnectingSessionID = nil
            }
        }

        let provider = try await makeConnectedSTTProvider(
            for: source,
            sessionToken: providerSessionID,
            offsetMilliseconds: offsetMilliseconds
        )
        guard isActiveSession(providerSessionID) else {
            provider.disconnect()
            throw URLError(.cancelled)
        }

        // A defensive loser check also covers future call paths that may bypass the explicit
        // mic single-flight gate. MainActor serializes installation, so exactly one provider
        // owns the pending PCM and every later connection is disconnected here.
        if let winner = self.provider(for: source) {
            provider.disconnect()
            return winner
        }
        if source == .system,
           systemSTTConnectingSessionID != providerSessionID {
            provider.disconnect()
            throw URLError(.cancelled)
        }

        switch source {
        case .mic:
            micSTT = provider
            flushPendingMicAudio(to: provider)
            if !systemPendingAudioChunks.isEmpty {
                ensureSystemSTTConnectedLazily(sessionToken: providerSessionID)
            }
        case .system:
            systemSTT = provider
            flushPendingSystemAudio(to: provider)
        }

        return provider
    }

    private func awaitInFlightMicSTT(sessionToken: UUID) async throws -> STTProvider {
        while micSTTConnectingSessionID == sessionToken {
            if let micSTT { return micSTT }
            guard isActiveSession(sessionToken) else { throw URLError(.cancelled) }
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(25))
        }

        guard isActiveSession(sessionToken), let micSTT else {
            throw URLError(.cancelled)
        }
        return micSTT
    }

    /// Ring-buffers mic audio captured before the provider finishes connecting, capped at
    /// `VoiceInputTiming.maxPendingAudioBytes` so a slow/failed connect can't grow unbounded.
    private func bufferPendingMicAudio(_ data: Data) {
        micPendingAudioChunks.append(data)
        micPendingAudioByteCount += data.count
        while micPendingAudioByteCount > VoiceInputTiming.maxPendingAudioBytes,
              !micPendingAudioChunks.isEmpty {
            let removed = micPendingAudioChunks.removeFirst()
            micPendingAudioByteCount -= removed.count
            advanceFirstAudioOffsetAfterDropping(bytes: removed.count, source: .mic)
        }
    }

    private func flushPendingMicAudio(to provider: STTProvider) {
        guard !micPendingAudioChunks.isEmpty else { return }
        let chunks = micPendingAudioChunks
        micPendingAudioChunks.removeAll(keepingCapacity: true)
        micPendingAudioByteCount = 0
        chunks.forEach { provider.sendAudio($0) }
    }

    private func bufferPendingSystemAudio(_ data: Data) {
        systemPendingAudioChunks.append(data)
        systemPendingAudioByteCount += data.count
        while systemPendingAudioByteCount > VoiceInputTiming.maxPendingAudioBytes,
              !systemPendingAudioChunks.isEmpty {
            let removed = systemPendingAudioChunks.removeFirst()
            systemPendingAudioByteCount -= removed.count
            advanceFirstAudioOffsetAfterDropping(bytes: removed.count, source: .system)
        }
    }

    private func flushPendingSystemAudio(to provider: STTProvider) {
        guard !systemPendingAudioChunks.isEmpty else { return }
        let chunks = systemPendingAudioChunks
        systemPendingAudioChunks.removeAll(keepingCapacity: true)
        systemPendingAudioByteCount = 0
        chunks.forEach { provider.sendAudio($0) }
    }

    /// Pending PCM is mono Int16 at 16 kHz: 32 bytes represent one millisecond.
    /// If the bounded queue ever overflows, advance its time anchor with the discarded head
    /// instead of silently moving later speech earlier on the meeting timeline.
    private func advanceFirstAudioOffsetAfterDropping(bytes: Int, source: AudioSource) {
        let droppedFrames = bytes / MemoryLayout<Int16>.size
        guard droppedFrames > 0 else { return }
        let advancedAnchor = (timelineAnchorSamplePositions[source] ?? 0) + Int64(droppedFrames)
        timelineAnchorSamplePositions[source] = advancedAnchor
        firstAudioOffsets[source] = recordingBaseOffsetMilliseconds
            + Int(advancedAnchor * 1_000 / 16_000)
        timelineAudioFrameCounts[source] = max(
            0,
            (timelineAudioFrameCounts[source] ?? 0) - droppedFrames
        )
    }

    /// Fills a capture outage with zero-valued PCM before accepting samples from the new tap.
    /// Recognizers derive timestamps from sample counts, so omitting the outage would move all
    /// later microphone text earlier relative to the continuously captured system track.
    private func fillTimelineGapWithSilenceIfNeeded(for source: AudioSource, sessionToken: UUID) {
        guard let anchorMilliseconds = firstAudioOffsets[source] else { return }
        let missingFrames = Self.timelineCatchUpFrameCount(
            elapsedMilliseconds: elapsedRecordingMilliseconds(),
            anchorMilliseconds: anchorMilliseconds,
            deliveredFrames: timelineAudioFrameCounts[source] ?? 0
        )
        guard missingFrames > 0 else { return }

        let framesPerChunk = 16_000
        var remainingFrames = missingFrames
        while remainingFrames > 0 {
            let chunkFrames = min(remainingFrames, framesPerChunk)
            sendAudioData(
                Data(repeating: 0, count: chunkFrames * MemoryLayout<Int16>.size),
                source: source,
                sessionToken: sessionToken
            )
            remainingFrames -= chunkFrames
        }
    }

    private func makeConnectedSTTProvider(
        for source: AudioSource,
        sessionToken: UUID,
        offsetMilliseconds: Int
    ) async throws -> STTProvider {
        var config = APIKeyValidator.shared.currentSTTConfig()
        config.speakerMode = recordingSpeakerMode
        let provider = sttProviderFactory.makeProvider()

        provider.onTranscriptUpdate = { [weak self, weak provider] update in
            DispatchQueue.main.async { [weak self, weak provider] in
                guard let self,
                      let provider,
                      self.sessionID == sessionToken,
                      self.isCurrentProvider(provider, for: source) else { return }
                // Use offset captured at first audio arrival; fall back to
                // connect-time offset if no audio has arrived yet for this source.
                let offset = self.firstAudioOffsets[source] ?? offsetMilliseconds
                self.handleTranscriptUpdate(
                    Self.offsetTranscriptUpdate(update, by: offset),
                    source: source
                )
            }
        }

        provider.onTranscriptCorrection = { [weak self, weak provider] corrections in
            DispatchQueue.main.async { [weak self, weak provider] in
                guard let self,
                      let provider,
                      self.sessionID == sessionToken,
                      self.isCurrentProvider(provider, for: source) else { return }
                let offset = self.firstAudioOffsets[source] ?? offsetMilliseconds
                self.applyCorrections(corrections, source: source, offsetMilliseconds: offset)
            }
        }

        provider.onError = { [weak self, weak provider] message in
            DispatchQueue.main.async { [weak self, weak provider] in
                guard let self, let provider, self.sessionID == sessionToken else { return }
                guard self.isCurrentProvider(provider, for: source) else {
                    print("ℹ️ Ignored STT error from retired \(source) provider: \(message)")
                    return
                }
                self.handleSTTProviderError(message, source: source)
            }
        }

        try await provider.connect(config: config)
        return provider
    }

    private func refreshSTTFactoryFromSettings() {
        let requested = UserDefaultsManager.shared.sttEngine
        guard requested != activeEngine else { return }
        activeEngine = requested
        sttProviderFactory = Self.factory(for: requested)
    }

    private static func factory(for engine: STTEngine) -> STTProviderFactory {
        switch engine {
        case .appleSpeechAnalyzer:
            if #available(macOS 26.0, *) {
                return SpeechAnalyzerSTTProviderFactory()
            }
            return UnavailableSTTProviderFactory(
                message: LanguageManager.shared.t(
                    "macOS 内置语音识别需要 macOS 26 或更高版本。请切换到本地 SenseVoice。",
                    "macOS built-in speech recognition requires macOS 26 or later. Switch to Local SenseVoice."
                )
            )
        case .sherpaSenseVoice:
            return SherpaSTTProviderFactory()
        case .funASRNano:
            return SherpaSTTProviderFactory(kind: .funASRNano)
        }
    }

    private func applyCorrections(
        _ corrections: [STTTranscriptCorrection],
        source: AudioSource,
        offsetMilliseconds: Int
    ) {
        guard !corrections.isEmpty else { return }
        var didChange = false
        for correction in corrections {
            let adjustedStart = Self.saturatedTimelineAddition(
                correction.startTime,
                offsetMilliseconds
            )
            let adjustedEnd = Self.saturatedTimelineAddition(
                correction.endTime,
                offsetMilliseconds
            )
            for index in transcriptChunks.indices {
                let chunk = transcriptChunks[index]
                guard chunk.source == source,
                      chunk.isFinal,
                      chunk.startTime == adjustedStart,
                      chunk.endTime == adjustedEnd else { continue }
                let newChunk = TranscriptChunk(
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
                transcriptChunks[index] = newChunk
                didChange = true
            }
        }
        if didChange {
            // touch the array to ensure SwiftUI republishes
            transcriptChunks = transcriptChunks
        }
    }

    private func stopMicRestartTask() {
        micRestartAttemptID = nil
        micRestartTask?.cancel()
        micRestartTask = nil
    }

    private func provider(for source: AudioSource) -> STTProvider? {
        switch source {
        case .mic:
            return micSTT
        case .system:
            return systemSTT
        }
    }

    private func isCurrentProvider(_ provider: STTProvider, for source: AudioSource) -> Bool {
        self.provider(for: source) === provider
    }

    private func isActiveSession(_ token: UUID) -> Bool {
        sessionID == token && recordingStateMachine.state.isActiveSession(token)
    }

    private func handleTranscriptUpdate(_ update: STTTranscriptUpdate, source: AudioSource) {
        let fixedIdentity: (tag: String?, id: Int?)
        if recordingSpeakerMode == .fixedByAudioSource {
            switch source {
            case .mic:
                fixedIdentity = ("candidate", 0)
            case .system:
                fixedIdentity = ("interviewer", 1)
            }
        } else {
            fixedIdentity = (update.speakerTag, update.speakerId)
        }
        if update.isFinal {
            if let id = activeInterimChunkId[source] {
                transcriptChunks.removeAll { $0.id == id }
                activeInterimChunkId[source] = nil
            }
            transcriptChunks.append(TranscriptChunk(
                source: source,
                text: update.text,
                isFinal: true,
                speakerTag: fixedIdentity.tag,
                speakerId: fixedIdentity.id,
                startTime: update.startTime,
                endTime: update.endTime
            ))
        } else {
            let id = activeInterimChunkId[source] ?? UUID()
            let chunk = TranscriptChunk(
                id: id,
                source: source,
                text: update.text,
                isFinal: false,
                speakerTag: fixedIdentity.tag,
                speakerId: fixedIdentity.id,
                startTime: update.startTime,
                endTime: update.endTime
            )
            if let idx = transcriptChunks.firstIndex(where: { $0.id == id }) {
                transcriptChunks[idx] = chunk
            } else {
                transcriptChunks.append(chunk)
                activeInterimChunkId[source] = id
            }
        }
    }

    private func handleSTTProviderError(_ message: String, source: AudioSource) {
        print("❌ STT provider error (\(source)): \(message)")
        if isStoppingOrTearingDown || isFinalizingStoppedRecording { return }
        disableSTTOnly(
            for: source,
            message: source == .system
                ? "系统音频转录不可用，但系统原声仍会继续保存。"
                : "麦克风实时转录不可用，但麦克风原声仍会继续保存。"
        )
    }

    /// Stops only the failed recognizer. The capture pipeline and synchronized recorder remain
    /// live, preserving both source tracks for post-meeting retranscription.
    private func disableSTTOnly(for source: AudioSource, message: String) {
        switch source {
        case .mic:
            micSTT?.disconnect()
            micSTT = nil
            micPendingAudioChunks.removeAll(keepingCapacity: false)
            micPendingAudioByteCount = 0
            micSTTConnectingSessionID = nil
            micSTTUnavailableSessionID = sessionID
            if !systemPendingAudioChunks.isEmpty {
                ensureSystemSTTConnectedLazily(sessionToken: sessionID)
            }
        case .system:
            systemSTT?.disconnect()
            systemSTT = nil
            systemPendingAudioChunks.removeAll(keepingCapacity: false)
            systemPendingAudioByteCount = 0
            systemSTTConnectTask?.cancel()
            systemSTTConnectTask = nil
            systemSTTConnectingSessionID = nil
            systemSTTUnavailableSessionID = sessionID
        }
        print("⚠️ \(message)")
        warningMessage = message
    }

    private func sendFinalAudioToSTTProviders() {
        micSTT?.sendLastAudio()
        systemSTT?.sendLastAudio()
    }

    /// All stop paths flush final audio via `sendFinalAudioToSTTProviders` and await
    /// `awaitPendingFinalization` before reaching here, so this only needs to tear down.
    private func disconnectSTTProviders() {
        micSTT?.disconnect()
        systemSTT?.disconnect()
        micSTT = nil
        systemSTT = nil
        micPendingAudioChunks.removeAll(keepingCapacity: false)
        micPendingAudioByteCount = 0
        systemPendingAudioChunks.removeAll(keepingCapacity: false)
        systemPendingAudioByteCount = 0
        systemSTTConnectTask?.cancel()
        systemSTTConnectTask = nil
        activeInterimChunkId.removeAll()
        micSTTConnectingSessionID = nil
        systemSTTConnectingSessionID = nil
        micSTTUnavailableSessionID = nil
        systemSTTUnavailableSessionID = nil
    }

    private func awaitMainQueueBarrier() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    nonisolated static func maximumTranscriptEndTime(in chunks: [TranscriptChunk]) -> Int {
        chunks.reduce(0) { maximumEnd, chunk in
            max(
                maximumEnd,
                max(
                    max(0, chunk.startTime ?? 0),
                    chunk.endTime ?? 0
                )
            )
        }
    }

    nonisolated static func maximumPersistedMeetingTimelineEnd(in meeting: Meeting?) -> Int {
        guard let meeting else { return 0 }
        return max(
            maximumTranscriptEndTime(in: meeting.transcriptChunks),
            meeting.accurateTranscriptReceipts.map(\.replacementEndMilliseconds).max() ?? 0
        )
    }

    nonisolated static func timelineCatchUpFrameCount(
        elapsedMilliseconds: Int,
        anchorMilliseconds: Int,
        deliveredFrames: Int,
        sampleRate: Int = 16_000
    ) -> Int {
        guard sampleRate > 0, elapsedMilliseconds > anchorMilliseconds else { return 0 }
        let (elapsedValue, elapsedOverflow) = elapsedMilliseconds.subtractingReportingOverflow(anchorMilliseconds)
        guard !elapsedOverflow, elapsedValue > 0 else { return 0 }
        let elapsedSinceAnchor = Int64(elapsedValue)
        let (frameProduct, frameOverflow) = elapsedSinceAnchor.multipliedReportingOverflow(by: Int64(sampleRate))
        guard !frameOverflow else { return 0 }
        let expectedFrames = frameProduct / 1_000
        let delivered = Int64(max(0, deliveredFrames))
        let (missingFrames, missingOverflow) = expectedFrames.subtractingReportingOverflow(delivered)
        guard !missingOverflow, missingFrames > 0 else { return 0 }
        return missingFrames >= Int64(Int.max) ? Int.max : Int(missingFrames)
    }

    private func elapsedRecordingMilliseconds() -> Int {
        guard let recordingStartedAtUptime else { return recordingBaseOffsetMilliseconds }
        let elapsed = ProcessInfo.processInfo.systemUptime - recordingStartedAtUptime
        let elapsedValue = max(0, elapsed * 1_000)
        let elapsedMilliseconds = elapsedValue.isFinite && elapsedValue < Double(Int.max)
            ? Int(elapsedValue)
            : Int.max
        return Self.saturatedTimelineAddition(
            recordingBaseOffsetMilliseconds,
            elapsedMilliseconds
        )
    }

    nonisolated static func offsetTranscriptUpdate(_ update: STTTranscriptUpdate, by offsetMilliseconds: Int) -> STTTranscriptUpdate {
        guard offsetMilliseconds > 0 else { return update }

        return STTTranscriptUpdate(
            text: update.text,
            isFinal: update.isFinal,
            speakerTag: update.speakerTag,
            speakerId: update.speakerId,
            startTime: update.startTime.map { saturatedTimelineAddition($0, offsetMilliseconds) },
            endTime: update.endTime.map { saturatedTimelineAddition($0, offsetMilliseconds) }
        )
    }

    nonisolated private static func saturatedTimelineAddition(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = max(0, lhs).addingReportingOverflow(max(0, rhs))
        return overflow ? Int.max : sum
    }

    nonisolated private static func milliseconds(forSamplePosition samplePosition: Int64) -> Int {
        let samples = max(0, samplePosition)
        let seconds = samples / 16_000
        let remainder = samples % 16_000
        let (wholeMilliseconds, overflow) = seconds.multipliedReportingOverflow(by: 1_000)
        guard !overflow, wholeMilliseconds < Int64(Int.max) else { return Int.max }
        let fractionalMilliseconds = remainder * 1_000 / 16_000
        let (total, totalOverflow) = wholeMilliseconds.addingReportingOverflow(fractionalMilliseconds)
        return totalOverflow || total >= Int64(Int.max) ? Int.max : Int(total)
    }

    private func handleAudioEngineConfigurationChange() {
        print("🔔 Audio engine configuration changed - restarting mic")
        restartMicrophone()
    }
}
