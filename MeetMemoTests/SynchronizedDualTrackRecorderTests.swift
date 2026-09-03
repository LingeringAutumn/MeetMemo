import Foundation
import XCTest
@testable import MeetMemo

final class SynchronizedDualTrackRecorderTests: XCTestCase {
    func testMonotonicTimelineMapsSharedHostTicksToNondecreasingSamplePositions() {
        let timeline = MonotonicAudioTimeline(
            sampleRate: 16_000,
            originHostTime: 1_000,
            hostClockFrequency: 1_000
        )

        let hostTimes: [UInt64] = [999, 1_000, 1_250, 1_500, 2_000]
        let positions = hostTimes.map(timeline.samplePosition(forHostTime:))

        XCTAssertEqual(positions, [0, 0, 4_000, 8_000, 16_000])
        XCTAssertEqual(positions, positions.sorted())
    }

    func testRecorderFillsTimelineGapsAndTrimsOverlappingFrames() async throws {
        let rootDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootDirectory) }

        let recorder = try SynchronizedDualTrackRecorder(
            meetingID: UUID(),
            sessionID: UUID(),
            rootDirectory: rootDirectory,
            timeline: deterministicTimeline()
        )

        recorder.append(pcmData([10, 11, 12]), source: .mic, atSamplePosition: 2)
        recorder.append(pcmData([99, 100, 101]), source: .mic, atSamplePosition: 4)
        let artifact = try await recorder.finish(atSamplePosition: 7).get()

        XCTAssertEqual(
            try pcmSamples(at: artifact.micRawFileURL),
            [0, 0, 10, 11, 12, 100, 101]
        )
        XCTAssertEqual(try pcmSamples(at: artifact.systemRawFileURL), Array(repeating: 0, count: 7))

        let manifest = try loadManifest(at: artifact.manifestURL)
        let micTrack = try XCTUnwrap(manifest.tracks.first(where: { $0.source == .mic }))
        let systemTrack = try XCTUnwrap(manifest.tracks.first(where: { $0.source == .system }))
        XCTAssertEqual(micTrack.frameCount, 7)
        XCTAssertEqual(micTrack.insertedSilenceFrames, 2)
        XCTAssertEqual(micTrack.trimmedOverlapFrames, 1)
        XCTAssertEqual(systemTrack.frameCount, 7)
        XCTAssertEqual(systemTrack.insertedSilenceFrames, 7)
        XCTAssertNotNil(manifest.accurateTranscriptionRequestedAt)
    }

    func testStereoWAVKeepsMicOnChannelZeroSystemOnChannelOneAndPreservesBaseOffset() async throws {
        let rootDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootDirectory) }

        let meetingID = UUID()
        let sessionID = UUID()
        let frameCount = 160
        let baseOffsetMilliseconds = 90_000
        let recordingStartedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let recorder = try SynchronizedDualTrackRecorder(
            meetingID: meetingID,
            sessionID: sessionID,
            rootDirectory: rootDirectory,
            timeline: deterministicTimeline(),
            recordingStartedAt: recordingStartedAt,
            timelineBaseOffsetMilliseconds: baseOffsetMilliseconds
        )

        recorder.append(
            pcmData(Array(repeating: 1_111, count: frameCount)),
            source: .mic,
            atSamplePosition: 0
        )
        recorder.append(
            pcmData(Array(repeating: -2_222, count: frameCount)),
            source: .system,
            atSamplePosition: 0
        )
        let artifact = try await recorder.finish(atSamplePosition: Int64(frameCount)).get()

        XCTAssertEqual(artifact.meetingID, meetingID)
        XCTAssertEqual(artifact.sessionID, sessionID)
        XCTAssertEqual(artifact.sampleRate, 16_000)
        XCTAssertEqual(artifact.channelCount, 2)
        XCTAssertEqual(artifact.recordingStartedAt, recordingStartedAt)
        XCTAssertEqual(artifact.timelineBaseOffsetMilliseconds, baseOffsetMilliseconds)
        XCTAssertEqual(artifact.timelineEndOffsetMilliseconds, 90_010)

        let wavData = try Data(contentsOf: artifact.stereoFileURL)
        XCTAssertEqual(ascii(in: wavData, offset: 0, count: 4), "RIFF")
        XCTAssertEqual(ascii(in: wavData, offset: 8, count: 4), "WAVE")
        XCTAssertEqual(ascii(in: wavData, offset: 36, count: 4), "data")
        XCTAssertEqual(uint16LE(in: wavData, offset: 20), 1)
        XCTAssertEqual(uint16LE(in: wavData, offset: 22), 2)
        XCTAssertEqual(uint32LE(in: wavData, offset: 24), 16_000)
        XCTAssertEqual(uint32LE(in: wavData, offset: 28), 64_000)
        XCTAssertEqual(uint16LE(in: wavData, offset: 32), 4)
        XCTAssertEqual(uint16LE(in: wavData, offset: 34), 16)
        XCTAssertEqual(uint32LE(in: wavData, offset: 40), UInt32(frameCount * 4))
        XCTAssertEqual(uint32LE(in: wavData, offset: 4), UInt32(36 + frameCount * 4))
        XCTAssertEqual(wavData.count, 44 + frameCount * 4)

        let interleavedSamples = pcmSamples(in: Data(wavData.dropFirst(44)))
        XCTAssertEqual(Array(interleavedSamples.prefix(4)), [1_111, -2_222, 1_111, -2_222])
        XCTAssertEqual(interleavedSamples.count, frameCount * 2)

        let manifest = try loadManifest(at: artifact.manifestURL)
        XCTAssertEqual(manifest.timelineBaseOffsetMilliseconds, baseOffsetMilliseconds)
        XCTAssertEqual(manifest.durationFrames, Int64(frameCount))
        XCTAssertEqual(manifest.status, .completed)
        XCTAssertEqual(manifest.createdAt, recordingStartedAt)
        XCTAssertNotNil(manifest.accurateTranscriptionRequestedAt)
        XCTAssertEqual(manifest.tracks.map(\.channelIndex), [0, 1])
        XCTAssertEqual(manifest.tracks.map(\.source), [.mic, .system])
        XCTAssertEqual(manifest.tracks.map(\.role), ["candidate", "interviewer"])
    }

    func testInterruptedRecordingCanBeRecoveredIntoAlignedStereoArtifact() async throws {
        let rootDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootDirectory) }

        let meetingID = UUID()
        let sessionID = UUID()
        let recorder = try SynchronizedDualTrackRecorder(
            meetingID: meetingID,
            sessionID: sessionID,
            rootDirectory: rootDirectory,
            timeline: deterministicTimeline(),
            timelineBaseOffsetMilliseconds: 12_000
        )
        recorder.append(pcmData([321, 322, 323]), source: .mic, atSamplePosition: 0)
        recorder.append(pcmData([-7, -8]), source: .system, atSamplePosition: 1)

        let store = MeetingRecordingStore(rootDirectory: rootDirectory)
        XCTAssertTrue(
            store.recoverIncompleteRecordings().isEmpty,
            "Recovery must not claim a session that this process is still writing."
        )
        await recorder.preserveForRecovery(reason: "simulated interruption")

        let interruptedManifest = try loadManifest(at: recorder.manifestURL)
        XCTAssertEqual(interruptedManifest.status, .interrupted)
        XCTAssertEqual(interruptedManifest.lastError, "simulated interruption")

        let recoveredArtifacts = store.recoverIncompleteRecordings()
        let artifact = try XCTUnwrap(recoveredArtifacts.first)

        XCTAssertEqual(recoveredArtifacts.count, 1)
        XCTAssertEqual(artifact.meetingID, meetingID)
        XCTAssertEqual(artifact.sessionID, sessionID)
        XCTAssertEqual(artifact.timelineBaseOffsetMilliseconds, 12_000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.stereoFileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.micFileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.systemFileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.micRawFileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.systemRawFileURL.path))
        XCTAssertEqual(store.latestArtifact(for: meetingID)?.sessionID, sessionID)

        let recoveredWAVData = try Data(contentsOf: artifact.stereoFileURL)
        let recoveredSamples = pcmSamples(in: Data(recoveredWAVData.dropFirst(44)))
        XCTAssertEqual(recoveredSamples, [321, 0, 322, -7, 323, -8])

        let completedManifest = try loadManifest(at: artifact.manifestURL)
        XCTAssertEqual(completedManifest.status, .completed)
        XCTAssertNotNil(completedManifest.accurateTranscriptionRequestedAt)
        XCTAssertEqual(completedManifest.durationFrames, 3)
        XCTAssertEqual(
            completedManifest.tracks.first(where: { $0.source == .system })?.insertedSilenceFrames,
            1
        )
        XCTAssertEqual(store.recoverIncompleteRecordings().count, 0)
    }

    func testRetainedTimelineEndIncludesInterruptedExportFailedAndRawFramesNewerThanManifest() async throws {
        let rootDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootDirectory) }
        let meetingID = UUID()

        let interrupted = try SynchronizedDualTrackRecorder(
            meetingID: meetingID,
            sessionID: UUID(),
            rootDirectory: rootDirectory,
            timeline: deterministicTimeline(),
            timelineBaseOffsetMilliseconds: 10_000
        )
        interrupted.append(
            pcmData(Array(repeating: 1, count: 16_000)),
            source: .mic,
            atSamplePosition: 0
        )
        await interrupted.preserveForRecovery(reason: "test interruption")

        let completed = try SynchronizedDualTrackRecorder(
            meetingID: meetingID,
            sessionID: UUID(),
            rootDirectory: rootDirectory,
            timeline: deterministicTimeline(),
            timelineBaseOffsetMilliseconds: 20_000
        )
        completed.append(
            pcmData(Array(repeating: 2, count: 8_000)),
            source: .system,
            atSamplePosition: 0
        )
        _ = try await completed.finish(atSamplePosition: 8_000).get()

        let failed = try SynchronizedDualTrackRecorder(
            meetingID: meetingID,
            sessionID: UUID(),
            rootDirectory: rootDirectory,
            timeline: deterministicTimeline(),
            timelineBaseOffsetMilliseconds: 30_000
        )
        failed.append(
            pcmData(Array(repeating: 3, count: 16_001)),
            source: .mic,
            atSamplePosition: 0
        )
        await failed.preserveForRecovery(reason: "test export failure")

        // Simulate an export failure after PCM reached disk but before the latest
        // counters made it into the manifest. The reservation must inspect raw PCM,
        // not regress to the stale manifest duration.
        var failedManifest = try loadManifest(at: failed.manifestURL)
        failedManifest.status = .exportFailed
        failedManifest.durationFrames = 0
        for index in failedManifest.tracks.indices {
            failedManifest.tracks[index].frameCount = 0
        }
        try saveManifest(failedManifest, at: failed.manifestURL)

        let store = MeetingRecordingStore(rootDirectory: rootDirectory)
        XCTAssertEqual(try store.maximumRetainedTimelineEnd(for: meetingID), 31_001)

        let reservation = try store.reserveRecorder(
            meetingID: meetingID,
            sessionID: UUID(),
            timeline: deterministicTimeline(),
            minimumTimelineEndMilliseconds: 25_000
        )
        XCTAssertEqual(reservation.timelineBaseOffsetMilliseconds, 31_001)
        XCTAssertEqual(
            try loadManifest(at: reservation.recorder.manifestURL).timelineBaseOffsetMilliseconds,
            31_001
        )
        await reservation.recorder.preserveForRecovery(reason: "test cleanup")
    }

    func testRecorderReservationRejectsAnActiveSessionForTheSameMeeting() async throws {
        let rootDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootDirectory) }
        let meetingID = UUID()
        let active = try SynchronizedDualTrackRecorder(
            meetingID: meetingID,
            sessionID: UUID(),
            rootDirectory: rootDirectory,
            timeline: deterministicTimeline(),
            timelineBaseOffsetMilliseconds: 5_000
        )
        let store = MeetingRecordingStore(rootDirectory: rootDirectory)

        XCTAssertThrowsError(try store.reserveRecorder(
            meetingID: meetingID,
            sessionID: UUID(),
            timeline: deterministicTimeline(),
            minimumTimelineEndMilliseconds: 0
        )) { error in
            guard case MeetingRecordingStoreError.activeRecordingSession = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        await active.preserveForRecovery(reason: "test cleanup")
        let reservation = try store.reserveRecorder(
            meetingID: meetingID,
            sessionID: UUID(),
            timeline: deterministicTimeline(),
            minimumTimelineEndMilliseconds: 9_000
        )
        XCTAssertEqual(reservation.timelineBaseOffsetMilliseconds, 9_000)
        await reservation.recorder.preserveForRecovery(reason: "test cleanup")
    }

    func testTimelineEndRoundsUpPartialMillisecondsAndSaturates() {
        XCTAssertEqual(
            MeetingRecordingStore.timelineEndOffsetMilliseconds(
                baseMilliseconds: 30_000,
                durationFrames: 16_001,
                sampleRate: 16_000
            ),
            31_001
        )
        XCTAssertEqual(
            MeetingRecordingStore.timelineEndOffsetMilliseconds(
                baseMilliseconds: Int.max - 1,
                durationFrames: 16_000,
                sampleRate: 16_000
            ),
            Int.max
        )
    }

    func testPendingAccurateArtifactsExcludeLegacyManifestAndSupportExactSessionLookup() async throws {
        let rootDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootDirectory) }
        let meetingID = UUID()
        let firstSessionID = UUID()
        let secondSessionID = UUID()

        let first = try SynchronizedDualTrackRecorder(
            meetingID: meetingID,
            sessionID: firstSessionID,
            rootDirectory: rootDirectory,
            timeline: deterministicTimeline(),
            recordingStartedAt: Date(timeIntervalSince1970: 100),
            timelineBaseOffsetMilliseconds: 0
        )
        first.append(pcmData([1]), source: .mic, atSamplePosition: 0)
        _ = try await first.finish(atSamplePosition: 1).get()

        let second = try SynchronizedDualTrackRecorder(
            meetingID: meetingID,
            sessionID: secondSessionID,
            rootDirectory: rootDirectory,
            timeline: deterministicTimeline(),
            recordingStartedAt: Date(timeIntervalSince1970: 200),
            timelineBaseOffsetMilliseconds: 10_000
        )
        second.append(pcmData([2]), source: .mic, atSamplePosition: 0)
        _ = try await second.finish(atSamplePosition: 1).get()

        let store = MeetingRecordingStore(rootDirectory: rootDirectory)
        XCTAssertEqual(Set(store.pendingAccurateTranscriptionArtifacts().map(\.sessionID)), [
            firstSessionID,
            secondSessionID
        ])
        XCTAssertEqual(
            store.artifact(for: meetingID, sessionID: firstSessionID)?.sessionID,
            firstSessionID
        )

        let firstManifestURL = rootDirectory
            .appendingPathComponent(meetingID.uuidString)
            .appendingPathComponent(firstSessionID.uuidString)
            .appendingPathComponent(SynchronizedDualTrackRecorder.manifestFileName)
        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: firstManifestURL)) as? [String: Any]
        )
        legacyObject.removeValue(forKey: "accurateTranscriptionRequestedAt")
        try JSONSerialization.data(withJSONObject: legacyObject).write(to: firstManifestURL)

        XCTAssertEqual(
            store.pendingAccurateTranscriptionArtifacts().map(\.sessionID),
            [secondSessionID]
        )
    }

    func testDeleteRecordingsRemovesOnlySelectedMeetingDirectory() throws {
        let rootDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootDirectory) }
        let targetMeetingID = UUID()
        let otherMeetingID = UUID()
        let targetDirectory = rootDirectory.appendingPathComponent(
            targetMeetingID.uuidString,
            isDirectory: true
        )
        let otherDirectory = rootDirectory.appendingPathComponent(
            otherMeetingID.uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: otherDirectory, withIntermediateDirectories: true)
        try Data("target".utf8).write(to: targetDirectory.appendingPathComponent("sentinel"))
        try Data("other".utf8).write(to: otherDirectory.appendingPathComponent("sentinel"))

        let store = MeetingRecordingStore(rootDirectory: rootDirectory)
        try store.deleteRecordings(for: targetMeetingID)

        XCTAssertFalse(FileManager.default.fileExists(atPath: targetDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: otherDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: otherDirectory.appendingPathComponent("sentinel").path
        ))

        XCTAssertNoThrow(try store.deleteRecordings(for: targetMeetingID))
    }

    func testRecoveredArtifactsUseANonAutomaticNotificationRoute() {
        XCTAssertNotEqual(
            Notification.Name.meetingRecordingArtifactRecovered,
            Notification.Name.meetingRecordingArtifactReady
        )
    }

    func testArtifactTimelineEndSaturatesInsteadOfTrappingOnInvalidDuration() {
        let recordingStartedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let artifact = RecordingArtifact(
            meetingID: UUID(),
            sessionID: UUID(),
            recordingStartedAt: recordingStartedAt,
            fileURL: URL(fileURLWithPath: "/tmp/stereo.wav"),
            micFileURL: URL(fileURLWithPath: "/tmp/mic.wav"),
            systemFileURL: URL(fileURLWithPath: "/tmp/system.wav"),
            micRawFileURL: URL(fileURLWithPath: "/tmp/mic.pcm"),
            systemRawFileURL: URL(fileURLWithPath: "/tmp/system.pcm"),
            manifestURL: URL(fileURLWithPath: "/tmp/manifest.json"),
            duration: .infinity,
            sampleRate: 16_000,
            channelCount: 2,
            timelineBaseOffsetMilliseconds: Int.max - 5
        )

        XCTAssertEqual(artifact.timelineEndOffsetMilliseconds, Int.max - 5)
        XCTAssertEqual(
            artifact.wallClockTimestamp(forMeetingTimelineMilliseconds: Int.max - 4)
                .timeIntervalSince1970,
            recordingStartedAt.addingTimeInterval(0.001).timeIntervalSince1970,
            accuracy: 0.000_001
        )
    }

    func testArtifactTimelineEndRoundsFractionalMillisecondsUp() {
        let artifact = RecordingArtifact(
            meetingID: UUID(),
            sessionID: UUID(),
            recordingStartedAt: Date(timeIntervalSince1970: 1_700_000_000),
            fileURL: URL(fileURLWithPath: "/tmp/stereo.wav"),
            micFileURL: URL(fileURLWithPath: "/tmp/mic.wav"),
            systemFileURL: URL(fileURLWithPath: "/tmp/system.wav"),
            micRawFileURL: URL(fileURLWithPath: "/tmp/mic.pcm"),
            systemRawFileURL: URL(fileURLWithPath: "/tmp/system.pcm"),
            manifestURL: URL(fileURLWithPath: "/tmp/manifest.json"),
            duration: 1.000_062_5,
            sampleRate: 16_000,
            channelCount: 2,
            timelineBaseOffsetMilliseconds: 90_000
        )

        XCTAssertEqual(artifact.timelineEndOffsetMilliseconds, 91_001)
    }

    func testArtifactUsesRecordingStartForAContinuationCreatedOnAnotherDay() {
        let recordingStartedAt = Date(timeIntervalSince1970: 1_700_086_400)
        let artifact = RecordingArtifact(
            meetingID: UUID(),
            sessionID: UUID(),
            recordingStartedAt: recordingStartedAt,
            fileURL: URL(fileURLWithPath: "/tmp/stereo.wav"),
            micFileURL: URL(fileURLWithPath: "/tmp/mic.wav"),
            systemFileURL: URL(fileURLWithPath: "/tmp/system.wav"),
            micRawFileURL: URL(fileURLWithPath: "/tmp/mic.pcm"),
            systemRawFileURL: URL(fileURLWithPath: "/tmp/system.pcm"),
            manifestURL: URL(fileURLWithPath: "/tmp/manifest.json"),
            duration: 10,
            sampleRate: 16_000,
            channelCount: 2,
            timelineBaseOffsetMilliseconds: 90_000
        )

        XCTAssertEqual(
            artifact.transcriptTimelineOrigin.addingTimeInterval(90).timeIntervalSince1970,
            recordingStartedAt.timeIntervalSince1970,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            artifact.wallClockTimestamp(forMeetingTimelineMilliseconds: 92_500)
                .timeIntervalSince1970,
            recordingStartedAt.addingTimeInterval(2.5).timeIntervalSince1970,
            accuracy: 0.000_001
        )
    }

    func testStoreRejectsCompletedManifestWithZeroSampleRate() throws {
        let rootDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootDirectory) }
        let meetingID = UUID()
        let sessionID = UUID()
        let directory = rootDirectory
            .appendingPathComponent(meetingID.uuidString, isDirectory: true)
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let tracks = [
            SynchronizedRecordingTrackManifest(
                source: .mic,
                role: "candidate",
                channelIndex: 0,
                rawFileName: SynchronizedDualTrackRecorder.candidateRawFileName,
                monoWAVFileName: SynchronizedDualTrackRecorder.candidateWAVFileName,
                frameCount: 1,
                insertedSilenceFrames: 0,
                trimmedOverlapFrames: 0
            ),
            SynchronizedRecordingTrackManifest(
                source: .system,
                role: "interviewer",
                channelIndex: 1,
                rawFileName: SynchronizedDualTrackRecorder.interviewerRawFileName,
                monoWAVFileName: SynchronizedDualTrackRecorder.interviewerWAVFileName,
                frameCount: 1,
                insertedSilenceFrames: 0,
                trimmedOverlapFrames: 0
            )
        ]
        let manifest = SynchronizedRecordingManifest(
            version: SynchronizedRecordingManifest.currentVersion,
            meetingID: meetingID,
            sessionID: sessionID,
            createdAt: Date(),
            finalizedAt: Date(),
            status: .completed,
            sampleRate: 0,
            sampleFormat: "s16le",
            timelineBaseOffsetMilliseconds: 0,
            interleavedWAVFileName: SynchronizedDualTrackRecorder.wavFileName,
            durationFrames: 1,
            tracks: tracks,
            lastError: nil
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: directory.appendingPathComponent(SynchronizedDualTrackRecorder.manifestFileName)
        )
        for name in [
            SynchronizedDualTrackRecorder.wavFileName,
            SynchronizedDualTrackRecorder.candidateWAVFileName,
            SynchronizedDualTrackRecorder.interviewerWAVFileName
        ] {
            try Data().write(to: directory.appendingPathComponent(name))
        }

        XCTAssertNil(MeetingRecordingStore(rootDirectory: rootDirectory).latestArtifact(for: meetingID))
    }

    private func deterministicTimeline() -> MonotonicAudioTimeline {
        MonotonicAudioTimeline(
            sampleRate: 16_000,
            originHostTime: 1,
            hostClockFrequency: 1
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SynchronizedDualTrackRecorderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func loadManifest(at url: URL) throws -> SynchronizedRecordingManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SynchronizedRecordingManifest.self, from: Data(contentsOf: url))
    }

    private func saveManifest(_ manifest: SynchronizedRecordingManifest, at url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: url, options: .atomic)
    }

    private func pcmData(_ samples: [Int16]) -> Data {
        var data = Data(capacity: samples.count * MemoryLayout<Int16>.size)
        for sample in samples {
            var littleEndianSample = sample.littleEndian
            withUnsafeBytes(of: &littleEndianSample) { data.append(contentsOf: $0) }
        }
        return data
    }

    private func pcmSamples(at url: URL) throws -> [Int16] {
        pcmSamples(in: try Data(contentsOf: url))
    }

    private func pcmSamples(in data: Data) -> [Int16] {
        stride(from: 0, to: data.count - (data.count % 2), by: 2).map { offset in
            let low = UInt16(data[data.startIndex + offset])
            let high = UInt16(data[data.startIndex + offset + 1]) << 8
            return Int16(bitPattern: low | high)
        }
    }

    private func ascii(in data: Data, offset: Int, count: Int) -> String? {
        guard offset >= 0, count >= 0, offset + count <= data.count else { return nil }
        return String(data: data.subdata(in: offset..<(offset + count)), encoding: .ascii)
    }

    private func uint16LE(in data: Data, offset: Int) -> UInt16 {
        UInt16(data[data.startIndex + offset])
            | (UInt16(data[data.startIndex + offset + 1]) << 8)
    }

    private func uint32LE(in data: Data, offset: Int) -> UInt32 {
        UInt32(data[data.startIndex + offset])
            | (UInt32(data[data.startIndex + offset + 1]) << 8)
            | (UInt32(data[data.startIndex + offset + 2]) << 16)
            | (UInt32(data[data.startIndex + offset + 3]) << 24)
    }
}
