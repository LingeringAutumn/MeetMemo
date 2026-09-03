import XCTest
@testable import MeetMemo

final class ASRTranscriptQualityGateTests: XCTestCase {
    func testRejectsCatastrophicRepeatedPhrase() {
        let text = String(repeating: "那个谁，", count: 80)
        let samples = Array(repeating: Float(0.05), count: 7 * 16_000)

        let result = ASRTranscriptQualityGate.evaluate(text: text, samples: samples)

        XCTAssertEqual(result.rejectionReason, .repeatedPattern)
    }

    func testRejectsNearLoopWithChangingSuffixes() {
        let text = String(repeating: "那个谁啊，那个谁呢，那个谁吧。", count: 8)
        let samples = Array(repeating: Float(0.05), count: 12 * 16_000)

        let result = ASRTranscriptQualityGate.evaluate(text: text, samples: samples)

        XCTAssertEqual(result.rejectionReason, .repeatedPattern)
    }

    func testRejectsImplausibleTextDensityWithoutLiteralLoop() {
        let text = String((0..<180).map { Character(UnicodeScalar(0x4E00 + $0)!) })
        let samples = Array(repeating: Float(0.05), count: 2 * 16_000)

        let result = ASRTranscriptQualityGate.evaluate(text: text, samples: samples)

        XCTAssertEqual(result.rejectionReason, .excessiveTextDensity)
    }

    func testRejectsHallucinationFromSilentPCM() {
        let samples = Array(repeating: Float.zero, count: 16_000)

        let result = ASRTranscriptQualityGate.evaluate(text: "这是一段并不存在的语音", samples: samples)

        XCTAssertEqual(result.rejectionReason, .insufficientAudioEnergy)
    }

    func testAcceptsNormalTechnicalInterviewAnswer() {
        let text = "我通过 Prefix Hash 查找可复用的 KV Cache，并根据传输和重算开销选择执行策略。"
        let samples = Array(repeating: Float(0.04), count: 9 * 16_000)

        XCTAssertEqual(
            ASRTranscriptQualityGate.evaluate(text: text, samples: samples),
            .accepted
        )
    }

    func testAllowsShortConversationalRepetition() {
        let text = "对对对，我明白这个问题。"
        let samples = Array(repeating: Float(0.04), count: 2 * 16_000)

        XCTAssertEqual(
            ASRTranscriptQualityGate.evaluate(text: text, samples: samples),
            .accepted
        )
    }

    func testSequenceGateRejectsThirdAdjacentShortHallucination() {
        var gate = ASRTranscriptSequenceGate()

        XCTAssertFalse(gate.shouldReject(text: "那个谁啊", startSampleOffset: 0, endSampleOffset: 16_000))
        XCTAssertFalse(gate.shouldReject(text: "那个谁呢", startSampleOffset: 20_000, endSampleOffset: 36_000))
        XCTAssertTrue(gate.shouldReject(text: "那个谁吧", startSampleOffset: 40_000, endSampleOffset: 56_000))
    }

    func testSequenceGateAllowsNormalTwoCharacterBackchannels() {
        var gate = ASRTranscriptSequenceGate()

        for index in 0..<5 {
            XCTAssertFalse(gate.shouldReject(
                text: "嗯嗯",
                startSampleOffset: index * 20_000,
                endSampleOffset: index * 20_000 + 16_000
            ))
        }
    }

    func testSequenceGateResetsAcrossLongSilence() {
        var gate = ASRTranscriptSequenceGate()

        XCTAssertFalse(gate.shouldReject(text: "那个谁", startSampleOffset: 0, endSampleOffset: 16_000))
        XCTAssertFalse(gate.shouldReject(text: "那个谁", startSampleOffset: 20_000, endSampleOffset: 36_000))
        XCTAssertFalse(gate.shouldReject(
            text: "那个谁",
            startSampleOffset: 20 * 16_000,
            endSampleOffset: 21 * 16_000
        ))
    }
}
