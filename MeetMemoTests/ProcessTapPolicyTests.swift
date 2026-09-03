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

        let policy = try? ProcessTap.tapMixPolicy(for: .singleProcess(process))

        XCTAssertEqual(policy, .includeProcesses([404]))
    }

    func testSystemAudioIncludesOnlyExplicitMeetingProcessAllowlist() throws {
        let target = TapTarget.systemAudio(processObjectIDs: [202, 101, 202])

        let policy = try ProcessTap.tapMixPolicy(for: target)

        XCTAssertEqual(policy, .includeProcesses([101, 202]))
    }

    func testSystemAudioRejectsEmptyProcessAllowlist() {
        XCTAssertThrowsError(try ProcessTap.tapMixPolicy(
            for: .systemAudio(processObjectIDs: [])
        )) { error in
            XCTAssertEqual(
                error as? ProcessTap.ConfigurationError,
                .noSupportedMeetingAudioProcess
            )
        }
    }

    func testSystemAudioRejectsUnknownOnlyProcessAllowlist() {
        XCTAssertThrowsError(try ProcessTap.tapMixPolicy(
            for: .systemAudio(processObjectIDs: [.unknown])
        ))
    }

    func testSupportedMeetingBundleIdentifiersAndHelpersAreAccepted() {
        let acceptedBundleIDs = [
            "com.tencent.meeting",
            "com.tencent.meeting.appstore",
            "com.tencent.wemeet",
            "com.tencent.voov",
            "com.electron.lark",
            "com.electron.lark.helper.renderer",
            "com.bytedance.Feishu",
            "com.bytedance.larkAudioPlugin",
            "com.larksuite.suite"
        ]

        for bundleID in acceptedBundleIDs {
            XCTAssertTrue(
                AudioProcessController.isSupportedMeetingProcess(
                    name: "unpublished-helper-name",
                    bundleID: bundleID
                ),
                "Expected \(bundleID) to be accepted"
            )
        }
    }

    func testSupportedMeetingExecutableFallbacksAreAccepted() {
        let acceptedNames = [
            "TencentMeeting",
            "WeMeetApp",
            "VooV Meeting Helper (Renderer)",
            "Feishu",
            "Lark Helper (GPU)",
            "ByteviewAudioDevice",
            "腾讯会议",
            "飞书"
        ]

        for name in acceptedNames {
            XCTAssertTrue(
                AudioProcessController.isSupportedMeetingProcess(name: name, bundleID: nil),
                "Expected \(name) to be accepted"
            )
        }
    }

    func testUnrelatedAudioProcessesAreRejected() {
        let unrelatedProcesses = [
            ("Safari", "com.apple.Safari"),
            ("Spotify", "com.spotify.client"),
            ("WeChat", "com.tencent.xinWeChat"),
            ("Slack Helper", "com.tinyspeck.slackmacgap.helper"),
            ("Meeting Notes", "com.example.meeting-notes"),
            ("Larkspur Player", "com.example.larkspur")
        ]

        for (name, bundleID) in unrelatedProcesses {
            XCTAssertFalse(
                AudioProcessController.isSupportedMeetingProcess(
                    name: name,
                    bundleID: bundleID
                ),
                "Expected \(name) / \(bundleID) to be rejected"
            )
        }
    }

    func testPublishedUnrelatedBundleIdentifierCannotSpoofMeetingExecutableName() {
        XCTAssertFalse(
            AudioProcessController.isSupportedMeetingProcess(
                name: "Feishu",
                bundleID: "com.example.unrelated"
            )
        )
    }

    func testMeetingProcessObjectIDFilterRejectsUnrelatedInvalidAndDuplicateEntries() {
        let processes = [
            makeProcess(name: "Feishu", bundleID: "com.electron.lark", objectID: 44),
            makeProcess(name: "Lark Helper", bundleID: "com.electron.lark.helper", objectID: 44),
            makeProcess(name: "Spotify", bundleID: "com.spotify.client", objectID: 55),
            makeProcess(name: "TencentMeeting", bundleID: nil, objectID: 66),
            makeProcess(name: "VooV", bundleID: nil, objectID: .unknown)
        ]

        XCTAssertEqual(
            AudioProcessController.supportedMeetingProcessObjectIDs(in: processes),
            [44, 66]
        )
    }

    func testRequestedInvalidationDoesNotNotifyFailureHandler() {
        XCTAssertFalse(ProcessTap.InvalidationReason.requested.notifiesHandler)
        XCTAssertTrue(ProcessTap.InvalidationReason.unexpected.notifiesHandler)
    }

    func testTapWatchdogDetectsMissingProcessOrStalledCallbacks() {
        XCTAssertTrue(ProcessTap.watchdogShouldInvalidate(
            nowUptimeNanoseconds: 10,
            lastCallbackUptimeNanoseconds: 9,
            timeoutNanoseconds: 5,
            hasAnyTargetProcess: false
        ))
        XCTAssertTrue(ProcessTap.watchdogShouldInvalidate(
            nowUptimeNanoseconds: 20,
            lastCallbackUptimeNanoseconds: 10,
            timeoutNanoseconds: 5,
            hasAnyTargetProcess: true
        ))
        XCTAssertFalse(ProcessTap.watchdogShouldInvalidate(
            nowUptimeNanoseconds: 14,
            lastCallbackUptimeNanoseconds: 10,
            timeoutNanoseconds: 5,
            hasAnyTargetProcess: true
        ))
    }

    private func makeProcess(
        name: String,
        bundleID: String?,
        objectID: AudioObjectID
    ) -> AudioProcess {
        AudioProcess(
            id: 42,
            kind: .process,
            name: name,
            audioActive: true,
            bundleID: bundleID,
            bundleURL: nil,
            objectID: objectID
        )
    }
}
