import XCTest
@testable import MeetMemo

final class RecordingTranscriptSaveRequestTests: XCTestCase {
    func testDebouncedSaveCannotMoveAcrossRecordingSessions() {
        let meetingA = UUID()
        let sessionA = UUID()
        let request = RecordingTranscriptSaveRequest(
            meetingID: meetingA,
            sessionToken: sessionA,
            chunks: []
        )

        XCTAssertTrue(request.belongsTo(meetingID: meetingA, sessionToken: sessionA))
        XCTAssertFalse(request.belongsTo(meetingID: UUID(), sessionToken: sessionA))
        XCTAssertFalse(request.belongsTo(meetingID: meetingA, sessionToken: UUID()))
        XCTAssertFalse(request.belongsTo(meetingID: nil, sessionToken: nil))
    }

    func testPersistedMeetingIsAuthoritativeWhenDetailTranscriptIsStale() {
        let supersededLocal = TranscriptChunk(
            source: .mic,
            text: "superseded local draft",
            isFinal: true,
            startTime: 0,
            endTime: 5_000
        )
        let accurate = TranscriptChunk(
            source: .mic,
            text: "accurate persisted result",
            isFinal: true,
            startTime: 0,
            endTime: 5_000
        )
        let persisted = Meeting(transcriptChunks: [accurate], transcriptRevision: 1)

        XCTAssertEqual(
            RecordingSessionManager.resumableTranscriptChunks(
                inMemory: [supersededLocal],
                persistedMeeting: persisted
            ),
            [accurate]
        )
        XCTAssertEqual(
            RecordingSessionManager.resumableTranscriptChunks(
                inMemory: [supersededLocal],
                persistedMeeting: nil
            ),
            [supersededLocal]
        )
    }
}
