import XCTest
@testable import MeetMemo

final class MeetingAccurateTranscriptUpdateTests: XCTestCase {
    func testAccurateTranscriptReplacesLiveDraftWhilePreservingUnsavedContext() throws {
        let meetingID = UUID()
        let liveChunk = transcriptChunk(text: "旧实时字幕", source: .mic, start: 0, end: 1_000)
        let accurateChunk = transcriptChunk(text: "新的精准字幕", source: .mic, start: 0, end: 1_000)

        var current = Meeting(
            id: meetingID,
            title: "本地尚未保存的标题",
            transcriptChunks: [liveChunk],
            contextItems: [MeetingContextItem(kind: .text, title: "JD", extractedText: "Go 后端")],
            speakerNameMappings: ["MIC:candidate": "陈彦哲"]
        )
        current.generatedNotes = "本地纪要"

        let persisted = Meeting(
            id: meetingID,
            title: "磁盘旧标题",
            transcriptChunks: [accurateChunk],
            transcriptRevision: 1,
            accurateTranscriptReceipts: [receipt(engine: .aliyunCloud, start: 0, end: 1_000)],
            speakerNameMappings: [
                "MIC:candidate": "候选人",
                "SYS:interviewer": "面试官"
            ]
        )

        let merged = try XCTUnwrap(
            MeetingAccurateTranscriptUpdate(persistedMeeting: persisted)
                .merging(into: current)
        )

        XCTAssertEqual(merged.title, "本地尚未保存的标题")
        XCTAssertEqual(merged.contextItems.first?.extractedText, "Go 后端")
        XCTAssertEqual(merged.generatedNotes, "本地纪要")
        XCTAssertEqual(merged.transcriptChunks, [accurateChunk])
        XCTAssertEqual(merged.transcriptRevision, 1)
        XCTAssertEqual(merged.latestAccurateTranscriptReceipt?.engine, .aliyunCloud)
        XCTAssertEqual(merged.speakerNameMappings["MIC:candidate"], "陈彦哲")
        XCTAssertEqual(merged.speakerNameMappings["SYS:interviewer"], "面试官")
    }

    func testAccurateTranscriptUsesPersistedSnapshotWithoutLocalEdits() throws {
        let meetingID = UUID()
        let current = Meeting(
            id: meetingID,
            title: "旧标题",
            transcriptChunks: [transcriptChunk(text: "旧字幕", source: .mic, start: 0, end: 1_000)]
        )
        let persisted = Meeting(
            id: meetingID,
            title: "磁盘标题",
            transcriptChunks: [transcriptChunk(text: "精准字幕", source: .system, start: 0, end: 1_000)],
            transcriptRevision: 1
        )

        let merged = try XCTUnwrap(
            MeetingAccurateTranscriptUpdate(persistedMeeting: persisted)
                .merging(into: current)
        )

        XCTAssertEqual(merged.title, current.title)
        XCTAssertEqual(merged.transcriptChunks, persisted.transcriptChunks)
        XCTAssertEqual(merged.transcriptRevision, 1)
    }

    func testAccurateTranscriptCannotCrossMeetings() {
        let update = MeetingAccurateTranscriptUpdate(persistedMeeting: Meeting(id: UUID()))
        XCTAssertNil(update.merging(into: Meeting(id: UUID())))
    }

    func testStaleSnapshotCannotReviveSupersededLiveChunks() {
        let meetingID = UUID()
        let liveChunk = transcriptChunk(text: "旧实时字幕", source: .mic, start: 0, end: 1_000)
        let accurateChunk = transcriptChunk(text: "精准字幕", source: .mic, start: 0, end: 1_000)
        let stale = Meeting(
            id: meetingID,
            title: "后来编辑的标题",
            transcriptChunks: [liveChunk],
            transcriptRevision: 0,
            speakerNameMappings: ["MIC:candidate": "候选人"]
        )
        let persisted = Meeting(
            id: meetingID,
            title: "原标题",
            transcriptChunks: [accurateChunk],
            transcriptRevision: 1,
            accurateTranscriptReceipts: [receipt(engine: .localQwen3, start: 0, end: 1_000)],
            speakerNameMappings: ["MIC:candidate": "陈彦哲"]
        )

        let merged = stale.mergingForPersistence(
            with: persisted,
            preserveMissingFinalChunks: true
        )

        XCTAssertEqual(merged.title, "后来编辑的标题")
        XCTAssertEqual(merged.transcriptChunks, [accurateChunk])
        XCTAssertEqual(merged.transcriptRevision, 1)
        XCTAssertEqual(merged.latestAccurateTranscriptReceipt?.engine, .localQwen3)
        XCTAssertEqual(merged.speakerNameMappings["MIC:candidate"], "陈彦哲")
    }

    func testLatestReceiptUsesLatestTimelineRangeWhenJobsFinishOutOfOrder() {
        let earlierRangeFinishedLater = receipt(
            engine: .aliyunCloud,
            start: 0,
            end: 1_000,
            completedAt: Date(timeIntervalSince1970: 200)
        )
        let laterRangeFinishedEarlier = receipt(
            engine: .localQwen3,
            start: 1_000,
            end: 2_000,
            completedAt: Date(timeIntervalSince1970: 100)
        )

        let meeting = Meeting(
            accurateTranscriptReceipts: [earlierRangeFinishedLater, laterRangeFinishedEarlier]
        )

        XCTAssertEqual(meeting.latestAccurateTranscriptReceipt?.artifactID, laterRangeFinishedEarlier.artifactID)
    }

    func testLegacyMeetingWithoutProvenanceFieldsDecodesAsSourceUnknown() throws {
        let original = Meeting(
            transcriptChunks: [transcriptChunk(text: "精准字幕", source: .mic, start: 0, end: 1_000)],
            transcriptRevision: 1,
            accurateTranscriptReceipts: [receipt(engine: .aliyunCloud, start: 0, end: 1_000)]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(original)) as? [String: Any]
        )
        object.removeValue(forKey: "accurateTranscriptReceipts")
        object.removeValue(forKey: "transcriptRevision")
        object.removeValue(forKey: "transcriptionProvenanceVersion")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(Meeting.self, from: legacyData)

        XCTAssertTrue(decoded.accurateTranscriptReceipts.isEmpty)
        XCTAssertEqual(decoded.transcriptRevision, 0)
        XCTAssertEqual(decoded.transcriptionProvenanceVersion, 0)
    }

    func testCurrentMeetingPersistsLocalLiveProvenanceMarkerWithoutReceipt() throws {
        let original = Meeting(
            transcriptChunks: [transcriptChunk(text: "实时字幕", source: .mic, start: 0, end: 1_000)]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(Meeting.self, from: encoder.encode(original))

        XCTAssertTrue(decoded.accurateTranscriptReceipts.isEmpty)
        XCTAssertEqual(decoded.transcriptionProvenanceVersion, 1)
    }

    func testReceiptJournalIsNotTruncatedWhileRecordingArtifactsMayRemain() {
        let receipts = (0..<300).map { index in
            receipt(
                engine: index.isMultiple(of: 2) ? .aliyunCloud : .localQwen3,
                start: index * 1_000,
                end: (index + 1) * 1_000
            )
        }

        let meeting = Meeting(accurateTranscriptReceipts: receipts)

        XCTAssertEqual(meeting.accurateTranscriptReceipts.count, 300)
        XCTAssertEqual(
            meeting.latestAccurateTranscriptReceipt?.replacementStartMilliseconds,
            299_000
        )
    }

    private func transcriptChunk(
        text: String,
        source: AudioSource,
        start: Int,
        end: Int
    ) -> TranscriptChunk {
        TranscriptChunk(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            source: source,
            text: text,
            isFinal: true,
            speakerTag: source == .mic ? "candidate" : "interviewer",
            startTime: start,
            endTime: end
        )
    }

    private func receipt(
        engine: AccurateTranscriptionEngine,
        start: Int,
        end: Int,
        completedAt: Date = Date(timeIntervalSince1970: 1_700_000_100)
    ) -> AccurateTranscriptReceipt {
        AccurateTranscriptReceipt(
            artifactID: UUID(),
            recordingSessionID: UUID(),
            engine: engine,
            modelName: engine == .aliyunCloud
                ? "qwen-audio-3.0-asr-flash-filetrans"
                : "Qwen3-ASR-0.6B INT8",
            replacementStartMilliseconds: start,
            replacementEndMilliseconds: end,
            completedAt: completedAt
        )
    }
}
