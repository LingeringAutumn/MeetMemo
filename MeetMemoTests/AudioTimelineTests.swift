import XCTest
@testable import MeetMemo

final class AudioTimelineTests: XCTestCase {
    func testCatchUpFramesRepresentMissingWallClockAudio() {
        XCTAssertEqual(
            AudioManager.timelineCatchUpFrameCount(
                elapsedMilliseconds: 2_500,
                anchorMilliseconds: 500,
                deliveredFrames: 16_000
            ),
            16_000
        )
    }

    func testCatchUpFramesNeverDuplicateAudioAlreadyDelivered() {
        XCTAssertEqual(
            AudioManager.timelineCatchUpFrameCount(
                elapsedMilliseconds: 1_500,
                anchorMilliseconds: 500,
                deliveredFrames: 16_001
            ),
            0
        )
    }

    func testCatchUpFramesRespectAdvancedAnchorAfterPendingAudioDrop() {
        XCTAssertEqual(
            AudioManager.timelineCatchUpFrameCount(
                elapsedMilliseconds: 20_000,
                anchorMilliseconds: 8_000,
                deliveredFrames: 12 * 16_000
            ),
            0
        )
    }
}
