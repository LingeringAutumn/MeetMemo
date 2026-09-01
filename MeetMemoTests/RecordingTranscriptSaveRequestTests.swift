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
}
