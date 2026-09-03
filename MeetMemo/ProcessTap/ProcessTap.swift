import SwiftUI
import AudioToolbox
import OSLog
import AVFoundation

enum TapTarget {
    case singleProcess(AudioProcess)
    /// Explicit Core Audio process allowlist for supported meeting clients. An empty list is
    /// invalid and must never be interpreted as permission to capture global system audio.
    case systemAudio(processObjectIDs: [AudioObjectID])

    var displayName: String {
        switch self {
        case .singleProcess(let process):
            return process.name
        case .systemAudio:
            return "Meeting Audio Output"
        }
    }

    var iconImage: NSImage {
        switch self {
        case .singleProcess(let process):
            return process.icon
        case .systemAudio:
            let genericAppIcon = NSWorkspace.shared.icon(for: .applicationBundle)
            genericAppIcon.size = NSSize(width: 32, height: 32)
            return genericAppIcon
        }
    }

    var loggingProcessName: String {
        switch self {
        case .singleProcess(let process):
            return process.name
        case .systemAudio:
            return "SystemAudioOutput"
        }
    }
}

@Observable
final class ProcessTap {

    typealias InvalidationHandler = (ProcessTap) -> Void

    enum InvalidationReason: Equatable {
        /// The owner is stopping, restarting, or otherwise deliberately tearing down the tap.
        case requested
        /// Reserved for a genuine Core Audio/device failure signal.
        case unexpected

        var notifiesHandler: Bool {
            self == .unexpected
        }
    }

    enum TapMixPolicy: Equatable {
        case includeProcesses([AudioObjectID])
    }

    enum ConfigurationError: LocalizedError, Equatable {
        case noSupportedMeetingAudioProcess

        var errorDescription: String? {
            switch self {
            case .noSupportedMeetingAudioProcess:
                return "未检测到腾讯会议、WeMeet、VooV 或飞书/Lark 的音频进程；为保护隐私，不会录制全系统音频。"
            }
        }
    }

    let target: TapTarget
    let muteWhenRunning: Bool
    private let logger: Logger

    private(set) var errorMessage: String? = nil

    init(target: TapTarget, muteWhenRunning: Bool = false) {
        self.target = target
        self.muteWhenRunning = muteWhenRunning
        self.logger = Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "io.github.lingeringautumn.meetmemo.interview",
            category: "\(String(describing: ProcessTap.self))(\(target.loggingProcessName))"
        )
    }

    @ObservationIgnored
    private var processTapID: AudioObjectID = .unknown
    @ObservationIgnored
    private var aggregateDeviceID = AudioObjectID.unknown
    @ObservationIgnored
    private var deviceProcID: AudioDeviceIOProcID?
    @ObservationIgnored
    private(set) var tapStreamDescription: AudioStreamBasicDescription?
    @ObservationIgnored
    private var invalidationHandler: InvalidationHandler?
    @ObservationIgnored
    private let invalidationLock = NSLock()
    @ObservationIgnored
    private let watchdogLock = NSLock()
    @ObservationIgnored
    private let watchdogQueue = DispatchQueue(label: "io.meetmemo.process-tap.watchdog", qos: .utility)
    @ObservationIgnored
    private var watchdogTimer: DispatchSourceTimer?
    @ObservationIgnored
    private var lastIOCallbackUptimeNanoseconds: UInt64 = 0

    @ObservationIgnored
    private(set) var activated = false

    var displayName: String {
        target.displayName
    }

    @MainActor
    func activate() {
        guard !activated else { return }
        activated = true

        logger.debug(#function)
        self.errorMessage = nil

        do {
            try prepare()
        } catch {
            logger.error("\(error, privacy: .public)")
            self.errorMessage = error.localizedDescription
        }
    }

    /// Tears down the tap.  Owner-requested teardown must not masquerade as an unexpected
    /// Core Audio failure: doing so used to make normal stop/degrade paths schedule a restart.
    func invalidate(reason: InvalidationReason = .requested) {
        invalidationLock.lock()
        guard activated else {
            invalidationLock.unlock()
            return
        }
        activated = false
        let handler = invalidationHandler
        self.invalidationHandler = nil
        invalidationLock.unlock()
        stopWatchdog()

        logger.debug(#function)

        if aggregateDeviceID.isValid {
            var err: OSStatus

            err = AudioDeviceStop(aggregateDeviceID, deviceProcID)
            if err != noErr { 
                logger.warning("Failed to stop aggregate device: \(err, privacy: .public)")
            }

            if let deviceProcID {
                err = AudioDeviceDestroyIOProcID(aggregateDeviceID, deviceProcID)
                if err != noErr {
                    logger.warning("Failed to destroy device I/O proc: \(err, privacy: .public)")
                }
                self.deviceProcID = nil
            }

            err = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            if err != noErr {
                logger.warning("Failed to destroy aggregate device: \(err, privacy: .public)")
            }
            aggregateDeviceID = .unknown
        }

        if processTapID.isValid {
            let errTapDestroy = AudioHardwareDestroyProcessTap(processTapID)
            if errTapDestroy != noErr {
                logger.warning("Failed to destroy audio tap: \(errTapDestroy, privacy: .public)")
            }
            self.processTapID = .unknown
        }

        if reason.notifiesHandler {
            handler?(self)
        }
    }

    private func prepare() throws {
        errorMessage = nil

        let policy = try Self.tapMixPolicy(for: target)
        let tapDescription: CATapDescription
        switch policy {
        case .includeProcesses(let processObjectIDs):
            tapDescription = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
            logger.debug("Configuring tap for \(processObjectIDs.count) explicit process(es).")
        }
        
        tapDescription.uuid = UUID()
        tapDescription.muteBehavior = muteWhenRunning ? .mutedWhenTapped : .unmuted
        var tapID: AUAudioObjectID = .unknown
        let errTapCreation = AudioHardwareCreateProcessTap(tapDescription, &tapID)

        guard errTapCreation == noErr else {
            errorMessage = "Process/System tap creation failed with error \(errTapCreation)"
            throw errorMessage ?? "Unknown error creating tap."
        }

        logger.debug("Created process/system tap #\(tapID, privacy: .public). Associated UUID: \(tapDescription.uuid.uuidString)")
        self.processTapID = tapID

        let allDeviceIDs = try AudioObjectID.system.getAllHardwareDevices()
        var outputUIDs: [String] = []
        var outputDeviceIDs: [AudioDeviceID] = []
        for devID in allDeviceIDs {
            do {
                let outputChans = try devID.getTotalOutputChannelCount()
                if outputChans > 0 {
                    let devUID = try devID.readDeviceUID()
                    outputUIDs.append(devUID)
                    outputDeviceIDs.append(devID)
                }
            } catch {
                logger.warning("Ignored device \(devID): \(error.localizedDescription)")
            }
        }

        if outputUIDs.isEmpty {
            throw "No hardware output devices found!"
        }

        let systemOutputID: AudioDeviceID
        do {
            logger.debug("Attempting to read default system output device ID...")
            systemOutputID = try AudioDeviceID.readDefaultSystemOutputDevice()
            logger.debug("Successfully read default system output device ID: \(systemOutputID)")
        } catch {
            logger.error("Failed to read default system output device ID: \(error)")
            throw error // Propagate error
        }

        let mainSubdeviceUID: String
        do {
            logger.debug("Attempting to read device UID for systemOutputID: \(systemOutputID)...")
            mainSubdeviceUID = try systemOutputID.readDeviceUID()
            logger.debug("Successfully read mainSubdeviceUID: \(mainSubdeviceUID)")
        } catch {
            logger.error("Failed to read device UID for systemOutputID \(systemOutputID): \(error)")
            throw error // Propagate error
        }
        
        let subDeviceListForAggregate: [[String: Any]]
        let aggregateDeviceName: String
        let aggregateUID = UUID().uuidString

        switch self.target {
        case .systemAudio:
            aggregateDeviceName = "Tap-SysAgg-\(mainSubdeviceUID.prefix(8))"
            subDeviceListForAggregate = [
                [kAudioSubDeviceUIDKey: mainSubdeviceUID]
            ]
            logger.debug("System mode: mainSubdeviceUID for aggregate: \(mainSubdeviceUID). Aggregate name: \(aggregateDeviceName)")
        case .singleProcess:
            aggregateDeviceName = "Tap-\(self.displayName)-Agg"
            subDeviceListForAggregate = outputUIDs.map { [kAudioSubDeviceUIDKey: $0] }
            logger.debug("Process mode: Aggregate subDeviceList from outputUIDs. Aggregate name: \(aggregateDeviceName)")
        }

        let descriptionForAggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: aggregateDeviceName,
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: mainSubdeviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: subDeviceListForAggregate,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapDescription.uuid.uuidString
                ]
            ]
        ]
        logger.debug("Aggregate device description prepared. Main sub-device UID: \(mainSubdeviceUID), Tap UUID: \(tapDescription.uuid.uuidString)")
        
        aggregateDeviceID = AudioObjectID.unknown
        do {
            logger.debug("Calling AudioHardwareCreateAggregateDevice...")
            let errAggDeviceCreation = AudioHardwareCreateAggregateDevice(descriptionForAggregate as CFDictionary, &aggregateDeviceID)
            if errAggDeviceCreation != noErr {
                logger.error("AudioHardwareCreateAggregateDevice failed with error: \(errAggDeviceCreation).")
                throw "Failed to create aggregate device: \(errAggDeviceCreation)"
            }
            logger.debug("Successfully created aggregate device #\(self.aggregateDeviceID, privacy: .public)")
        } catch {
            logger.error("EXCEPTION during AudioHardwareCreateAggregateDevice block: \(error)")
            throw error // Propagate error
        }

        do {
            logger.debug("Attempting to read audio tap stream basic description for tapID #\(tapID)...")
            self.tapStreamDescription = try tapID.readAudioTapStreamBasicDescription()
            logger.debug("Successfully read tap stream description: \(String(describing: self.tapStreamDescription))")
        } catch {
            logger.error("Failed to read audio tap stream basic description for tapID #\(tapID): \(error)")
            throw error // Propagate error
        }
    }

    func run(on queue: DispatchQueue, ioBlock: @escaping AudioDeviceIOBlock, invalidationHandler: @escaping InvalidationHandler) throws {
        guard activated else {
            throw NSError(domain: "ProcessTap", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "\(#function) called with inactive tap"])
        }
        guard self.invalidationHandler == nil else {
            throw NSError(domain: "ProcessTap", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "\(#function) called with tap already running"])
        }

        errorMessage = nil
        logger.debug("Run tap!")
        self.invalidationHandler = invalidationHandler

        let monitoredIOBlock: AudioDeviceIOBlock = { [weak self] inNow, inInputData, inInputTime, outOutputData, inOutputTime in
            self?.recordIOCallback()
            ioBlock(inNow, inInputData, inInputTime, outOutputData, inOutputTime)
        }

        var err = AudioDeviceCreateIOProcIDWithBlock(
            &deviceProcID,
            aggregateDeviceID,
            queue,
            monitoredIOBlock
        )
        guard err == noErr else { throw "Failed to create device I/O proc: \(err)" }

        err = AudioDeviceStart(aggregateDeviceID, deviceProcID)
        guard err == noErr else { throw "Failed to start audio device: \(err)" }
        startWatchdog()
    }

    deinit { invalidate() }

    /// Pure policy used by `prepare()` and unit tests. Every tap uses an explicit process
    /// allowlist. In particular, an empty system-audio list is rejected so it can never become
    /// a global tap through Core Audio API semantics or a future refactor.
    static func tapMixPolicy(for target: TapTarget) throws -> TapMixPolicy {
        switch target {
        case .singleProcess(let process):
            guard process.objectID.isValid else {
                throw ConfigurationError.noSupportedMeetingAudioProcess
            }
            return .includeProcesses([process.objectID])
        case .systemAudio(let processObjectIDs):
            let validIDs = Array(Set(processObjectIDs.filter(\.isValid))).sorted()
            guard !validIDs.isEmpty else {
                throw ConfigurationError.noSupportedMeetingAudioProcess
            }
            return .includeProcesses(validIDs)
        }
    }

    nonisolated static func watchdogShouldInvalidate(
        nowUptimeNanoseconds: UInt64,
        lastCallbackUptimeNanoseconds: UInt64,
        timeoutNanoseconds: UInt64,
        hasAnyTargetProcess: Bool
    ) -> Bool {
        guard hasAnyTargetProcess else { return true }
        guard nowUptimeNanoseconds >= lastCallbackUptimeNanoseconds else { return false }
        return nowUptimeNanoseconds - lastCallbackUptimeNanoseconds > timeoutNanoseconds
    }

    private func recordIOCallback() {
        watchdogLock.lock()
        if watchdogTimer != nil {
            lastIOCallbackUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
        }
        watchdogLock.unlock()
    }

    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: watchdogQueue)
        watchdogLock.lock()
        watchdogTimer?.cancel()
        watchdogTimer = timer
        lastIOCallbackUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
        watchdogLock.unlock()

        timer.schedule(
            deadline: .now() + .seconds(8),
            repeating: .seconds(2),
            leeway: .milliseconds(500)
        )
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.watchdogLock.lock()
            let isCurrentTimer = self.watchdogTimer === timer
            let lastCallback = self.lastIOCallbackUptimeNanoseconds
            self.watchdogLock.unlock()
            guard isCurrentTimer else { return }

            let hasTargetProcess: Bool
            do {
                let current = Set(try AudioObjectID.readProcessList())
                hasTargetProcess = !current.isDisjoint(with: Set(self.targetProcessObjectIDs))
            } catch {
                // A transient process-list read failure is not proof that capture died;
                // the callback heartbeat still provides an independent failure signal.
                hasTargetProcess = true
            }
            let shouldInvalidate = Self.watchdogShouldInvalidate(
                nowUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds,
                lastCallbackUptimeNanoseconds: lastCallback,
                timeoutNanoseconds: 5_000_000_000,
                hasAnyTargetProcess: hasTargetProcess
            )
            if shouldInvalidate {
                self.invalidate(reason: .unexpected)
            }
        }
        timer.resume()
    }

    private func stopWatchdog() {
        watchdogLock.lock()
        let timer = watchdogTimer
        watchdogTimer = nil
        watchdogLock.unlock()
        timer?.setEventHandler {}
        timer?.cancel()
    }

    private var targetProcessObjectIDs: [AudioObjectID] {
        switch target {
        case .singleProcess(let process):
            return process.objectID.isValid ? [process.objectID] : []
        case .systemAudio(let processObjectIDs):
            return processObjectIDs.filter(\.isValid)
        }
    }

}

private extension AudioDeviceID {
    func getTotalOutputChannelCount() throws -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        var err = AudioObjectGetPropertyDataSize(self, &address, 0, nil, &dataSize)
        if err == kAudioHardwareUnknownPropertyError || dataSize == 0 {
            return 0
        }
        guard err == noErr else {
            throw "Error reading data size for output stream configuration: \(err)"
        }
        let bufferListPtr = UnsafeMutableRawPointer.allocate(byteCount: Int(dataSize), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { bufferListPtr.deallocate() }
        err = AudioObjectGetPropertyData(self, &address, 0, nil, &dataSize, bufferListPtr)
        guard err == noErr else {
            throw "Error reading output stream configuration: \(err)"
        }
        let audioBufferList = bufferListPtr.assumingMemoryBound(to: AudioBufferList.self)
        var totalOutputChannels: UInt32 = 0
        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        for i in 0..<Int(buffers.count) {
            totalOutputChannels += buffers[i].mNumberChannels
        }
        return totalOutputChannels
    }
}

@Observable
final class ProcessTapRecorder {

    let fileURL: URL
    let tapDisplayName: String
    let icon: NSImage

    private(set) var currentAudioLevel: Float = 0.0

    private let queue = DispatchQueue(label: "ProcessTapRecorder", qos: .userInitiated)
    private let logger: Logger

    @ObservationIgnored
    private weak var _tap: ProcessTap?

    private(set) var isRecording = false

    init(fileURL: URL, tap: ProcessTap) {
        self.tapDisplayName = tap.displayName
        self.fileURL = fileURL
        self._tap = tap
        self.logger = Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "io.github.lingeringautumn.meetmemo.interview",
            category: "\(String(describing: ProcessTapRecorder.self))(\(fileURL.lastPathComponent))"
        )
        
        self.icon = tap.target.iconImage
    }

    private var tap: ProcessTap {
        get throws {
            guard let _tap else { throw "Process tap unavailable" }
            return _tap
        }
    }

    @ObservationIgnored
    private var currentFile: AVAudioFile?

    @MainActor
    func start() throws {
        logger.debug(#function)
        
        guard !isRecording else {
            logger.warning("\(#function, privacy: .public) while already recording")
            return
        }

        self.isRecording = true

        let tap = try tap

        if !tap.activated {
            tap.activate()
            if let errorMessage = tap.errorMessage {
                logger.error("Tap activation error: \(errorMessage)")
                self.isRecording = false
                throw errorMessage
            }
        }

        guard var streamDescription = tap.tapStreamDescription else {
            logger.error("Tap stream description not available.")
            self.isRecording = false
            throw "Tap stream description not available."
        }

        guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
            logger.error("Failed to create AVAudioFormat from stream description.")
            self.isRecording = false
            throw "Failed to create AVAudioFormat."
        }

        logger.info("Using audio format: \(format, privacy: .public)")

        let settings: [String: Any] = [
            AVFormatIDKey: streamDescription.mFormatID,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount
        ]
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
        
        do {
            let file = try AVAudioFile(forWriting: fileURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: format.isInterleaved)
            self.currentFile = file
        } catch {
            logger.error("Failed to create AVAudioFile for writing: \(error, privacy: .public)")
            self.isRecording = false
            throw error
        }

        #if DEBUG
        let systemModeActive: Bool
        if case .systemAudio = tap.target {
            systemModeActive = true
        } else {
            systemModeActive = false
        }
        logger.debug("About to call tap.run. System mode: \(systemModeActive, privacy: .public)")
        #endif

        try tap.run(on: queue) { [weak self] inNow, inInputData, inInputTime, outOutputData, inOutputTime in
            guard let self else { return }
            var localAudioLevel: Float = 0.0
            
            do {
                guard let currentFile = self.currentFile else {
                    DispatchQueue.main.async { if self.currentAudioLevel != 0.0 { self.currentAudioLevel = 0.0 } }
                    return
                }
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inInputData, deallocator: nil) else {
                    self.logger.warning("Failed to create PCM buffer")
                    DispatchQueue.main.async { if self.currentAudioLevel != 0.0 { self.currentAudioLevel = 0.0 } }
                    return
                }
                
                var rms: Float = 0.0
                if let floatChannelData = buffer.floatChannelData, buffer.frameLength > 0 {
                    let channelData = floatChannelData[0]
                    let frameLength = Int(buffer.frameLength)
                    var sumOfSquares: Float = 0.0
                    for i in 0..<frameLength {
                        let sample = channelData[i]
                        sumOfSquares += sample * sample
                    }
                    rms = sqrt(sumOfSquares / Float(frameLength))
                    
                    #if DEBUG
                    if case .systemAudio = (try? self.tap)?.target {
                        if rms == 0.0 {
                            self.logger.warning("System mode audio buffer is silent")
                        }
                    }
                    #endif
                }
                
                localAudioLevel = min(max(rms * 2.0, 0.0), 1.0)

                if buffer.frameLength == 0 {
                    self.logger.warning("Received zero audio frames")
                }

                try currentFile.write(from: buffer)

            } catch {
                self.logger.error("Buffer write error: \(error, privacy: .public)")
                localAudioLevel = 0.0
            }
            
            DispatchQueue.main.async {
                self.currentAudioLevel = localAudioLevel
            }

        } invalidationHandler: { [weak self] tap in
            guard let self else { return }
            DispatchQueue.main.async {
                self.handleInvalidation()
            }
        }
        logger.debug("Recording started")
    }

    @MainActor
    func stop() {
        logger.debug(#function)
        guard isRecording else { return }
        
        self.currentAudioLevel = 0.0
        self.isRecording = false

        guard let tapToInvalidate = try? self.tap else {
            logger.warning("Tap unavailable during stop. Cleaning up recorder state.")
            self.currentFile = nil
            return
        }
        
        tapToInvalidate.invalidate()
            
        self.currentFile = nil
    }

    @MainActor
    private func handleInvalidation() {
        logger.debug("Handling tap invalidation in recorder.")
        if isRecording {
            logger.info("Tap invalidated while recording. Stopping recording.")
            self.currentFile = nil
            self.isRecording = false
            self.currentAudioLevel = 0.0
        }
    }
} 
