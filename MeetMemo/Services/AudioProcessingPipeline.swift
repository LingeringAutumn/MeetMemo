@preconcurrency import AVFoundation
import Foundation

final class AudioProcessingPipeline: @unchecked Sendable {
    typealias AudioDataHandler = @Sendable (Data, AudioSource) -> Void
    typealias AudioLevelHandler = @Sendable (Float, AudioSource) -> Void

    private let source: AudioSource
    private let inputFormat: AVAudioFormat
    private let targetFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private let onAudioData: AudioDataHandler
    private let onAudioLevel: AudioLevelHandler
    private let queue: DispatchQueue
    private let stateLock = NSLock()
    private let pendingWork = DispatchGroup()
    private let maxPendingBuffers: Int

    private var pendingBuffers = 0
    private var droppedBuffers = 0
    private var pendingSilenceFrames = 0
    private var isAcceptingAudio = true
    private var isDraining = false
    private var isStopped = false
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []

    init?(
        source: AudioSource,
        inputFormat: AVAudioFormat,
        targetFormat: AVAudioFormat,
        maxPendingBuffers: Int = 96,
        onAudioData: @escaping AudioDataHandler,
        onAudioLevel: @escaping AudioLevelHandler
    ) {
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            return nil
        }

        self.source = source
        self.inputFormat = inputFormat
        self.targetFormat = targetFormat
        self.converter = converter
        self.onAudioData = onAudioData
        self.onAudioLevel = onAudioLevel
        self.maxPendingBuffers = maxPendingBuffers
        self.queue = DispatchQueue(label: "io.meetmemo.audio.pipeline.\(source.rawValue)", qos: .userInitiated)
    }

    func enqueue(_ buffer: AVAudioPCMBuffer) {
        let outputFramesForBuffer = convertedFrameCount(for: buffer)
        let leadingSilenceFrames: Int? = stateLock.withLock {
            guard isAcceptingAudio, !isStopped else { return nil }
            guard pendingBuffers < maxPendingBuffers else {
                droppedBuffers += 1
                pendingSilenceFrames += outputFramesForBuffer
                if droppedBuffers == 1 || droppedBuffers % 50 == 0 {
                    print("⚠️ Dropped \(droppedBuffers) \(source.rawValue) audio buffers because the processing queue is backlogged.")
                }
                return nil
            }

            pendingBuffers += 1
            pendingWork.enter()
            let frames = pendingSilenceFrames
            pendingSilenceFrames = 0
            return frames
        }

        guard let leadingSilenceFrames else { return }
        guard let copiedBuffer = Self.copyBuffer(buffer, format: inputFormat) else {
            stateLock.withLock {
                pendingSilenceFrames += leadingSilenceFrames + outputFramesForBuffer
            }
            releasePendingBuffer()
            return
        }

        queue.async { [self] in
            defer {
                releasePendingBuffer()
            }

            guard stateLock.withLock({
                !isStopped
            }) else { return }
            process(copiedBuffer, leadingSilenceFrames: leadingSilenceFrames)
        }
    }

    func stop() {
        stateLock.withLock {
            isAcceptingAudio = false
            isStopped = true
        }
    }

    /// Stops accepting new buffers, lets every already-reserved buffer finish in FIFO order,
    /// then resumes on the main queue. AudioManager delivers pipeline callbacks on that same
    /// queue, so returning from this method is also a delivery barrier for `sendAudioData`.
    func drainAndStop() async {
        await withCheckedContinuation { continuation in
            let drainAction: (resumeImmediately: Bool, beginDrain: Bool) = stateLock.withLock {
                if isStopped {
                    return (true, false)
                }

                drainWaiters.append(continuation)
                guard !isDraining else { return (false, false) }
                isAcceptingAudio = false
                isDraining = true
                return (false, true)
            }

            if drainAction.resumeImmediately {
                continuation.resume()
                return
            }
            guard drainAction.beginDrain else { return }

            pendingWork.notify(queue: queue) { [self] in
                let trailingSilenceFrames: Int = stateLock.withLock {
                    let frames = pendingSilenceFrames
                    pendingSilenceFrames = 0
                    return frames
                }
                flushConverterTail()
                emitSilence(frameCount: trailingSilenceFrames)
                let waiters: [CheckedContinuation<Void, Never>] = stateLock.withLock {
                    isStopped = true
                    isDraining = false
                    let waiters = drainWaiters
                    drainWaiters.removeAll(keepingCapacity: false)
                    return waiters
                }
                DispatchQueue.main.async {
                    waiters.forEach { $0.resume() }
                }
            }
        }
    }

    private func process(_ buffer: AVAudioPCMBuffer, leadingSilenceFrames: Int) {
        emitSilence(frameCount: leadingSilenceFrames)

        let rms = Self.rmsLevel(in: buffer)
        onAudioLevel(rms, source)

        let expectedOutputFrames = convertedFrameCount(for: buffer)
        let outputFrameCapacity = AVAudioFrameCount(max(1, expectedOutputFrames)) + 32
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCapacity) else {
            emitSilence(frameCount: expectedOutputFrames)
            return
        }

        var error: NSError?
        let converterInput = OneShotConverterInput(buffer: buffer)
        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            converterInput.next(status: outStatus)
        }

        guard error == nil,
              status == .haveData || status == .inputRanDry || status == .endOfStream else {
            emitSilence(frameCount: expectedOutputFrames)
            return
        }

        guard let channelData = outputBuffer.int16ChannelData?[0] else {
            emitSilence(frameCount: expectedOutputFrames)
            return
        }

        let frameCount = Int(outputBuffer.frameLength)
        guard frameCount > 0 else {
            emitSilence(frameCount: expectedOutputFrames)
            return
        }

        onAudioData(Data(bytes: channelData, count: frameCount * 2), source)
    }

    /// AVAudioConverter may retain a few resampled frames after the last input buffer. Signal
    /// end-of-stream on the same serial queue and forward every remaining frame before the STT
    /// provider receives sendLastAudio().
    private func flushConverterTail() {
        let maximumFlushIterations = 16
        for _ in 0..<maximumFlushIterations {
            let capacity = AVAudioFrameCount(max(256, Int(targetFormat.sampleRate / 10)))
            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: capacity
            ) else { return }

            var error: NSError?
            let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .endOfStream
                return nil
            }

            if let channelData = outputBuffer.int16ChannelData?[0], outputBuffer.frameLength > 0 {
                onAudioData(
                    Data(bytes: channelData, count: Int(outputBuffer.frameLength) * MemoryLayout<Int16>.size),
                    source
                )
            }

            if error != nil || status == .endOfStream || outputBuffer.frameLength == 0 {
                return
            }
        }
    }

    private func convertedFrameCount(for buffer: AVAudioPCMBuffer) -> Int {
        guard buffer.format.sampleRate > 0 else { return Int(buffer.frameLength) }
        return max(0, Int((Double(buffer.frameLength) * targetFormat.sampleRate / buffer.format.sampleRate).rounded()))
    }

    private func emitSilence(frameCount: Int) {
        guard frameCount > 0 else { return }
        let framesPerChunk = max(1, Int(targetFormat.sampleRate))
        var remainingFrames = frameCount
        while remainingFrames > 0 {
            let chunkFrames = min(remainingFrames, framesPerChunk)
            onAudioData(Data(repeating: 0, count: chunkFrames * MemoryLayout<Int16>.size), source)
            remainingFrames -= chunkFrames
        }
    }

    private static func copyBuffer(_ buffer: AVAudioPCMBuffer, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0,
              let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength) else {
            return nil
        }

        copy.frameLength = buffer.frameLength

        let sourceBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard sourceBuffers.count == destinationBuffers.count else { return nil }

        for index in 0..<sourceBuffers.count {
            let sourceBuffer = sourceBuffers[index]
            var destinationBuffer = destinationBuffers[index]
            guard let sourceData = sourceBuffer.mData,
                  let destinationData = destinationBuffer.mData else {
                return nil
            }

            let bytesToCopy = min(Int(sourceBuffer.mDataByteSize), Int(destinationBuffer.mDataByteSize))
            memcpy(destinationData, sourceData, bytesToCopy)
            destinationBuffer.mDataByteSize = UInt32(bytesToCopy)
            destinationBuffers[index] = destinationBuffer
        }

        return copy
    }

    private func releasePendingBuffer() {
        stateLock.withLock {
            pendingBuffers = max(0, pendingBuffers - 1)
        }
        pendingWork.leave()
    }

    private static func rmsLevel(in buffer: AVAudioPCMBuffer) -> Float {
        guard buffer.frameLength > 0 else {
            return 0
        }

        let audioBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        var sumOfSquares = 0.0
        var sampleCount = 0

        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            accumulateSamples(in: audioBuffers, as: Float.self, sumOfSquares: &sumOfSquares, sampleCount: &sampleCount) {
                Double($0)
            }
        case .pcmFormatFloat64:
            accumulateSamples(in: audioBuffers, as: Double.self, sumOfSquares: &sumOfSquares, sampleCount: &sampleCount) {
                $0
            }
        case .pcmFormatInt16:
            accumulateSamples(in: audioBuffers, as: Int16.self, sumOfSquares: &sumOfSquares, sampleCount: &sampleCount) {
                Double($0) / Double(Int16.max)
            }
        case .pcmFormatInt32:
            accumulateSamples(in: audioBuffers, as: Int32.self, sumOfSquares: &sumOfSquares, sampleCount: &sampleCount) {
                Double($0) / Double(Int32.max)
            }
        default:
            return 0
        }

        guard sampleCount > 0 else { return 0 }
        return Float(sqrt(sumOfSquares / Double(sampleCount)))
    }

    private static func accumulateSamples<T>(
        in audioBuffers: UnsafeMutableAudioBufferListPointer,
        as sampleType: T.Type,
        sumOfSquares: inout Double,
        sampleCount: inout Int,
        normalize: (T) -> Double
    ) {
        for audioBuffer in audioBuffers {
            guard let data = audioBuffer.mData else { continue }
            let samples = Int(audioBuffer.mDataByteSize) / MemoryLayout<T>.size
            let typedData = data.assumingMemoryBound(to: T.self)
            for index in 0..<samples {
                let sample = normalize(typedData[index])
                sumOfSquares += sample * sample
            }
            sampleCount += samples
        }
    }

    /// AVAudioConverter's input closure is conservatively modeled as concurrently callable.
    /// Keep one-shot state behind a lock instead of capturing and mutating a local Bool.
    private final class OneShotConverterInput: @unchecked Sendable {
        private let lock = NSLock()
        private let buffer: AVAudioPCMBuffer
        private var didProvideInput = false

        init(buffer: AVAudioPCMBuffer) {
            self.buffer = buffer
        }

        func next(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
            lock.withLock {
                guard !didProvideInput else {
                    status.pointee = .noDataNow
                    return nil
                }
                didProvideInput = true
                status.pointee = .haveData
                return buffer
            }
        }
    }
}
