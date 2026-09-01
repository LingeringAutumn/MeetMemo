import AudioToolbox
import XCTest
@testable import MeetMemo

final class ProcessTapPolicyTests: XCTestCase {
    func testSingleProcessTapStillIncludesOnlyItsSelectedProcess() {
        let process = AudioProcess(
            id: 42,
            kind: .process,
            name: "Test process",
            audioActive: true,
            bundleID: nil,
            bundleURL: nil,
            objectID: 404
        )

        let policy = ProcessTap.tapMixPolicy(
            for: .singleProcess(process),
            currentProcessObjectID: 303
        )

        XCTAssertEqual(policy, .includeProcesses([404]))
    }

    func testSystemAudioUsesGlobalTapAndIgnoresLegacyProcessSnapshot() {
        let target = TapTarget.systemAudio(processObjectIDs: [101, 202])

        let policy = ProcessTap.tapMixPolicy(for: target, currentProcessObjectID: 303)

        XCTAssertEqual(policy, .globalExcludingProcesses([303]))
    }

    func testSystemAudioGlobalTapCanRunWhenCurrentProcessHasNoAudioObject() {
        let target = TapTarget.systemAudio(processObjectIDs: [])

        let policy = ProcessTap.tapMixPolicy(for: target, currentProcessObjectID: nil)

        XCTAssertEqual(policy, .globalExcludingProcesses([]))
    }

    func testUnknownCurrentProcessObjectIsNotAddedToGlobalTapExclusions() {
        let target = TapTarget.systemAudio(processObjectIDs: [101])

        let policy = ProcessTap.tapMixPolicy(for: target, currentProcessObjectID: .unknown)

        XCTAssertEqual(policy, .globalExcludingProcesses([]))
    }

    func testRequestedInvalidationDoesNotNotifyFailureHandler() {
        XCTAssertFalse(ProcessTap.InvalidationReason.requested.notifiesHandler)
        XCTAssertTrue(ProcessTap.InvalidationReason.unexpected.notifiesHandler)
    }
}
