import AudioToolbox
import Foundation

/// A single monotonic clock shared by microphone and system-audio capture.
///
/// Core Audio host times and `AudioGetCurrentHostTime()` use the same clock. Mapping both
/// capture callbacks onto this clock gives every converted packet an absolute sample position
/// instead of relying on callback arrival order or wall-clock `Date` values.
struct MonotonicAudioTimeline: Sendable {
    let sampleRate: Int
    let originHostTime: UInt64
    let hostClockFrequency: Double

    init(
        sampleRate: Int = 16_000,
        originHostTime: UInt64 = AudioGetCurrentHostTime(),
        hostClockFrequency: Double = AudioGetHostClockFrequency()
    ) {
        self.sampleRate = sampleRate
        self.originHostTime = originHostTime
        self.hostClockFrequency = hostClockFrequency
    }

    func samplePosition(forHostTime hostTime: UInt64) -> Int64 {
        guard sampleRate > 0,
              hostClockFrequency.isFinite,
              hostClockFrequency > 0,
              hostTime > originHostTime else {
            return 0
        }

        let elapsedTicks = hostTime - originHostTime
        let samples = Double(elapsedTicks) * Double(sampleRate) / hostClockFrequency
        guard samples.isFinite, samples > 0 else { return 0 }
        guard samples < Double(Int64.max) else { return Int64.max }
        return Int64(samples.rounded(.down))
    }

    func currentSamplePosition() -> Int64 {
        samplePosition(forHostTime: AudioGetCurrentHostTime())
    }

    /// Resolves the first frame of a capture callback. Invalid or implausibly future host times
    /// fall back to callback time minus the buffer duration, rather than shifting the audio one
    /// whole buffer late or allocating an unbounded silence gap.
    func captureStartSamplePosition(
        hostTime: UInt64?,
        frameCount: Int,
        sourceSampleRate: Double,
        callbackHostTime: UInt64 = AudioGetCurrentHostTime()
    ) -> Int64 {
        let maximumFutureTicks: UInt64
        if hostClockFrequency.isFinite,
           hostClockFrequency > 0,
           hostClockFrequency < Double(UInt64.max) {
            maximumFutureTicks = UInt64(hostClockFrequency.rounded())
        } else {
            maximumFutureTicks = 0
        }
        let (latestPlausibleHostTime, futureOverflow) = callbackHostTime.addingReportingOverflow(maximumFutureTicks)
        if let hostTime,
           hostTime >= originHostTime,
           hostTime <= (futureOverflow ? UInt64.max : latestPlausibleHostTime) {
            return samplePosition(forHostTime: hostTime)
        }

        let durationSamples: Int64
        if frameCount > 0, sourceSampleRate.isFinite, sourceSampleRate > 0 {
            let converted = Double(frameCount) * Double(sampleRate) / sourceSampleRate
            if !converted.isFinite || converted >= Double(Int64.max) {
                durationSamples = Int64.max
            } else {
                durationSamples = Int64(max(0, converted.rounded()))
            }
        } else {
            durationSamples = 0
        }
        return max(0, samplePosition(forHostTime: callbackHostTime) - durationSamples)
    }
}

struct RecordingArtifact: Hashable, Sendable {
    let meetingID: UUID
    let sessionID: UUID
    /// Wall-clock time at which this recording session actually started. This is
    /// intentionally not the meeting creation date: a meeting may be resumed days later.
    let recordingStartedAt: Date
    /// Canonical post-meeting input: stereo, channel 0 = mic/candidate, channel 1 = system/interviewer.
    let fileURL: URL
    let micFileURL: URL
    let systemFileURL: URL
    let micRawFileURL: URL
    let systemRawFileURL: URL
    let manifestURL: URL
    let duration: TimeInterval
    let sampleRate: Int
    let channelCount: Int
    /// Position of this recording session on the persisted meeting transcript timeline.
    let timelineBaseOffsetMilliseconds: Int

    var stereoFileURL: URL { fileURL }

    /// Origin used by engines that return offsets on the complete meeting timeline.
    /// Adding `timelineBaseOffsetMilliseconds` to this value yields the real start
    /// time of this recording session.
    var transcriptTimelineOrigin: Date {
        recordingStartedAt.addingTimeInterval(
            -Double(max(0, timelineBaseOffsetMilliseconds)) / 1_000
        )
    }

    func wallClockTimestamp(forMeetingTimelineMilliseconds value: Int?) -> Date {
        guard let value else { return recordingStartedAt }
        let base = max(0, timelineBaseOffsetMilliseconds)
        guard value > base else { return recordingStartedAt }
        let (relative, overflow) = value.subtractingReportingOverflow(base)
        guard !overflow else { return recordingStartedAt }
        return recordingStartedAt.addingTimeInterval(Double(relative) / 1_000)
    }

    var timelineEndOffsetMilliseconds: Int {
        let base = max(0, timelineBaseOffsetMilliseconds)
        guard duration.isFinite, duration > 0 else { return base }
        let millisecondsValue = duration * 1_000
        guard millisecondsValue.isFinite,
              millisecondsValue < Double(Int.max) else { return Int.max }
        // This is an exclusive upper bound for the retained audio. Round up so
        // a final fractional millisecond is never omitted from replacement or
        // provenance ranges, matching MeetingRecordingStore's frame-based math.
        let milliseconds = Int(millisecondsValue.rounded(.up))
        let (end, overflow) = base.addingReportingOverflow(milliseconds)
        return overflow ? Int.max : end
    }
}

enum SynchronizedRecordingStatus: String, Codable, Sendable {
    case recording
    case interrupted
    case completed
    case exportFailed
}

struct SynchronizedRecordingTrackManifest: Codable, Hashable, Sendable {
    let source: AudioSource
    let role: String
    let channelIndex: Int
    let rawFileName: String
    let monoWAVFileName: String
    var frameCount: Int64
    var insertedSilenceFrames: Int64
    var trimmedOverlapFrames: Int64
}

struct SynchronizedRecordingManifest: Codable, Hashable, Sendable {
    static let currentVersion = 1

    var version: Int
    let meetingID: UUID
    let sessionID: UUID
    let createdAt: Date
    var finalizedAt: Date?
    var status: SynchronizedRecordingStatus
    let sampleRate: Int
    let sampleFormat: String
    /// The start of this session relative to the complete meeting timeline. A retranscription
    /// must add this offset and replace only this session's range.
    let timelineBaseOffsetMilliseconds: Int
    let interleavedWAVFileName: String
    var durationFrames: Int64
    var tracks: [SynchronizedRecordingTrackManifest]
    var lastError: String?
    /// Set only after both mono tracks and the canonical stereo WAV have been
    /// finalized successfully. Its presence is a durable hand-off marker for the
    /// post-recording recognizer; legacy manifests decode it as nil and therefore
    /// are never mistaken for interrupted new work.
    var accurateTranscriptionRequestedAt: Date? = nil
}

enum SynchronizedRecordingError: LocalizedError {
    case invalidSampleRate(Int)
    case invalidPCMByteCount(Int)
    case recordingAlreadyClosed
    case missingTrack(AudioSource)
    case wavTooLarge(Int64)

    var errorDescription: String? {
        switch self {
        case .invalidSampleRate(let rate):
            return "Invalid recording sample rate: \(rate)"
        case .invalidPCMByteCount(let count):
            return "Int16 PCM payload has an odd byte count: \(count)"
        case .recordingAlreadyClosed:
            return "The synchronized recording has already been closed."
        case .missingTrack(let source):
            return "The raw \(source.rawValue) recording track is missing."
        case .wavTooLarge(let frames):
            return "The stereo WAV would exceed the RIFF size limit (\(frames) frames)."
        }
    }
}

enum MeetingRecordingStoreError: LocalizedError {
    case activeRecordingSession(UUID)
    case unreadableManifest(URL, Error)
    case invalidManifest(URL)

    var errorDescription: String? {
        switch self {
        case .activeRecordingSession:
            return "A previous recording session is still being preserved. Wait for it to finish before recording again."
        case .unreadableManifest(let url, let error):
            return "Could not read the retained recording manifest at \(url.path): \(error.localizedDescription)"
        case .invalidManifest(let url):
            return "The retained recording manifest at \(url.path) is invalid."
        }
    }
}

/// The recorder and the meeting-timeline position atomically reserved for it.
/// Keeping these values together prevents callers from accidentally constructing
/// the recorder with a stale offset after inspecting the artifact store.
struct SynchronizedRecordingReservation {
    let recorder: SynchronizedDualTrackRecorder
    let timelineBaseOffsetMilliseconds: Int
}

/// Prevents startup recovery from claiming a session that this process is still writing.
/// The registry is intentionally process-local: after a crash it is empty, so genuinely
/// interrupted sessions remain eligible for recovery on the next launch.
private final class ActiveRecordingSessionRegistry: @unchecked Sendable {
    static let shared = ActiveRecordingSessionRegistry()

    private let lock = NSLock()
    private var sessionIDs = Set<UUID>()

    func register(_ sessionID: UUID) {
        _ = lock.withLock { sessionIDs.insert(sessionID) }
    }

    func unregister(_ sessionID: UUID) {
        _ = lock.withLock { sessionIDs.remove(sessionID) }
    }

    func contains(_ sessionID: UUID) -> Bool {
        lock.withLock { sessionIDs.contains(sessionID) }
    }
}

/// Incrementally persists two source-aligned Int16 tracks and exports a deterministic stereo
/// WAV at stop. Raw tracks are never deleted, including after a successful export, so a failed
/// export or interrupted process always retains the original captured samples.
final class SynchronizedDualTrackRecorder: @unchecked Sendable {
    static let manifestFileName = "manifest.json"
    static let wavFileName = "meeting-stereo.wav"
    static let candidateRawFileName = "candidate-mic.s16le.pcm"
    static let interviewerRawFileName = "interviewer-system.s16le.pcm"
    static let candidateWAVFileName = "candidate-mic.wav"
    static let interviewerWAVFileName = "interviewer-system.wav"

    private struct TrackState {
        let source: AudioSource
        let role: String
        let channelIndex: Int
        let rawFileName: String
        let monoWAVFileName: String
        let fileHandle: FileHandle
        var frameCount: Int64 = 0
        var insertedSilenceFrames: Int64 = 0
        var trimmedOverlapFrames: Int64 = 0
        var unsynchronizedFrames: Int64 = 0
    }

    let meetingID: UUID
    let sessionID: UUID
    let directoryURL: URL
    let manifestURL: URL
    let timeline: MonotonicAudioTimeline

    private let sampleRate: Int
    private let queue: DispatchQueue
    private var manifest: SynchronizedRecordingManifest
    private var tracks: [AudioSource: TrackState]
    private var isClosed = false
    private var firstWriteError: Error?

    init(
        meetingID: UUID,
        sessionID: UUID = UUID(),
        rootDirectory: URL = MeetingRecordingStore.defaultRootDirectory,
        timeline: MonotonicAudioTimeline = MonotonicAudioTimeline(),
        recordingStartedAt: Date = Date(),
        timelineBaseOffsetMilliseconds: Int = 0
    ) throws {
        guard timeline.sampleRate > 0 else {
            throw SynchronizedRecordingError.invalidSampleRate(timeline.sampleRate)
        }

        let activeRegistry = ActiveRecordingSessionRegistry.shared
        activeRegistry.register(sessionID)
        var didInitialize = false
        defer {
            if !didInitialize {
                activeRegistry.unregister(sessionID)
            }
        }

        self.meetingID = meetingID
        self.sessionID = sessionID
        self.timeline = timeline
        self.sampleRate = timeline.sampleRate
        self.directoryURL = rootDirectory
            .appendingPathComponent(meetingID.uuidString, isDirectory: true)
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
        self.manifestURL = directoryURL.appendingPathComponent(Self.manifestFileName)
        self.queue = DispatchQueue(
            label: "io.meetmemo.recording.\(sessionID.uuidString)",
            qos: .userInitiated
        )

        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )

        let candidateURL = directoryURL.appendingPathComponent(Self.candidateRawFileName)
        let interviewerURL = directoryURL.appendingPathComponent(Self.interviewerRawFileName)
        guard FileManager.default.createFile(atPath: candidateURL.path, contents: nil),
              FileManager.default.createFile(atPath: interviewerURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let candidateHandle = try FileHandle(forWritingTo: candidateURL)
        let interviewerHandle = try FileHandle(forWritingTo: interviewerURL)
        let initialTracks = [
            SynchronizedRecordingTrackManifest(
                source: .mic,
                role: "candidate",
                channelIndex: 0,
                rawFileName: Self.candidateRawFileName,
                monoWAVFileName: Self.candidateWAVFileName,
                frameCount: 0,
                insertedSilenceFrames: 0,
                trimmedOverlapFrames: 0
            ),
            SynchronizedRecordingTrackManifest(
                source: .system,
                role: "interviewer",
                channelIndex: 1,
                rawFileName: Self.interviewerRawFileName,
                monoWAVFileName: Self.interviewerWAVFileName,
                frameCount: 0,
                insertedSilenceFrames: 0,
                trimmedOverlapFrames: 0
            ),
        ]

        self.manifest = SynchronizedRecordingManifest(
            version: SynchronizedRecordingManifest.currentVersion,
            meetingID: meetingID,
            sessionID: sessionID,
            // `recordingStartedAt` is evaluated alongside the default monotonic
            // timeline before directory/file I/O begins. Keeping the pair together
            // avoids shifting every wall-clock transcript timestamp by setup latency.
            createdAt: recordingStartedAt,
            finalizedAt: nil,
            status: .recording,
            sampleRate: timeline.sampleRate,
            sampleFormat: "signed-int16-little-endian-mono",
            timelineBaseOffsetMilliseconds: max(0, timelineBaseOffsetMilliseconds),
            interleavedWAVFileName: Self.wavFileName,
            durationFrames: 0,
            tracks: initialTracks,
            lastError: nil
        )
        self.tracks = [
            .mic: TrackState(
                source: .mic,
                role: "candidate",
                channelIndex: 0,
                rawFileName: Self.candidateRawFileName,
                monoWAVFileName: Self.candidateWAVFileName,
                fileHandle: candidateHandle
            ),
            .system: TrackState(
                source: .system,
                role: "interviewer",
                channelIndex: 1,
                rawFileName: Self.interviewerRawFileName,
                monoWAVFileName: Self.interviewerWAVFileName,
                fileHandle: interviewerHandle
            ),
        ]

        do {
            try persistManifest()
            didInitialize = true
        } catch {
            try? candidateHandle.close()
            try? interviewerHandle.close()
            throw error
        }
    }

    func append(_ pcmData: Data, source: AudioSource, atSamplePosition samplePosition: Int64) {
        guard !pcmData.isEmpty else { return }
        let immutableData = pcmData
        queue.async { [self] in
            guard !isClosed else { return }
            do {
                try appendOnQueue(
                    immutableData,
                    source: source,
                    atSamplePosition: max(0, samplePosition)
                )
            } catch {
                rememberWriteError(error)
            }
        }
    }

    func finish(atSamplePosition samplePosition: Int64? = nil) async -> Result<RecordingArtifact, Error> {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                do {
                    let artifact = try finishOnQueue(atSamplePosition: samplePosition)
                    continuation.resume(returning: .success(artifact))
                } catch {
                    continuation.resume(returning: .failure(error))
                }
            }
        }
    }

    /// Closes recoverable raw files without attempting WAV export. Used for hard-reset paths;
    /// the next app launch can recover this manifest through `MeetingRecordingStore`.
    func preserveForRecovery(reason: String) async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard !isClosed else {
                    continuation.resume()
                    return
                }
                closeTrackHandles()
                isClosed = true
                refreshManifestFromTrackState()
                manifest.status = .interrupted
                manifest.lastError = reason
                try? persistManifest()
                ActiveRecordingSessionRegistry.shared.unregister(sessionID)
                continuation.resume()
            }
        }
    }

    private func appendOnQueue(
        _ pcmData: Data,
        source: AudioSource,
        atSamplePosition samplePosition: Int64
    ) throws {
        dispatchPrecondition(condition: .onQueue(queue))
        guard pcmData.count.isMultiple(of: MemoryLayout<Int16>.size) else {
            throw SynchronizedRecordingError.invalidPCMByteCount(pcmData.count)
        }
        guard var track = tracks[source] else {
            throw SynchronizedRecordingError.missingTrack(source)
        }

        let incomingFrames = Int64(pcmData.count / MemoryLayout<Int16>.size)
        guard incomingFrames > 0 else { return }

        if samplePosition > track.frameCount {
            let gapFrames = samplePosition - track.frameCount
            try Self.writeSilence(frameCount: gapFrames, to: track.fileHandle)
            track.frameCount += gapFrames
            track.insertedSilenceFrames += gapFrames
            track.unsynchronizedFrames += gapFrames
        }

        let overlapFrames = max(0, track.frameCount - samplePosition)
        let framesToTrim = min(overlapFrames, incomingFrames)
        track.trimmedOverlapFrames += framesToTrim

        if framesToTrim < incomingFrames {
            let byteOffset = Int(framesToTrim) * MemoryLayout<Int16>.size
            let remaining = pcmData.subdata(in: byteOffset..<pcmData.count)
            try track.fileHandle.write(contentsOf: remaining)
            let writtenFrames = incomingFrames - framesToTrim
            track.frameCount += writtenFrames
            track.unsynchronizedFrames += writtenFrames
        }

        if track.unsynchronizedFrames >= Int64(sampleRate) {
            try track.fileHandle.synchronize()
            track.unsynchronizedFrames = 0
            tracks[source] = track
            refreshManifestFromTrackState()
            try persistManifest()
        } else {
            tracks[source] = track
        }
    }

    private func finishOnQueue(atSamplePosition samplePosition: Int64?) throws -> RecordingArtifact {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isClosed else { throw SynchronizedRecordingError.recordingAlreadyClosed }
        defer { ActiveRecordingSessionRegistry.shared.unregister(sessionID) }

        let requestedEnd = max(0, samplePosition ?? timeline.currentSamplePosition())
        let naturalEnd = tracks.values.map(\.frameCount).max() ?? 0
        let commonEnd = max(requestedEnd, naturalEnd)

        do {
            for source in AudioSource.allCases {
                guard var track = tracks[source] else {
                    throw SynchronizedRecordingError.missingTrack(source)
                }
                if track.frameCount < commonEnd {
                    let gapFrames = commonEnd - track.frameCount
                    try Self.writeSilence(frameCount: gapFrames, to: track.fileHandle)
                    track.frameCount += gapFrames
                    track.insertedSilenceFrames += gapFrames
                }
                try track.fileHandle.synchronize()
                tracks[source] = track
            }
        } catch {
            rememberWriteError(error)
            closeTrackHandles()
            isClosed = true
            refreshManifestFromTrackState()
            manifest.status = .exportFailed
            manifest.finalizedAt = Date()
            manifest.lastError = error.localizedDescription
            try? persistManifest()
            throw error
        }

        closeTrackHandles()
        isClosed = true
        refreshManifestFromTrackState()
        manifest.durationFrames = commonEnd

        if let firstWriteError {
            manifest.status = .exportFailed
            manifest.finalizedAt = Date()
            manifest.lastError = firstWriteError.localizedDescription
            try? persistManifest()
            throw firstWriteError
        }

        do {
            let micWAVURL = try PCM16WAVExporter.exportMonoTrack(
                directoryURL: directoryURL,
                track: manifest.tracks.first(where: { $0.source == .mic })!,
                sampleRate: sampleRate,
                frameCount: commonEnd
            )
            let systemWAVURL = try PCM16WAVExporter.exportMonoTrack(
                directoryURL: directoryURL,
                track: manifest.tracks.first(where: { $0.source == .system })!,
                sampleRate: sampleRate,
                frameCount: commonEnd
            )
            let wavURL = try StereoPCM16WAVExporter.export(
                directoryURL: directoryURL,
                manifest: manifest
            )
            manifest.status = .completed
            let finalizedAt = Date()
            manifest.finalizedAt = finalizedAt
            manifest.lastError = nil
            manifest.accurateTranscriptionRequestedAt = finalizedAt
            try persistManifest()
            return RecordingArtifact(
                meetingID: meetingID,
                sessionID: sessionID,
                recordingStartedAt: manifest.createdAt,
                fileURL: wavURL,
                micFileURL: micWAVURL,
                systemFileURL: systemWAVURL,
                micRawFileURL: directoryURL.appendingPathComponent(Self.candidateRawFileName),
                systemRawFileURL: directoryURL.appendingPathComponent(Self.interviewerRawFileName),
                manifestURL: manifestURL,
                duration: TimeInterval(commonEnd) / TimeInterval(sampleRate),
                sampleRate: sampleRate,
                channelCount: 2,
                timelineBaseOffsetMilliseconds: manifest.timelineBaseOffsetMilliseconds
            )
        } catch {
            manifest.status = .exportFailed
            manifest.finalizedAt = Date()
            manifest.lastError = error.localizedDescription
            try? persistManifest()
            throw error
        }
    }

    private func closeTrackHandles() {
        for track in tracks.values {
            try? track.fileHandle.synchronize()
            try? track.fileHandle.close()
        }
    }

    private func rememberWriteError(_ error: Error) {
        if firstWriteError == nil {
            firstWriteError = error
            manifest.lastError = error.localizedDescription
            refreshManifestFromTrackState()
            try? persistManifest()
        }
    }

    private func refreshManifestFromTrackState() {
        manifest.tracks = tracks.values
            .map { track in
                SynchronizedRecordingTrackManifest(
                    source: track.source,
                    role: track.role,
                    channelIndex: track.channelIndex,
                    rawFileName: track.rawFileName,
                    monoWAVFileName: track.monoWAVFileName,
                    frameCount: track.frameCount,
                    insertedSilenceFrames: track.insertedSilenceFrames,
                    trimmedOverlapFrames: track.trimmedOverlapFrames
                )
            }
            .sorted { $0.channelIndex < $1.channelIndex }
        manifest.durationFrames = manifest.tracks.map(\.frameCount).max() ?? 0
    }

    private func persistManifest() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
    }

    private static func writeSilence(frameCount: Int64, to fileHandle: FileHandle) throws {
        guard frameCount > 0 else { return }
        let framesPerChunk: Int64 = 32_768
        let zeroChunk = Data(repeating: 0, count: Int(framesPerChunk) * MemoryLayout<Int16>.size)
        var remaining = frameCount
        while remaining > 0 {
            let frames = min(remaining, framesPerChunk)
            if frames == framesPerChunk {
                try fileHandle.write(contentsOf: zeroChunk)
            } else {
                try fileHandle.write(contentsOf: Data(
                    repeating: 0,
                    count: Int(frames) * MemoryLayout<Int16>.size
                ))
            }
            remaining -= frames
        }
    }
}

enum StereoPCM16WAVExporter {
    static func export(
        directoryURL: URL,
        manifest: SynchronizedRecordingManifest
    ) throws -> URL {
        guard manifest.sampleRate > 0 else {
            throw SynchronizedRecordingError.invalidSampleRate(manifest.sampleRate)
        }
        guard let candidate = manifest.tracks.first(where: { $0.channelIndex == 0 }),
              let interviewer = manifest.tracks.first(where: { $0.channelIndex == 1 }) else {
            throw SynchronizedRecordingError.missingTrack(.mic)
        }

        let leftURL = directoryURL.appendingPathComponent(candidate.rawFileName)
        let rightURL = directoryURL.appendingPathComponent(interviewer.rawFileName)
        guard FileManager.default.fileExists(atPath: leftURL.path) else {
            throw SynchronizedRecordingError.missingTrack(candidate.source)
        }
        guard FileManager.default.fileExists(atPath: rightURL.path) else {
            throw SynchronizedRecordingError.missingTrack(interviewer.source)
        }

        let leftFrames = try rawFrameCount(at: leftURL)
        let rightFrames = try rawFrameCount(at: rightURL)
        let frameCount = max(manifest.durationFrames, max(leftFrames, rightFrames))
        let bytesPerFrame: Int64 = 4
        let maximumDataByteCount = Int64(UInt32.max) - 36
        guard frameCount >= 0,
              frameCount <= maximumDataByteCount / bytesPerFrame else {
            throw SynchronizedRecordingError.wavTooLarge(frameCount)
        }

        let finalURL = directoryURL.appendingPathComponent(manifest.interleavedWAVFileName)
        let partialURL = directoryURL.appendingPathComponent(
            "\(manifest.interleavedWAVFileName).\(UUID().uuidString).partial"
        )
        guard FileManager.default.createFile(atPath: partialURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let output = try FileHandle(forWritingTo: partialURL)
        let left = try FileHandle(forReadingFrom: leftURL)
        let right = try FileHandle(forReadingFrom: rightURL)
        do {
            try output.write(contentsOf: wavHeader(
                sampleRate: manifest.sampleRate,
                frameCount: frameCount
            ))

            let chunkFrames = 16_384
            var remaining = frameCount
            while remaining > 0 {
                let requestedFrames = Int(min(remaining, Int64(chunkFrames)))
                let leftData = try readUpToExactly(left, byteCount: requestedFrames * 2)
                let rightData = try readUpToExactly(right, byteCount: requestedFrames * 2)
                let leftBytes = [UInt8](leftData)
                let rightBytes = [UInt8](rightData)
                var interleaved = Data(count: requestedFrames * 4)
                interleaved.withUnsafeMutableBytes { outputBytes in
                    guard let destination = outputBytes.bindMemory(to: UInt8.self).baseAddress else { return }
                    for frame in 0..<requestedFrames {
                        let sourceOffset = frame * 2
                        let destinationOffset = frame * 4
                        destination[destinationOffset] = sourceOffset < leftBytes.count ? leftBytes[sourceOffset] : 0
                        destination[destinationOffset + 1] = sourceOffset + 1 < leftBytes.count ? leftBytes[sourceOffset + 1] : 0
                        destination[destinationOffset + 2] = sourceOffset < rightBytes.count ? rightBytes[sourceOffset] : 0
                        destination[destinationOffset + 3] = sourceOffset + 1 < rightBytes.count ? rightBytes[sourceOffset + 1] : 0
                    }
                }
                try output.write(contentsOf: interleaved)
                remaining -= Int64(requestedFrames)
            }
            try output.synchronize()
            try output.close()
            try left.close()
            try right.close()

            if FileManager.default.fileExists(atPath: finalURL.path) {
                _ = try FileManager.default.replaceItemAt(finalURL, withItemAt: partialURL)
            } else {
                try FileManager.default.moveItem(at: partialURL, to: finalURL)
            }
            return finalURL
        } catch {
            try? output.close()
            try? left.close()
            try? right.close()
            // Deliberately keep the partial WAV and both source PCM files for diagnosis/retry.
            throw error
        }
    }

    static func rawFrameCount(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        let bytes = Int64(values.fileSize ?? 0)
        return max(0, bytes / Int64(MemoryLayout<Int16>.size))
    }

    static func wavHeader(sampleRate: Int, frameCount: Int64) throws -> Data {
        try PCM16WAVExporter.wavHeader(sampleRate: sampleRate, channelCount: 2, frameCount: frameCount)
    }
}

enum PCM16WAVExporter {
    static func exportMonoTrack(
        directoryURL: URL,
        track: SynchronizedRecordingTrackManifest,
        sampleRate: Int,
        frameCount: Int64
    ) throws -> URL {
        let rawURL = directoryURL.appendingPathComponent(track.rawFileName)
        guard FileManager.default.fileExists(atPath: rawURL.path) else {
            throw SynchronizedRecordingError.missingTrack(track.source)
        }

        let finalURL = directoryURL.appendingPathComponent(track.monoWAVFileName)
        let partialURL = directoryURL.appendingPathComponent(
            "\(track.monoWAVFileName).\(UUID().uuidString).partial"
        )
        guard FileManager.default.createFile(atPath: partialURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let input = try FileHandle(forReadingFrom: rawURL)
        let output = try FileHandle(forWritingTo: partialURL)
        do {
            try output.write(contentsOf: wavHeader(
                sampleRate: sampleRate,
                channelCount: 1,
                frameCount: frameCount
            ))
            var remainingBytes = frameCount * Int64(MemoryLayout<Int16>.size)
            while remainingBytes > 0 {
                let request = Int(min(remainingBytes, 64 * 1_024))
                let chunk = try readUpToExactly(input, byteCount: request)
                if chunk.isEmpty {
                    try output.write(contentsOf: Data(repeating: 0, count: request))
                } else {
                    try output.write(contentsOf: chunk)
                    if chunk.count < request {
                        try output.write(contentsOf: Data(repeating: 0, count: request - chunk.count))
                    }
                }
                remainingBytes -= Int64(request)
            }
            try output.synchronize()
            try input.close()
            try output.close()
            if FileManager.default.fileExists(atPath: finalURL.path) {
                _ = try FileManager.default.replaceItemAt(finalURL, withItemAt: partialURL)
            } else {
                try FileManager.default.moveItem(at: partialURL, to: finalURL)
            }
            return finalURL
        } catch {
            try? input.close()
            try? output.close()
            // Keep the partial file and headerless source PCM for a later recovery attempt.
            throw error
        }
    }

    static func wavHeader(sampleRate: Int, channelCount: Int, frameCount: Int64) throws -> Data {
        guard sampleRate > 0 else {
            throw SynchronizedRecordingError.invalidSampleRate(sampleRate)
        }
        guard channelCount > 0,
              channelCount <= Int(UInt16.max) / MemoryLayout<Int16>.size else {
            throw SynchronizedRecordingError.wavTooLarge(frameCount)
        }
        let bytesPerFrame = Int64(channelCount * MemoryLayout<Int16>.size)
        let maximumDataByteCount = Int64(UInt32.max) - 36
        guard frameCount >= 0,
              frameCount <= maximumDataByteCount / bytesPerFrame else {
            throw SynchronizedRecordingError.wavTooLarge(frameCount)
        }
        let dataByteCount = frameCount * bytesPerFrame
        let byteRate = Int64(sampleRate) * bytesPerFrame
        guard byteRate <= Int64(UInt32.max) else {
            throw SynchronizedRecordingError.wavTooLarge(frameCount)
        }

        var header = Data()
        header.append(contentsOf: Array("RIFF".utf8))
        appendLittleEndian(UInt32(36 + dataByteCount), to: &header)
        header.append(contentsOf: Array("WAVE".utf8))
        header.append(contentsOf: Array("fmt ".utf8))
        appendLittleEndian(UInt32(16), to: &header)
        appendLittleEndian(UInt16(1), to: &header)
        appendLittleEndian(UInt16(channelCount), to: &header)
        appendLittleEndian(UInt32(sampleRate), to: &header)
        appendLittleEndian(UInt32(byteRate), to: &header)
        appendLittleEndian(UInt16(channelCount * MemoryLayout<Int16>.size), to: &header)
        appendLittleEndian(UInt16(16), to: &header)
        header.append(contentsOf: Array("data".utf8))
        appendLittleEndian(UInt32(dataByteCount), to: &header)
        return header
    }

    private static func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndianValue = value.littleEndian
        withUnsafeBytes(of: &littleEndianValue) { data.append(contentsOf: $0) }
    }
}

private func readUpToExactly(_ handle: FileHandle, byteCount: Int) throws -> Data {
    guard byteCount > 0 else { return Data() }
    var result = Data()
    result.reserveCapacity(byteCount)
    while result.count < byteCount {
        let chunk = try handle.read(upToCount: byteCount - result.count) ?? Data()
        guard !chunk.isEmpty else { break }
        result.append(chunk)
    }
    return result
}

/// Persistent index/recovery facade. Callers that need a file for post-meeting processing can
/// query by meeting id without knowing the on-disk directory convention.
final class MeetingRecordingStore: @unchecked Sendable {
    static let defaultRootDirectory: URL = {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("MeetMemo", isDirectory: true)
        return base.appendingPathComponent("MeetingRecordings", isDirectory: true)
    }()

    static let shared = MeetingRecordingStore()

    let rootDirectory: URL
    private let lock = NSLock()

    init(rootDirectory: URL = defaultRootDirectory) {
        self.rootDirectory = rootDirectory
        try? FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
    }

    /// Atomically finds the greatest durable end of this meeting's timeline and
    /// creates the next recording manifest at that position. Unlike `latestArtifact`,
    /// this accounts for interrupted/export-failed sessions and for raw PCM that is
    /// newer than the last periodically persisted frame count.
    ///
    /// An active manifest for the same meeting is a hard stop. It can be the recorder
    /// currently being closed after an in-process startup failure; ignoring it would
    /// allow a continuation to overlap audio that has not finished reaching disk yet.
    func reserveRecorder(
        meetingID: UUID,
        sessionID: UUID,
        timeline: MonotonicAudioTimeline,
        recordingStartedAt: Date = Date(),
        minimumTimelineEndMilliseconds: Int
    ) throws -> SynchronizedRecordingReservation {
        try lock.withLock {
            let retainedEnd = try maximumRetainedTimelineEndLocked(for: meetingID)
            let timelineBase = max(
                max(0, minimumTimelineEndMilliseconds),
                retainedEnd
            )
            let recorder = try SynchronizedDualTrackRecorder(
                meetingID: meetingID,
                sessionID: sessionID,
                rootDirectory: rootDirectory,
                timeline: timeline,
                recordingStartedAt: recordingStartedAt,
                timelineBaseOffsetMilliseconds: timelineBase
            )
            return SynchronizedRecordingReservation(
                recorder: recorder,
                timelineBaseOffsetMilliseconds: timelineBase
            )
        }
    }

    /// Read-only form used by diagnostics and storage tests. Production recording
    /// startup uses `reserveRecorder` so the scan and new manifest creation cannot race.
    func maximumRetainedTimelineEnd(for meetingID: UUID) throws -> Int {
        try lock.withLock {
            try maximumRetainedTimelineEndLocked(for: meetingID)
        }
    }

    /// Removes every recording artifact owned by one meeting. The UUID-derived directory
    /// keeps deletion scoped to that meeting even when the store contains many sessions.
    func deleteRecordings(for meetingID: UUID) throws {
        try lock.withLock {
            let meetingDirectory = rootDirectory.appendingPathComponent(
                meetingID.uuidString,
                isDirectory: true
            )
            guard FileManager.default.fileExists(atPath: meetingDirectory.path) else { return }
            try FileManager.default.removeItem(at: meetingDirectory)
        }
    }

    func latestArtifact(for meetingID: UUID) -> RecordingArtifact? {
        lock.withLock {
            manifests(for: meetingID)
                .compactMap { manifestURL -> (Int, Date, RecordingArtifact)? in
                    guard let manifest = try? Self.loadManifest(at: manifestURL),
                          manifest.status == .completed else { return nil }
                    let directory = manifestURL.deletingLastPathComponent()
                    let wavURL = directory.appendingPathComponent(manifest.interleavedWAVFileName)
                    guard FileManager.default.fileExists(atPath: wavURL.path),
                          manifest.tracks.allSatisfy({ track in
                              FileManager.default.fileExists(
                                  atPath: directory.appendingPathComponent(track.monoWAVFileName).path
                              )
                          }) else { return nil }
                    guard let artifact = Self.artifact(
                        manifest: manifest,
                        manifestURL: manifestURL,
                        wavURL: wavURL
                    ) else { return nil }
                    return (
                        artifact.timelineEndOffsetMilliseconds,
                        manifest.createdAt,
                        artifact
                    )
                }
                .max(by: { lhs, rhs in
                    if lhs.0 == rhs.0 {
                        return lhs.1 < rhs.1
                    }
                    return lhs.0 < rhs.0
                })?
                .2
        }
    }

    /// Exact lookup used by a restored retry banner. Retrying by meeting alone is
    /// unsafe when a meeting has several continuation sessions: the newest artifact
    /// may already be complete while an older cloud job is the one that failed.
    func artifact(for meetingID: UUID, sessionID: UUID) -> RecordingArtifact? {
        lock.withLock {
            let manifestURL = rootDirectory
                .appendingPathComponent(meetingID.uuidString, isDirectory: true)
                .appendingPathComponent(sessionID.uuidString, isDirectory: true)
                .appendingPathComponent(SynchronizedDualTrackRecorder.manifestFileName)
            guard let manifest = try? Self.loadManifest(at: manifestURL),
                  manifest.meetingID == meetingID,
                  manifest.sessionID == sessionID,
                  manifest.status == .completed else {
                return nil
            }
            let directory = manifestURL.deletingLastPathComponent()
            let wavURL = directory.appendingPathComponent(manifest.interleavedWAVFileName)
            guard FileManager.default.fileExists(atPath: wavURL.path),
                  manifest.tracks.allSatisfy({ track in
                      FileManager.default.fileExists(
                          atPath: directory.appendingPathComponent(track.monoWAVFileName).path
                      )
                  }) else {
                return nil
            }
            return Self.artifact(
                manifest: manifest,
                manifestURL: manifestURL,
                wavURL: wavURL
            )
        }
    }

    /// Returns only artifacts produced by builds that wrote an explicit durable
    /// post-processing hand-off marker. Older completed recordings are deliberately
    /// excluded because the absence of a provenance receipt cannot tell us whether
    /// those legacy files were already refined successfully.
    func pendingAccurateTranscriptionArtifacts() -> [RecordingArtifact] {
        lock.withLock {
            allManifestURLs().compactMap { manifestURL in
                guard let manifest = try? Self.loadManifest(at: manifestURL),
                      manifest.status == .completed,
                      manifest.accurateTranscriptionRequestedAt != nil else {
                    return nil
                }
                let directory = manifestURL.deletingLastPathComponent()
                let wavURL = directory.appendingPathComponent(manifest.interleavedWAVFileName)
                guard FileManager.default.fileExists(atPath: wavURL.path),
                      manifest.tracks.allSatisfy({ track in
                          FileManager.default.fileExists(
                              atPath: directory.appendingPathComponent(track.monoWAVFileName).path
                          )
                      }) else {
                    return nil
                }
                return Self.artifact(
                    manifest: manifest,
                    manifestURL: manifestURL,
                    wavURL: wavURL
                )
            }
        }
    }

    @discardableResult
    func recoverIncompleteRecordings() -> [RecordingArtifact] {
        // Only snapshot directory membership under the store lock. WAV export can
        // be slow for a long interview and must not block unrelated artifact reads.
        // RecordingSessionManager gates creation of new sessions until this startup
        // pass finishes, while the active-session registry protects live writers.
        let manifestURLs = lock.withLock { allManifestURLs() }
        return manifestURLs.compactMap { manifestURL in
                guard var manifest = try? Self.loadManifest(at: manifestURL),
                      !ActiveRecordingSessionRegistry.shared.contains(manifest.sessionID),
                      Self.isValid(manifest: manifest),
                      manifest.status == .recording || manifest.status == .interrupted || manifest.status == .exportFailed else {
                    return nil
                }

                let directory = manifestURL.deletingLastPathComponent()
                do {
                    for index in manifest.tracks.indices {
                        let rawURL = directory.appendingPathComponent(manifest.tracks[index].rawFileName)
                        manifest.tracks[index].frameCount = try StereoPCM16WAVExporter.rawFrameCount(at: rawURL)
                    }
                    manifest.durationFrames = manifest.tracks.map(\.frameCount).max() ?? 0
                    for index in manifest.tracks.indices {
                        let missingFrames = manifest.durationFrames - manifest.tracks[index].frameCount
                        if missingFrames > 0 {
                            let rawURL = directory.appendingPathComponent(manifest.tracks[index].rawFileName)
                            let handle = try FileHandle(forWritingTo: rawURL)
                            try handle.seekToEnd()
                            try Self.writeRecoverySilence(frameCount: missingFrames, to: handle)
                            try handle.synchronize()
                            try handle.close()
                            manifest.tracks[index].frameCount = manifest.durationFrames
                            manifest.tracks[index].insertedSilenceFrames += missingFrames
                        }
                    }
                    let micTrack = manifest.tracks.first(where: { $0.source == .mic })
                    let systemTrack = manifest.tracks.first(where: { $0.source == .system })
                    guard let micTrack, let systemTrack else {
                        throw SynchronizedRecordingError.missingTrack(micTrack == nil ? .mic : .system)
                    }
                    _ = try PCM16WAVExporter.exportMonoTrack(
                        directoryURL: directory,
                        track: micTrack,
                        sampleRate: manifest.sampleRate,
                        frameCount: manifest.durationFrames
                    )
                    _ = try PCM16WAVExporter.exportMonoTrack(
                        directoryURL: directory,
                        track: systemTrack,
                        sampleRate: manifest.sampleRate,
                        frameCount: manifest.durationFrames
                    )
                    let wavURL = try StereoPCM16WAVExporter.export(
                        directoryURL: directory,
                        manifest: manifest
                    )
                    manifest.status = .completed
                    let finalizedAt = Date()
                    manifest.finalizedAt = finalizedAt
                    manifest.lastError = nil
                    manifest.accurateTranscriptionRequestedAt = finalizedAt
                    try Self.saveManifest(manifest, at: manifestURL)
                    return Self.artifact(manifest: manifest, manifestURL: manifestURL, wavURL: wavURL)
                } catch {
                    manifest.status = .exportFailed
                    manifest.finalizedAt = Date()
                    manifest.lastError = error.localizedDescription
                    try? Self.saveManifest(manifest, at: manifestURL)
                    return nil
                }
        }
    }

    private func manifests(for meetingID: UUID) -> [URL] {
        let meetingDirectory = rootDirectory.appendingPathComponent(meetingID.uuidString, isDirectory: true)
        guard let sessions = try? FileManager.default.contentsOfDirectory(
            at: meetingDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return sessions.map { $0.appendingPathComponent(SynchronizedDualTrackRecorder.manifestFileName) }
    }

    private func maximumRetainedTimelineEndLocked(for meetingID: UUID) throws -> Int {
        var maximumEnd = 0
        for manifestURL in manifests(for: meetingID) where FileManager.default.fileExists(atPath: manifestURL.path) {
            let manifest: SynchronizedRecordingManifest
            do {
                manifest = try Self.loadManifest(at: manifestURL)
            } catch {
                throw MeetingRecordingStoreError.unreadableManifest(manifestURL, error)
            }

            guard manifest.meetingID == meetingID,
                  Self.isValid(manifest: manifest) else {
                throw MeetingRecordingStoreError.invalidManifest(manifestURL)
            }
            guard !ActiveRecordingSessionRegistry.shared.contains(manifest.sessionID) else {
                throw MeetingRecordingStoreError.activeRecordingSession(manifest.sessionID)
            }

            let directory = manifestURL.deletingLastPathComponent()
            var retainedFrames = max(
                manifest.durationFrames,
                manifest.tracks.map(\.frameCount).max() ?? 0
            )
            for track in manifest.tracks {
                let rawURL = directory.appendingPathComponent(track.rawFileName)
                if FileManager.default.fileExists(atPath: rawURL.path) {
                    retainedFrames = max(
                        retainedFrames,
                        try StereoPCM16WAVExporter.rawFrameCount(at: rawURL)
                    )
                }
            }

            maximumEnd = max(
                maximumEnd,
                Self.timelineEndOffsetMilliseconds(
                    baseMilliseconds: manifest.timelineBaseOffsetMilliseconds,
                    durationFrames: retainedFrames,
                    sampleRate: manifest.sampleRate
                )
            )
        }
        return maximumEnd
    }

    /// Converts retained PCM frames to the smallest millisecond boundary that is
    /// guaranteed not to overlap them. Integer arithmetic avoids precision loss and
    /// saturates corrupt/extreme inputs instead of trapping.
    static func timelineEndOffsetMilliseconds(
        baseMilliseconds: Int,
        durationFrames: Int64,
        sampleRate: Int
    ) -> Int {
        let base = max(0, baseMilliseconds)
        guard durationFrames > 0, sampleRate > 0 else { return base }

        let rate = Int64(sampleRate)
        let wholeSeconds = durationFrames / rate
        let remainingFrames = durationFrames % rate
        guard wholeSeconds <= Int64(Int.max / 1_000) else { return Int.max }

        let wholeMilliseconds = Int(wholeSeconds) * 1_000
        // `remainingFrames < sampleRate <= 384_000` for every valid manifest,
        // so this multiplication cannot overflow Int64.
        let fractionalNumerator = remainingFrames * 1_000
        let fractionalMilliseconds = Int(
            (fractionalNumerator + rate - 1) / rate
        )
        let (durationMilliseconds, durationOverflow) = wholeMilliseconds
            .addingReportingOverflow(fractionalMilliseconds)
        guard !durationOverflow else { return Int.max }
        let (end, endOverflow) = base.addingReportingOverflow(durationMilliseconds)
        return endOverflow ? Int.max : end
    }

    private func allManifestURLs() -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: rootDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return enumerator.compactMap { item in
            guard let url = item as? URL,
                  url.lastPathComponent == SynchronizedDualTrackRecorder.manifestFileName else { return nil }
            return url
        }
    }

    private static func loadManifest(at url: URL) throws -> SynchronizedRecordingManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SynchronizedRecordingManifest.self, from: Data(contentsOf: url))
    }

    private static func writeRecoverySilence(frameCount: Int64, to handle: FileHandle) throws {
        guard frameCount >= 0,
              frameCount <= Int64.max / Int64(MemoryLayout<Int16>.size) else {
            throw SynchronizedRecordingError.wavTooLarge(frameCount)
        }
        var remaining = frameCount * Int64(MemoryLayout<Int16>.size)
        let zeros = Data(repeating: 0, count: 64 * 1_024)
        while remaining > 0 {
            let byteCount = Int(min(remaining, Int64(zeros.count)))
            try handle.write(contentsOf: Data(zeros.prefix(byteCount)))
            remaining -= Int64(byteCount)
        }
    }

    private static func saveManifest(_ manifest: SynchronizedRecordingManifest, at url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: url, options: .atomic)
    }

    private static func artifact(
        manifest: SynchronizedRecordingManifest,
        manifestURL: URL,
        wavURL: URL
    ) -> RecordingArtifact? {
        guard isValid(manifest: manifest) else { return nil }
        let directory = manifestURL.deletingLastPathComponent()
        let micFileURL = directory.appendingPathComponent(
            manifest.tracks.first(where: { $0.source == .mic })?.monoWAVFileName
                ?? SynchronizedDualTrackRecorder.candidateWAVFileName
        )
        let systemFileURL = directory.appendingPathComponent(
            manifest.tracks.first(where: { $0.source == .system })?.monoWAVFileName
                ?? SynchronizedDualTrackRecorder.interviewerWAVFileName
        )
        return RecordingArtifact(
            meetingID: manifest.meetingID,
            sessionID: manifest.sessionID,
            recordingStartedAt: manifest.createdAt,
            fileURL: wavURL,
            micFileURL: micFileURL,
            systemFileURL: systemFileURL,
            micRawFileURL: directory.appendingPathComponent(
                manifest.tracks.first(where: { $0.source == .mic })?.rawFileName
                    ?? SynchronizedDualTrackRecorder.candidateRawFileName
            ),
            systemRawFileURL: directory.appendingPathComponent(
                manifest.tracks.first(where: { $0.source == .system })?.rawFileName
                    ?? SynchronizedDualTrackRecorder.interviewerRawFileName
            ),
            manifestURL: manifestURL,
            duration: TimeInterval(manifest.durationFrames) / TimeInterval(manifest.sampleRate),
            sampleRate: manifest.sampleRate,
            channelCount: 2,
            timelineBaseOffsetMilliseconds: manifest.timelineBaseOffsetMilliseconds
        )
    }

    private static func isValid(manifest: SynchronizedRecordingManifest) -> Bool {
        let micTracks = manifest.tracks.filter { $0.source == .mic }
        let systemTracks = manifest.tracks.filter { $0.source == .system }
        guard manifest.sampleRate > 0,
              manifest.sampleRate <= 384_000,
              manifest.durationFrames >= 0,
              manifest.timelineBaseOffsetMilliseconds >= 0,
              manifest.version == SynchronizedRecordingManifest.currentVersion,
              manifest.sampleFormat == "signed-int16-little-endian-mono",
              manifest.tracks.count == 2,
              micTracks.count == 1,
              systemTracks.count == 1,
              micTracks[0].channelIndex == 0,
              micTracks[0].role == "candidate",
              systemTracks[0].channelIndex == 1,
              systemTracks[0].role == "interviewer",
              manifest.tracks.allSatisfy({ track in
                  track.frameCount >= 0
                      && track.insertedSilenceFrames >= 0
                      && track.trimmedOverlapFrames >= 0
              }) else {
            return false
        }

        let fileNames = [manifest.interleavedWAVFileName]
            + manifest.tracks.flatMap { [$0.rawFileName, $0.monoWAVFileName] }
        return fileNames.allSatisfy { name in
            !name.isEmpty
                && name != "."
                && name != ".."
                && URL(fileURLWithPath: name).lastPathComponent == name
        }
    }
}

extension LocalStorageManager {
    /// Stable lookup used by post-meeting transcription services.
    func latestRecordingArtifact(for meetingID: UUID) -> RecordingArtifact? {
        MeetingRecordingStore.shared.latestArtifact(for: meetingID)
    }
}

extension Notification.Name {
    static let meetingRecordingArtifactReady = Notification.Name("MeetingRecordingArtifactReady")
    /// A crash/interruption recovery completed locally. Unlike `meetingRecordingArtifactReady`,
    /// observers must never start cloud upload until the user explicitly retries it.
    static let meetingRecordingArtifactRecovered = Notification.Name("MeetingRecordingArtifactRecovered")
}
