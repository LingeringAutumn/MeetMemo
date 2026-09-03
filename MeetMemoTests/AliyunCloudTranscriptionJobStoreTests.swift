import Foundation
import XCTest
@testable import MeetMemo

final class AliyunCloudTranscriptionJobStoreTests: XCTestCase {
    func testJobsAreKeyedByArtifactAndCanBeFilteredByMeetingSession() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AliyunCloudJobStoreTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AliyunCloudTranscriptionJobStore(directoryURL: directory)
        let meetingID = UUID()
        let firstSession = UUID()
        let secondSession = UUID()
        let firstArtifact = UUID()
        let secondArtifact = UUID()
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

        var first = AliyunCloudTranscriptionJob(
            meetingID: meetingID,
            recordingSessionID: firstSession,
            artifactID: firstArtifact,
            audioFileURL: directory.appendingPathComponent("first.wav"),
            meetingStart: baseDate,
            timelineBaseOffsetMilliseconds: 0,
            recordingDurationMilliseconds: 10_000,
            now: baseDate
        )
        first.taskID = "first-task"
        first.updatedAt = baseDate
        var second = AliyunCloudTranscriptionJob(
            meetingID: meetingID,
            recordingSessionID: secondSession,
            artifactID: secondArtifact,
            audioFileURL: directory.appendingPathComponent("second.wav"),
            meetingStart: baseDate,
            timelineBaseOffsetMilliseconds: 60_000,
            recordingDurationMilliseconds: 20_000,
            now: baseDate.addingTimeInterval(10)
        )
        second.taskID = "second-task"
        second.updatedAt = baseDate.addingTimeInterval(10)

        try await store.save(first)
        try await store.save(second)

        XCTAssertEqual(try await store.load(artifactID: firstArtifact)?.taskID, "first-task")
        XCTAssertEqual(try await store.load(artifactID: secondArtifact)?.taskID, "second-task")
        XCTAssertEqual(
            try await store.loadLatest(meetingID: meetingID, recordingSessionID: firstSession)?.artifactID,
            firstArtifact
        )
        XCTAssertEqual(
            try await store.loadLatest(meetingID: meetingID, recordingSessionID: nil)?.artifactID,
            secondArtifact
        )

        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(Set(files.map(\.deletingPathExtension().lastPathComponent)), Set([
            firstArtifact.uuidString,
            secondArtifact.uuidString
        ]))
    }

    func testDeleteMeetingRemovesAllMatchingJobsAndPreservesOtherMeeting() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AliyunCloudJobDeletionTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AliyunCloudTranscriptionJobStore(directoryURL: directory)
        let targetMeetingID = UUID()
        let otherMeetingID = UUID()

        let targetJobs = [UUID(), UUID()].map { artifactID in
            AliyunCloudTranscriptionJob(
                meetingID: targetMeetingID,
                recordingSessionID: UUID(),
                artifactID: artifactID,
                audioFileURL: directory.appendingPathComponent("\(artifactID).wav"),
                meetingStart: Date()
            )
        }
        let otherArtifactID = UUID()
        let otherJob = AliyunCloudTranscriptionJob(
            meetingID: otherMeetingID,
            recordingSessionID: UUID(),
            artifactID: otherArtifactID,
            audioFileURL: directory.appendingPathComponent("other.wav"),
            meetingStart: Date()
        )

        for job in targetJobs + [otherJob] {
            try await store.save(job)
        }
        try await store.delete(meetingID: targetMeetingID)

        for job in targetJobs {
            let deleted = try await store.load(artifactID: job.artifactID)
            XCTAssertNil(deleted)
        }
        let preserved = try await store.load(artifactID: otherArtifactID)
        XCTAssertEqual(preserved?.meetingID, otherMeetingID)

        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.map(\.lastPathComponent), ["\(otherArtifactID.uuidString).json"])
    }

    func testJobContextIsBoundedBeforePersistence() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AliyunCloudJobContextTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AliyunCloudTranscriptionJobStore(directoryURL: directory)
        let artifactID = UUID()
        let expected = String(repeating: "技", count: AliyunCloudTranscriptionJob.maximumPersistedContextCharacters)
        let oversized = " \n" + String(repeating: "技", count: 450) + "SENSITIVE_TAIL \n"
        let job = AliyunCloudTranscriptionJob(
            meetingID: UUID(),
            recordingSessionID: UUID(),
            artifactID: artifactID,
            audioFileURL: directory.appendingPathComponent("audio.wav"),
            meetingStart: Date(),
            context: oversized
        )

        XCTAssertEqual(job.context, expected)
        XCTAssertNil(AliyunCloudTranscriptionJob.normalizedPersistedContext(" \n "))

        try await store.save(job)
        let persisted = try await store.load(artifactID: artifactID)
        XCTAssertEqual(persisted?.context, expected)

        let rawJSON = try String(
            contentsOf: directory.appendingPathComponent("\(artifactID.uuidString).json"),
            encoding: .utf8
        )
        XCTAssertFalse(rawJSON.contains("SENSITIVE_TAIL"))
    }

    func testRemoteErrorCodesAreSanitizedAndBoundedBeforeDisplay() {
        XCTAssertEqual(
            AliyunCloudTranscriptionErrorSanitizer.sanitizedRemoteCode(" InvalidParameter-1 "),
            "InvalidParameter-1"
        )
        XCTAssertEqual(
            AliyunCloudTranscriptionErrorSanitizer.sanitizedRemoteCode("FAIL\nDROP"),
            "FAIL_DROP"
        )
        XCTAssertEqual(
            AliyunCloudTranscriptionErrorSanitizer.sanitizedRemoteCode(String(repeating: "A", count: 80))?.count,
            AliyunCloudTranscriptionErrorSanitizer.maximumRemoteCodeCharacters
        )
        XCTAssertNil(AliyunCloudTranscriptionErrorSanitizer.sanitizedRemoteCode("sk-secret-value"))

        let description = AliyunCloudTranscriptionErrorSanitizer.description(
            for: .taskFailed(code: "Authorization: Bearer secret-value")
        )
        XCTAssertFalse(description.lowercased().contains("authorization"))
        XCTAssertFalse(description.lowercased().contains("bearer"))
        XCTAssertFalse(description.lowercased().contains("secret-value"))
    }

    func testAbsoluteTimelineMergeDoesNotCollideWithEarlierRecordingSession() throws {
        let json = """
        {"properties":{"original_duration_in_milliseconds":8000},"transcripts":[
          {"channel_id":0,"text":"续录回答","sentences":[
            {"begin_time":1000,"end_time":2500,"text":"续录回答"}
          ]}
        ]}
        """
        let wire = try JSONDecoder().decode(WireTranscriptionResult.self, from: Data(json.utf8))
        let result = try AliyunTranscriptMerger.merge(
            wire,
            options: AliyunFileTranscriptionOptions(),
            meetingStart: Date(timeIntervalSince1970: 1_700_000_000),
            timelineBaseOffsetMilliseconds: 90_000
        )

        XCTAssertEqual(result.chunks.first?.startTime, 91_000)
        XCTAssertEqual(result.chunks.first?.endTime, 92_500)
        XCTAssertGreaterThan(result.chunks.first?.startTime ?? 0, 80_000)
    }

    func testRemoteTimelineOverflowIsRejectedWithoutTrapping() throws {
        let json = """
        {"properties":{"original_duration_in_milliseconds":1000},"transcripts":[
          {"channel_id":1,"text":"问题","sentences":[
            {"begin_time":0,"end_time":1000,"text":"问题"}
          ]}
        ]}
        """
        let wire = try JSONDecoder().decode(WireTranscriptionResult.self, from: Data(json.utf8))

        XCTAssertThrowsError(try AliyunTranscriptMerger.merge(
            wire,
            options: AliyunFileTranscriptionOptions(),
            meetingStart: Date(),
            timelineBaseOffsetMilliseconds: Int.max
        )) { error in
            XCTAssertEqual(error as? AliyunFileTranscriptionError, .malformedResponse)
        }
    }

    func testSingleChannelCloudResultReportsOnlyTheSourceItCanSafelyReplace() throws {
        let json = """
        {"properties":{"original_duration_in_milliseconds":1000},"transcripts":[
          {"channel_id":0,"text":"候选人回答","sentences":[
            {"begin_time":0,"end_time":1000,"text":"候选人回答"}
          ]},
          {"channel_id":1,"text":"","sentences":[]}
        ]}
        """
        let wire = try JSONDecoder().decode(WireTranscriptionResult.self, from: Data(json.utf8))
        let result = try AliyunTranscriptMerger.merge(
            wire,
            options: AliyunFileTranscriptionOptions(),
            meetingStart: Date()
        )

        XCTAssertEqual(Set(result.chunks.map(\.source)), [.mic])
        XCTAssertFalse(result.chunks.contains(where: { $0.source == .system }))
    }

    func testAccurateReplacementPreservesMissingChannelAndUncoveredHole() {
        let micCovered = transcriptChunk(text: "旧回答一", source: .mic, start: 0, end: 1_000)
        let micHole = transcriptChunk(text: "质量门保留", source: .mic, start: 8_000, end: 9_000)
        let systemDraft = transcriptChunk(text: "面试官问题", source: .system, start: 0, end: 2_000)
        let accurateMic = transcriptChunk(text: "精准回答一", source: .mic, start: 100, end: 1_100)

        let merged = AccurateTranscriptReplacement.merging(
            existing: [micCovered, micHole, systemDraft],
            replacement: [accurateMic],
            replacementStartMilliseconds: 0,
            replacementEndMilliseconds: 10_000
        )

        XCTAssertFalse(merged.contains(where: { $0.id == micCovered.id }))
        XCTAssertTrue(merged.contains(where: { $0.id == micHole.id }))
        XCTAssertTrue(merged.contains(where: { $0.id == systemDraft.id }))
        XCTAssertTrue(merged.contains(where: { $0.id == accurateMic.id }))
    }

    func testAccurateReplacementCannotDeleteAdjacentContinuationSessions() {
        let previousSessionTail = transcriptChunk(
            text: "上一段尾句",
            source: .mic,
            start: 89_500,
            end: 90_000
        )
        let currentDraft = transcriptChunk(
            text: "本段实时文字",
            source: .mic,
            start: 90_000,
            end: 91_000
        )
        let accurateCurrent = transcriptChunk(
            text: "本段精准文字",
            source: .mic,
            start: 90_000,
            end: 91_000
        )

        let merged = AccurateTranscriptReplacement.merging(
            existing: [previousSessionTail, currentDraft],
            replacement: [accurateCurrent],
            replacementStartMilliseconds: 90_000,
            replacementEndMilliseconds: 120_000
        )

        XCTAssertTrue(merged.contains(where: { $0.id == previousSessionTail.id }))
        XCTAssertFalse(merged.contains(where: { $0.id == currentDraft.id }))
        XCTAssertTrue(merged.contains(where: { $0.id == accurateCurrent.id }))
    }

    func testAccurateReplacementPreservesShortQualityGateGap() {
        let firstDraft = transcriptChunk(text: "旧一", source: .mic, start: 0, end: 1_000)
        let gapDraft = transcriptChunk(text: "对，我想一下", source: .mic, start: 2_000, end: 2_500)
        let lastDraft = transcriptChunk(text: "旧二", source: .mic, start: 3_000, end: 4_000)
        let firstAccurate = transcriptChunk(text: "精准一", source: .mic, start: 0, end: 1_000)
        let lastAccurate = transcriptChunk(text: "精准二", source: .mic, start: 3_000, end: 4_000)

        let merged = AccurateTranscriptReplacement.merging(
            existing: [firstDraft, gapDraft, lastDraft],
            replacement: [firstAccurate, lastAccurate],
            replacementStartMilliseconds: 0,
            replacementEndMilliseconds: 5_000
        )

        XCTAssertTrue(merged.contains(where: { $0.id == gapDraft.id }))
    }

    func testAccurateReplacementToleranceCannotBridgeInternalQualityGateHole() {
        let crossingDraft = transcriptChunk(
            text: "这个实时块跨过了质量门空洞",
            source: .mic,
            start: 900,
            end: 1_900
        )
        let firstAccurate = transcriptChunk(text: "精准一", source: .mic, start: 0, end: 1_000)
        let lastAccurate = transcriptChunk(text: "精准二", source: .mic, start: 1_800, end: 2_800)

        let merged = AccurateTranscriptReplacement.merging(
            existing: [crossingDraft],
            replacement: [firstAccurate, lastAccurate],
            replacementStartMilliseconds: 0,
            replacementEndMilliseconds: 3_000
        )

        XCTAssertTrue(merged.contains(where: { $0.id == crossingDraft.id }))
        XCTAssertTrue(merged.contains(where: { $0.id == firstAccurate.id }))
        XCTAssertTrue(merged.contains(where: { $0.id == lastAccurate.id }))
    }

    func testAccurateReplacementStillUsesToleranceAtConnectedComponentBoundary() {
        let boundaryDraft = transcriptChunk(text: "旧实时块", source: .mic, start: 0, end: 1_000)
        let jitteredAccurate = transcriptChunk(text: "精准块", source: .mic, start: 100, end: 1_100)

        let merged = AccurateTranscriptReplacement.merging(
            existing: [boundaryDraft],
            replacement: [jitteredAccurate],
            replacementStartMilliseconds: 0,
            replacementEndMilliseconds: 2_000
        )

        XCTAssertFalse(merged.contains(where: { $0.id == boundaryDraft.id }))
        XCTAssertTrue(merged.contains(where: { $0.id == jitteredAccurate.id }))
    }

    func testAccurateReplacementPreservesLongDraftWhenOnlyMiddleIsCovered() {
        let longDraft = transcriptChunk(
            text: "前半句、中间词和后半句都在同一个实时块里",
            source: .mic,
            start: 0,
            end: 10_000
        )
        let narrowAccurate = transcriptChunk(
            text: "中间词",
            source: .mic,
            start: 4_500,
            end: 5_500
        )

        let merged = AccurateTranscriptReplacement.merging(
            existing: [longDraft],
            replacement: [narrowAccurate],
            replacementStartMilliseconds: 0,
            replacementEndMilliseconds: 10_000
        )

        XCTAssertTrue(merged.contains(where: { $0.id == longDraft.id }))
        XCTAssertTrue(merged.contains(where: { $0.id == narrowAccurate.id }))
    }

    func testAccurateReplacementHandlesExtremeImportedTimestampsWithoutOverflow() {
        let malformed = transcriptChunk(
            text: "导入异常值",
            source: .mic,
            start: Int.min,
            end: Int.max
        )
        let accurate = transcriptChunk(text: "精准", source: .mic, start: 0, end: 1_000)

        let merged = AccurateTranscriptReplacement.merging(
            existing: [malformed],
            replacement: [accurate],
            replacementStartMilliseconds: 0,
            replacementEndMilliseconds: 1_000
        )

        XCTAssertTrue(merged.contains(where: { $0.id == accurate.id }))
    }

    func testCloudJobRejectsRecordingPathOutsideItsMeetingSessionDirectory() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrustedRecordingRoot-\(UUID().uuidString)")
        let meetingID = UUID()
        let sessionID = UUID()
        let expected = root
            .appendingPathComponent(meetingID.uuidString)
            .appendingPathComponent(sessionID.uuidString)
            .appendingPathComponent(SynchronizedDualTrackRecorder.wavFileName)

        XCTAssertTrue(AliyunCloudTranscriptionJob.isTrustedRecordingPath(
            expected,
            meetingID: meetingID,
            recordingSessionID: sessionID,
            rootDirectory: root
        ))
        XCTAssertFalse(AliyunCloudTranscriptionJob.isTrustedRecordingPath(
            root.appendingPathComponent("unrelated.wav"),
            meetingID: meetingID,
            recordingSessionID: sessionID,
            rootDirectory: root
        ))
    }

    private func transcriptChunk(
        text: String,
        source: AudioSource,
        start: Int,
        end: Int
    ) -> TranscriptChunk {
        TranscriptChunk(
            source: source,
            text: text,
            isFinal: true,
            startTime: start,
            endTime: end
        )
    }
}
