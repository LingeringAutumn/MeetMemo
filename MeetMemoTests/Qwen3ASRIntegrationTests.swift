import XCTest
@testable import MeetMemo

final class Qwen3ASRIntegrationTests: XCTestCase {
    func testQwenManifestUsesVerifiedMainlandMirrorFirst() {
        let files = SherpaModelManager.qwen3ASRCoreModelFiles

        XCTAssertEqual(files.count, 6)
        XCTAssertEqual(Set(files.map(\.fileName)), Set([
            "qwen3-asr/conv_frontend.onnx",
            "qwen3-asr/encoder.int8.onnx",
            "qwen3-asr/decoder.int8.onnx",
            "qwen3-asr/tokenizer/merges.txt",
            "qwen3-asr/tokenizer/tokenizer_config.json",
            "qwen3-asr/tokenizer/vocab.json",
        ]))
        for file in files {
            XCTAssertEqual(file.urls.first?.host, "modelscope.cn")
            XCTAssertEqual(file.sha256?.count, 64)
            XCTAssertGreaterThan(file.approximateBytes, 0)
        }
    }

    func testQwenTrackRequestPreservesRoleAndSharedTimelineOffset() {
        let request = AudioTrackTranscriptionRequest(
            url: URL(fileURLWithPath: "/tmp/system.wav"),
            source: .system,
            timelineOffsetMilliseconds: 1_250,
            hotwords: "KV Cache, TTFT"
        )

        XCTAssertEqual(request.source, .system)
        XCTAssertEqual(request.timelineOffsetMilliseconds, 1_250)
        XCTAssertEqual(request.hotwords, "KV Cache, TTFT")
    }

    func testQwenTrackRequestClampsInvalidNegativeOffset() {
        let request = AudioTrackTranscriptionRequest(
            url: URL(fileURLWithPath: "/tmp/mic.wav"),
            source: .mic,
            timelineOffsetMilliseconds: -500
        )

        XCTAssertEqual(request.timelineOffsetMilliseconds, 0)
    }

    func testQwenProviderConfigCarriesFixedRoleAndPerJobHotwords() {
        let config = STTProviderConfig(
            speakerMode: .fixedByAudioSource,
            hotwords: "PagedAttention\nPrefix Caching"
        )

        XCTAssertEqual(config.speakerMode, .fixedByAudioSource)
        XCTAssertEqual(config.hotwords, "PagedAttention\nPrefix Caching")
    }

    func testLocalQwenHotwordsStayWithinAudioSafeBudgetAndDeduplicate() {
        let terms = ["KV Cache", "kv cache"]
            + (0..<100).map { "VeryLongInterviewTerm\($0)" }

        let hotwords = AliyunPostRecordingTranscriptionService.boundedLocalQwenHotwords(
            from: terms
        )
        let split = hotwords.split(separator: ",").map(String.init)

        XCTAssertLessThanOrEqual(hotwords.count, 160)
        XCTAssertLessThanOrEqual(split.count, 16)
        XCTAssertEqual(split.first, "KV Cache")
        XCTAssertEqual(split.filter { $0.lowercased() == "kv cache" }.count, 1)
    }
}
