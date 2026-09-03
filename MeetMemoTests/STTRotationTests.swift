import XCTest
@testable import MeetMemo

final class STTRotationTests: XCTestCase {
    func testTranscriptUpdateTimeOffsetKeepsProviderStreamsOnMeetingTimeline() {
        let update = STTTranscriptUpdate(
            text: "second segment",
            isFinal: true,
            speakerTag: "speaker A",
            speakerId: 1,
            startTime: 1_000,
            endTime: 2_500
        )

        let shifted = AudioManager.offsetTranscriptUpdate(update, by: 25 * 60 * 1000)

        XCTAssertEqual(shifted.text, update.text)
        XCTAssertEqual(shifted.isFinal, update.isFinal)
        XCTAssertEqual(shifted.speakerTag, update.speakerTag)
        XCTAssertEqual(shifted.speakerId, update.speakerId)
        XCTAssertEqual(shifted.startTime, 1_501_000)
        XCTAssertEqual(shifted.endTime, 1_502_500)
    }

    func testTranscriptUpdateTimeOffsetLeavesMissingTimesUnchanged() {
        let update = STTTranscriptUpdate(
            text: "untimed",
            isFinal: false,
            speakerTag: nil,
            speakerId: nil,
            startTime: nil,
            endTime: nil
        )

        let shifted = AudioManager.offsetTranscriptUpdate(update, by: 25 * 60 * 1000)

        XCTAssertNil(shifted.startTime)
        XCTAssertNil(shifted.endTime)
    }

    func testMaximumTranscriptEndTimeUsesExistingMeetingTimeline() {
        let chunks = [
            TranscriptChunk(source: .mic, text: "first", isFinal: true, startTime: 1_000, endTime: 2_000),
            TranscriptChunk(source: .system, text: "second", isFinal: true, startTime: 4_000, endTime: nil),
            TranscriptChunk(source: .mic, text: "third", isFinal: true, startTime: 5_000, endTime: 8_500)
        ]

        XCTAssertEqual(AudioManager.maximumTranscriptEndTime(in: chunks), 8_500)
    }

    func testMaximumTranscriptEndTimeDoesNotRegressForMalformedOrNegativeBounds() {
        let chunks = [
            TranscriptChunk(
                source: .mic,
                text: "reversed",
                isFinal: true,
                startTime: 9_000,
                endTime: 1_000
            ),
            TranscriptChunk(
                source: .system,
                text: "negative",
                isFinal: true,
                startTime: -5_000,
                endTime: -1
            )
        ]

        XCTAssertEqual(AudioManager.maximumTranscriptEndTime(in: chunks), 9_000)
    }

    func testPersistedMeetingTimelineEndIncludesAccurateRecordingReceipt() {
        let meeting = Meeting(
            transcriptChunks: [
                TranscriptChunk(
                    source: .mic,
                    text: "loaded transcript",
                    isFinal: true,
                    startTime: 1_000,
                    endTime: 12_000
                )
            ],
            accurateTranscriptReceipts: [
                AccurateTranscriptReceipt(
                    artifactID: UUID(),
                    recordingSessionID: UUID(),
                    engine: .localQwen3,
                    modelName: "test-model",
                    replacementStartMilliseconds: 0,
                    replacementEndMilliseconds: 45_000
                )
            ]
        )

        XCTAssertEqual(
            AudioManager.maximumPersistedMeetingTimelineEnd(in: meeting),
            45_000
        )
        XCTAssertEqual(AudioManager.maximumPersistedMeetingTimelineEnd(in: nil), 0)
    }

    func testTranscriptUpdateTimeOffsetLeavesZeroOffsetUnchanged() {
        let update = STTTranscriptUpdate(
            text: "unchanged",
            isFinal: true,
            speakerTag: nil,
            speakerId: nil,
            startTime: 1_000,
            endTime: 2_000
        )

        XCTAssertEqual(AudioManager.offsetTranscriptUpdate(update, by: 0), update)
    }
}
