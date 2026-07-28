@preconcurrency import AVFAudio
import CoreMedia
import Foundation
import Speech

// MARK: - Cross-Actor Audio Values

nonisolated struct AudioBufferTransfer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    let bufferStartTime: CMTime?
    let timelineStartUptimeNanoseconds: UInt64?
    let precedingDroppedBufferCount: Int
    let startsNewSourceSegment: Bool

    var durationMilliseconds: Double? {
        let sampleRate = buffer.format.sampleRate
        guard sampleRate.isFinite, sampleRate > 0 else { return nil }
        return Double(buffer.frameLength) / sampleRate * 1_000
    }

    var bufferEndTime: CMTime? {
        guard let bufferStartTime,
            bufferStartTime.isNumeric,
            buffer.format.sampleRate.isFinite,
            buffer.format.sampleRate > 0,
            buffer.format.sampleRate <= Double(Int32.max)
        else {
            return nil
        }
        let duration = CMTime(
            value: CMTimeValue(buffer.frameLength),
            timescale: CMTimeScale(buffer.format.sampleRate.rounded())
        )
        return CMTimeAdd(bufferStartTime, duration)
    }

    var bufferStartUptimeNanoseconds: UInt64? {
        uptimeNanoseconds(for: bufferStartTime)
    }

    func analyzerTimelineOriginUptimeNanoseconds(
        for analyzerStartTime: CMTime
    ) -> UInt64? {
        guard let bufferStartUptimeNanoseconds else { return nil }
        let seconds = analyzerStartTime.seconds
        guard seconds.isFinite, seconds >= 0 else { return nil }
        let offset = seconds * 1_000_000_000
        guard offset <= Double(bufferStartUptimeNanoseconds) else { return nil }
        return bufferStartUptimeNanoseconds - UInt64(offset)
    }

    func ageNanoseconds(at uptimeNanoseconds: UInt64) -> UInt64? {
        let sampleRate = buffer.format.sampleRate
        guard sampleRate.isFinite, sampleRate > 0 else { return nil }
        guard let bufferStartUptimeNanoseconds else { return nil }
        let duration = Double(buffer.frameLength) / sampleRate * 1_000_000_000
        guard duration.isFinite,
            duration >= 0,
            duration <= Double(UInt64.max - bufferStartUptimeNanoseconds)
        else {
            return nil
        }
        let audioEndUptimeNanoseconds =
            bufferStartUptimeNanoseconds + UInt64(duration)
        guard uptimeNanoseconds >= audioEndUptimeNanoseconds else { return 0 }
        return uptimeNanoseconds - audioEndUptimeNanoseconds
    }

    private func uptimeNanoseconds(for time: CMTime?) -> UInt64? {
        guard let timelineStartUptimeNanoseconds,
            let time,
            time.isNumeric
        else {
            return nil
        }
        let seconds = time.seconds
        guard seconds.isFinite, seconds >= 0 else { return nil }
        let offset = seconds * 1_000_000_000
        guard offset <= Double(UInt64.max - timelineStartUptimeNanoseconds) else {
            return nil
        }
        return timelineStartUptimeNanoseconds + UInt64(offset)
    }
}

nonisolated struct AudioFormatTransfer: @unchecked Sendable {
    let format: AVAudioFormat
}

nonisolated struct ConvertedAnalyzerInput: @unchecked Sendable {
    let input: AnalyzerInput
    let startTime: CMTime?
    let endTime: CMTime?
}

// MARK: - Real-Time Audio Tap

nonisolated func makeAudioTapBlock(
    continuation: AsyncStream<AudioBufferTransfer>.Continuation,
    timeline: SpeechAudioTimeline
) -> AVAudioNodeTapBlock {
    return { buffer, time in
        // Core Audio invokes taps on its real-time queue. Constructing this
        // block outside MainActor isolation prevents Swift 6 from asserting
        // that the callback must execute on the main dispatch queue.
        let timing = timeline.timing(for: time, buffer: buffer)
        guard let ownedBuffer = buffer.copy() as? AVAudioPCMBuffer else {
            timeline.droppedBufferCount += 1
            return
        }
        let transfer = AudioBufferTransfer(
            buffer: ownedBuffer,
            bufferStartTime: timing.bufferStartTime,
            timelineStartUptimeNanoseconds: timing.timelineStartUptimeNanoseconds,
            precedingDroppedBufferCount: timeline.droppedBufferCount,
            startsNewSourceSegment: timing.startsNewSourceSegment
        )
        if case .dropped = continuation.yield(transfer) {
            // AVAudioEngine serializes callbacks for a tap. Reporting the
            // cumulative value on the next retained buffer keeps logging and
            // task creation off the real-time audio queue.
            timeline.droppedBufferCount += 1
        }
    }
}

// MARK: - Format Conversion

nonisolated private final class ConverterInputState: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var suppliedInput = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}

actor AudioBufferConverter {
    private static let maximumConversionPasses = 64

    private var converter: AVAudioConverter?
    private var analyzerClock = SpeechAnalyzerInputClock()
    private var expectedInputStartTime: CMTime?
    private var observedDroppedBufferCount = 0

    func beginCaptureSession() {
        clearConverterState()
        analyzerClock.beginCaptureSession()
    }

    func endCaptureSession() {
        clearConverterState()
    }

    func resetAfterInputDiscontinuity() {
        clearConverterState()
    }

    func convert(
        _ transfer: AudioBufferTransfer,
        to outputTransfer: AudioFormatTransfer
    ) throws -> [ConvertedAnalyzerInput] {
        let input = transfer.buffer
        let outputFormat = outputTransfer.format
        guard input.frameLength > 0 else { return [] }

        if input.format == outputFormat {
            clearConverterState()
            analyzerClock.prepareForInput(
                proposedStartTime: transfer.bufferStartTime
            )
            return [
                analyzerInput(
                    for: input,
                    fallbackStartTime: transfer.bufferStartTime
                )
            ]
        }

        if converter?.inputFormat != input.format || converter?.outputFormat != outputFormat {
            guard let newConverter = AVAudioConverter(from: input.format, to: outputFormat) else {
                throw SpeechServiceError.audioConversionUnavailable
            }
            // Ctrl-Say is a live command recognizer. Latency-mode priming avoids
            // waiting for read-ahead frames at the beginning of each session.
            newConverter.primeMethod = .none
            converter = newConverter
            expectedInputStartTime = nil
            observedDroppedBufferCount = transfer.precedingDroppedBufferCount
            analyzerClock.prepareForInput(
                proposedStartTime: transfer.bufferStartTime
            )
        }

        guard let converter else {
            throw SpeechServiceError.audioConversionUnavailable
        }

        if inputTimelineIsDiscontinuous(transfer, sampleRate: input.format.sampleRate) {
            converter.reset()
            analyzerClock.prepareForInput(
                proposedStartTime: transfer.bufferStartTime
            )
        }
        observedDroppedBufferCount = transfer.precedingDroppedBufferCount

        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity =
            AVAudioFrameCount(
                (Double(input.frameLength) * ratio).rounded(.up)
            ) + 32
        let inputState = ConverterInputState(buffer: input)
        var analyzerInputs: [ConvertedAnalyzerInput] = []

        for _ in 0..<Self.maximumConversionPasses {
            guard
                let output = AVAudioPCMBuffer(
                    pcmFormat: outputFormat,
                    frameCapacity: capacity
                )
            else {
                throw SpeechServiceError.audioConversionUnavailable
            }
            var conversionError: NSError?
            let status = converter.convert(
                to: output,
                error: &conversionError
            ) { _, inputStatus in
                if inputState.suppliedInput {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                inputState.suppliedInput = true
                inputStatus.pointee = .haveData
                return inputState.buffer
            }

            if let conversionError { throw conversionError }
            if output.frameLength > 0 {
                analyzerInputs.append(
                    analyzerInput(
                        for: output,
                        fallbackStartTime: transfer.bufferStartTime
                    )
                )
            }

            switch status {
            case .inputRanDry, .endOfStream:
                guard inputState.suppliedInput else {
                    throw SpeechServiceError.audioConversionFailed
                }
                expectedInputStartTime = transfer.bufferEndTime
                return analyzerInputs
            case .haveData:
                guard output.frameLength > 0 else {
                    throw SpeechServiceError.audioConversionFailed
                }
            case .error:
                throw SpeechServiceError.audioConversionFailed
            @unknown default:
                throw SpeechServiceError.audioConversionFailed
            }
        }

        throw SpeechServiceError.audioConversionFailed
    }

    func reset() {
        clearConverterState()
        analyzerClock.reset()
    }

    private func clearConverterState() {
        converter?.reset()
        converter = nil
        expectedInputStartTime = nil
        observedDroppedBufferCount = 0
    }

    private func inputTimelineIsDiscontinuous(
        _ transfer: AudioBufferTransfer,
        sampleRate: Double
    ) -> Bool {
        if transfer.startsNewSourceSegment {
            return true
        }
        guard let expectedInputStartTime,
            let actualStartTime = transfer.bufferStartTime
        else {
            return transfer.precedingDroppedBufferCount
                != observedDroppedBufferCount
        }

        let delta = abs(
            CMTimeGetSeconds(CMTimeSubtract(actualStartTime, expectedInputStartTime))
        )
        return delta.isFinite && delta > max(2 / sampleRate, 0.000_1)
    }

    private func analyzerInput(
        for output: AVAudioPCMBuffer,
        fallbackStartTime: CMTime?
    ) -> ConvertedAnalyzerInput {
        let outputTiming = analyzerClock.consumeOutput(
            duration: duration(
                frameCount: output.frameLength,
                sampleRate: output.format.sampleRate
            ),
            fallbackStartTime: fallbackStartTime
        )
        return ConvertedAnalyzerInput(
            input: AnalyzerInput(
                buffer: output,
                bufferStartTime: outputTiming.start
            ),
            startTime: outputTiming.start,
            endTime: outputTiming.end
        )
    }

    private func duration(
        frameCount: AVAudioFrameCount,
        sampleRate: Double
    ) -> CMTime? {
        guard sampleRate.isFinite,
            sampleRate > 0,
            sampleRate <= Double(Int32.max)
        else {
            return nil
        }
        return CMTime(
            value: CMTimeValue(frameCount),
            timescale: CMTimeScale(sampleRate.rounded())
        )
    }
}
