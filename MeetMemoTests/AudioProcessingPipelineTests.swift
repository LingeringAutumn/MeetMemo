import AVFoundation
import XCTest
@testable import MeetMemo

final class AudioProcessingPipelineTests: XCTestCase {
    func testInterleavedInt16BufferIsCopiedAndConverted() throws {
        let inputFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        ))
        let outputFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))
        let inputBuffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 4))
        inputBuffer.frameLength = 4

        let audioBuffers = UnsafeMutableAudioBufferListPointer(inputBuffer.mutableAudioBufferList)
        let samples = try XCTUnwrap(audioBuffers.first?.mData?.assumingMemoryBound(to: Int16.self))
        samples[0] = 1_000
        samples[1] = -1_000
        samples[2] = 2_000
        samples[3] = -2_000

        let receivedAudio = expectation(description: "pipeline emits converted audio")
        let receivedLevel = expectation(description: "pipeline emits an audio level")
        let output = CapturedPipelineOutput()

        let pipeline = try XCTUnwrap(AudioProcessingPipeline(
            source: .mic,
            inputFormat: inputFormat,
            targetFormat: outputFormat,
            onAudioData: { data, _ in
                output.setData(data)
                receivedAudio.fulfill()
            },
            onAudioLevel: { level, _ in
                output.setLevel(level)
                receivedLevel.fulfill()
            }
        ))

        pipeline.enqueue(inputBuffer)

        wait(for: [receivedAudio, receivedLevel], timeout: 1)
        XCTAssertEqual(output.data.count, 8)
        XCTAssertGreaterThan(output.level, 0)
    }

    func testBackloggedPipelineDropsBeforeProcessing() throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))
        let inputBuffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        inputBuffer.frameLength = 4
        inputBuffer.floatChannelData?[0][0] = 0.5

        let unexpectedAudio = expectation(description: "backlogged pipeline does not emit audio")
        unexpectedAudio.isInverted = true

        let pipeline = try XCTUnwrap(AudioProcessingPipeline(
            source: .system,
            inputFormat: format,
            targetFormat: format,
            maxPendingBuffers: 0,
            onAudioData: { _, _ in unexpectedAudio.fulfill() },
            onAudioLevel: { _, _ in }
        ))

        pipeline.enqueue(inputBuffer)

        wait(for: [unexpectedAudio], timeout: 0.2)
    }

    func testSilentSystemBufferIsForwardedWithoutCompressingTimeline() async throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))
        let inputBuffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 320))
        inputBuffer.frameLength = 320
        memset(inputBuffer.int16ChannelData?[0], 0, 320 * MemoryLayout<Int16>.size)

        let output = CapturedPipelineOutput()
        let pipeline = try XCTUnwrap(AudioProcessingPipeline(
            source: .system,
            inputFormat: format,
            targetFormat: format,
            onAudioData: { data, _ in output.appendData(data) },
            onAudioLevel: { level, _ in output.setLevel(level) }
        ))

        pipeline.enqueue(inputBuffer)
        await pipeline.drainAndStop()

        XCTAssertEqual(output.data.count, 640)
        XCTAssertEqual(output.level, 0, accuracy: 0.000_001)
    }

    func testDrainAndStopDeliversEveryReservedBufferBeforeReturning() async throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))
        let inputBuffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160))
        inputBuffer.frameLength = 160
        inputBuffer.int16ChannelData?[0][0] = 1_000

        let output = CapturedPipelineOutput()
        let pipeline = try XCTUnwrap(AudioProcessingPipeline(
            source: .mic,
            inputFormat: format,
            targetFormat: format,
            onAudioData: { data, _ in output.appendData(data) },
            onAudioLevel: { _, _ in }
        ))

        pipeline.enqueue(inputBuffer)
        pipeline.enqueue(inputBuffer)
        await pipeline.drainAndStop()

        XCTAssertEqual(output.data.count, 640)
    }

    func testConcurrentDrainCallersWaitForTheSameFlushBarrier() async throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))
        let inputBuffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160))
        inputBuffer.frameLength = 160

        let processingStarted = expectation(description: "pipeline callback started")
        let releaseProcessing = DispatchSemaphore(value: 0)
        let output = CapturedPipelineOutput()
        let pipeline = try XCTUnwrap(AudioProcessingPipeline(
            source: .mic,
            inputFormat: format,
            targetFormat: format,
            onAudioData: { data, _ in
                processingStarted.fulfill()
                _ = releaseProcessing.wait(timeout: .now() + 1)
                output.appendData(data)
            },
            onAudioLevel: { _, _ in }
        ))

        pipeline.enqueue(inputBuffer)
        await fulfillment(of: [processingStarted], timeout: 1)

        let firstDrain = Task { await pipeline.drainAndStop() }
        let secondDrain = Task { await pipeline.drainAndStop() }
        releaseProcessing.signal()

        await firstDrain.value
        await secondDrain.value
        XCTAssertEqual(output.data.count, 320)
    }

    func testDrainFlushesResamplerTailFrames() async throws {
        let inputFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ))
        let outputFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))
        let inputBuffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 1_024))
        inputBuffer.frameLength = 1_024
        for index in 0..<Int(inputBuffer.frameLength) {
            inputBuffer.floatChannelData?[0][index] = 0.25
        }

        let output = CapturedPipelineOutput()
        let pipeline = try XCTUnwrap(AudioProcessingPipeline(
            source: .system,
            inputFormat: inputFormat,
            targetFormat: outputFormat,
            onAudioData: { data, _ in output.appendData(data) },
            onAudioLevel: { _, _ in }
        ))

        pipeline.enqueue(inputBuffer)
        await pipeline.drainAndStop()

        let outputFrameCount = output.data.count / MemoryLayout<Int16>.size
        XCTAssertTrue((340...342).contains(outputFrameCount), "Unexpected resampled frame count: \(outputFrameCount)")
    }

    func testBackpressureReplacesDroppedAudioWithEqualDurationSilence() async throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))
        let inputBuffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 320))
        inputBuffer.frameLength = 320
        inputBuffer.int16ChannelData?[0][0] = 2_000

        let output = CapturedPipelineOutput()
        let pipeline = try XCTUnwrap(AudioProcessingPipeline(
            source: .system,
            inputFormat: format,
            targetFormat: format,
            maxPendingBuffers: 0,
            onAudioData: { data, _ in output.appendData(data) },
            onAudioLevel: { _, _ in }
        ))

        pipeline.enqueue(inputBuffer)
        await pipeline.drainAndStop()

        XCTAssertEqual(output.data, Data(repeating: 0, count: 640))
    }
}

private final class CapturedPipelineOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var capturedData = Data()
    private var capturedLevel: Float = 0

    var data: Data {
        lock.withLock { capturedData }
    }

    var level: Float {
        lock.withLock { capturedLevel }
    }

    func setData(_ data: Data) {
        lock.withLock {
            capturedData = data
        }
    }

    func appendData(_ data: Data) {
        lock.withLock {
            capturedData.append(data)
        }
    }

    func setLevel(_ level: Float) {
        lock.withLock {
            capturedLevel = level
        }
    }
}
