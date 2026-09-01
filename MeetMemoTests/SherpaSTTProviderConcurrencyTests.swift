import Foundation
import XCTest
@testable import MeetMemo

final class SherpaSTTProviderConcurrencyTests: XCTestCase {
    func testSessionGateRejectsWorkFromSupersededGeneration() {
        let gate = SherpaSessionGate()
        var resetGenerations: [UInt64] = []

        let first = gate.beginSession { resetGenerations.append($0) }
        XCTAssertTrue(gate.activateIfCurrent(first) {})
        XCTAssertTrue(gate.submitAudio { XCTAssertEqual($0, first) })

        let second = gate.beginSession { resetGenerations.append($0) }

        XCTAssertFalse(gate.isCurrent(first))
        XCTAssertTrue(gate.isCurrent(second))
        XCTAssertFalse(gate.submitIfCurrent(first) {
            XCTFail("Superseded work must not be submitted")
        })
        XCTAssertFalse(gate.submitAudio { _ in
            XCTFail("Audio must stay closed until the new runtime is installed")
        })
        XCTAssertEqual(resetGenerations, [first, second])
    }

    func testSessionGateFinalMarkerClosesAudioExactlyOnce() {
        let gate = SherpaSessionGate()
        let generation = gate.beginSession { _ in }
        XCTAssertTrue(gate.activateIfCurrent(generation) {})

        var submittedFinalGeneration: UInt64?
        XCTAssertTrue(gate.submitFinal { submittedFinalGeneration = $0 })
        XCTAssertEqual(submittedFinalGeneration, generation)
        XCTAssertFalse(gate.submitAudio { _ in
            XCTFail("Audio submitted after the final marker")
        })
        XCTAssertFalse(gate.submitFinal { _ in
            XCTFail("A duplicate final marker was submitted")
        })
        XCTAssertTrue(gate.submitBarrier { XCTAssertEqual($0, generation) })
    }

    func testSessionGateInvalidationDoesNotRetireNewerSession() {
        let gate = SherpaSessionGate()
        let first = gate.beginSession { _ in }
        let second = gate.beginSession { _ in }

        XCTAssertFalse(gate.invalidateIfCurrent(first) {
            XCTFail("A stale connect attempt must not reset the current session")
        })
        XCTAssertTrue(gate.isCurrent(second))
    }

    func testFinalizationWaitCompletesWhenMarkerRuns() async {
        let queue = DispatchQueue(label: "io.meetmemo.tests.sherpa.finalization.fast")

        let status = await SherpaSTTProvider.waitForFinalization(timeout: 1) { completion in
            queue.async(execute: completion)
            return true
        }

        XCTAssertEqual(status, .completed)
    }

    func testFinalizationTimeoutDoesNotWaitForBlockedMarker() async {
        let queue = DispatchQueue(label: "io.meetmemo.tests.sherpa.finalization.blocked")
        let releaseQueue = DispatchSemaphore(value: 0)
        let lateMarkerRan = expectation(description: "late marker becomes a no-op")

        queue.async {
            _ = releaseQueue.wait(timeout: .now() + 2)
        }
        // Safety release prevents a failed implementation from hanging the test process.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.5) {
            releaseQueue.signal()
        }

        let startedAt = Date()
        let status = await SherpaSTTProvider.waitForFinalization(timeout: 0.05) { completion in
            queue.async {
                completion()
                lateMarkerRan.fulfill()
            }
            return true
        }
        let elapsed = Date().timeIntervalSince(startedAt)

        XCTAssertEqual(status, .finalizeTimedOut)
        XCTAssertLessThan(elapsed, 0.8, "Timeout waited for the losing queue operation")

        releaseQueue.signal()
        await fulfillment(of: [lateMarkerRan], timeout: 2)
    }

    func testFinalizationWaitWithoutActiveSessionCompletesImmediately() async {
        let status = await SherpaSTTProvider.waitForFinalization(timeout: 0) { _ in false }
        XCTAssertEqual(status, .completed)
    }

    func testRingBufferUsesBatchTrimmingSlack() {
        let limit = SherpaSTTProvider.fallbackDecodeSampleLimit
        let slack = SherpaSTTProvider.ringBufferTrimSlackSamples
        let threshold = limit + slack

        XCTAssertEqual(SherpaSTTProvider.ringBufferRemovalCount(forSampleCount: limit), 0)
        XCTAssertEqual(SherpaSTTProvider.ringBufferRemovalCount(forSampleCount: threshold), 0)
        XCTAssertEqual(
            SherpaSTTProvider.ringBufferRemovalCount(forSampleCount: threshold + 1),
            slack + 1
        )
        XCTAssertEqual(
            threshold + 1 - SherpaSTTProvider.ringBufferRemovalCount(forSampleCount: threshold + 1),
            limit
        )
    }
}
