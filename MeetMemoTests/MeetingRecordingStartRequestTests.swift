import XCTest
@testable import MeetMemo

final class MeetingRecordingStartRequestTests: XCTestCase {
    func testRequestCommitsOnlyForSameMeetingAndGeneration() {
        let meetingID = UUID()
        let request = MeetingRecordingStartRequest(meetingID: meetingID, generation: 4)

        XCTAssertTrue(request.canCommit(
            currentMeetingID: meetingID,
            currentGeneration: 4,
            isDeleted: false,
            activeMeetingID: nil,
            isRecording: false,
            isStopping: false,
            isRecoveringRecordings: false
        ))
        XCTAssertFalse(request.canCommit(
            currentMeetingID: UUID(),
            currentGeneration: 4,
            isDeleted: false,
            activeMeetingID: nil,
            isRecording: false,
            isStopping: false,
            isRecoveringRecordings: false
        ))
        XCTAssertFalse(request.canCommit(
            currentMeetingID: meetingID,
            currentGeneration: 5,
            isDeleted: false,
            activeMeetingID: nil,
            isRecording: false,
            isStopping: false,
            isRecoveringRecordings: false
        ))
    }

    func testRequestRejectsDeletedMeetingOrExistingSession() {
        let meetingID = UUID()
        let request = MeetingRecordingStartRequest(meetingID: meetingID, generation: 1)

        XCTAssertFalse(request.canCommit(
            currentMeetingID: meetingID,
            currentGeneration: 1,
            isDeleted: true,
            activeMeetingID: nil,
            isRecording: false,
            isStopping: false,
            isRecoveringRecordings: false
        ))
        XCTAssertFalse(request.canCommit(
            currentMeetingID: meetingID,
            currentGeneration: 1,
            isDeleted: false,
            activeMeetingID: UUID(),
            isRecording: false,
            isStopping: false,
            isRecoveringRecordings: false
        ))
        XCTAssertFalse(request.canCommit(
            currentMeetingID: meetingID,
            currentGeneration: 1,
            isDeleted: false,
            activeMeetingID: nil,
            isRecording: true,
            isStopping: false,
            isRecoveringRecordings: false
        ))
        XCTAssertFalse(request.canCommit(
            currentMeetingID: meetingID,
            currentGeneration: 1,
            isDeleted: false,
            activeMeetingID: nil,
            isRecording: false,
            isStopping: true,
            isRecoveringRecordings: false
        ))
    }

    func testRequestRejectsCommitUntilInterruptedRecordingRecoveryFinishes() {
        let meetingID = UUID()
        let request = MeetingRecordingStartRequest(meetingID: meetingID, generation: 1)

        XCTAssertFalse(request.canCommit(
            currentMeetingID: meetingID,
            currentGeneration: 1,
            isDeleted: false,
            activeMeetingID: nil,
            isRecording: false,
            isStopping: false,
            isRecoveringRecordings: true
        ))
    }
}
