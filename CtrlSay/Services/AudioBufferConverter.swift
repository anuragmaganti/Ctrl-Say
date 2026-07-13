@preconcurrency import AVFAudio
import CoreMedia
import Foundation
import Speech

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

    func ageNanoseconds(at uptimeNanoseconds: UInt64) -> UInt64? {
        guard let timelineStartUptimeNanoseconds,
              let bufferStartTime,
              bufferStartTime.isNumeric else {
            return nil
        }
        let sampleRate = buffer.format.sampleRate
        guard sampleRate.isFinite, sampleRate > 0 else { return nil }

        let audioEndSeconds = bufferStartTime.seconds
            + Double(buffer.frameLength) / sampleRate
        guard audioEndSeconds.isFinite, audioEndSeconds >= 0 else { return nil }
        let offset = audioEndSeconds * 1_000_000_000
        guard offset <= Double(UInt64.max - timelineStartUptimeNanoseconds) else {
            return nil
        }
        let audioEndUptimeNanoseconds = timelineStartUptimeNanoseconds
            + UInt64(offset)
        guard uptimeNanoseconds >= audioEndUptimeNanoseconds else { return 0 }
        return uptimeNanoseconds - audioEndUptimeNanoseconds
    }
}

nonisolated struct AudioFormatTransfer: @unchecked Sendable {
    let format: AVAudioFormat
}

nonisolated func makeAudioTapBlock(
    continuation: AsyncStream<AudioBufferTransfer>.Continuation
) -> AVAudioNodeTapBlock {
    let state = AudioTapState()
    return { buffer, time in
        // Core Audio invokes taps on its real-time queue. Constructing this
        // block outside MainActor isolation prevents Swift 6 from asserting
        // that the callback must execute on the main dispatch queue.
        let timing = state.timing(for: time, buffer: buffer)
        guard let ownedBuffer = buffer.copy() as? AVAudioPCMBuffer else {
            state.droppedBufferCount += 1
            return
        }
        let transfer = AudioBufferTransfer(
            buffer: ownedBuffer,
            bufferStartTime: timing.bufferStartTime,
            timelineStartUptimeNanoseconds: timing.timelineStartUptimeNanoseconds,
            precedingDroppedBufferCount: state.droppedBufferCount,
            startsNewSourceSegment: timing.startsNewSourceSegment
        )
        if case .dropped = continuation.yield(transfer) {
            // AVAudioEngine serializes callbacks for a tap. Reporting the
            // cumulative value on the next retained buffer keeps logging and
            // task creation off the real-time audio queue.
            state.droppedBufferCount += 1
        }
    }
}

nonisolated private struct AudioTapTiming {
    let bufferStartTime: CMTime?
    let timelineStartUptimeNanoseconds: UInt64?
    let startsNewSourceSegment: Bool
}

nonisolated private final class AudioTapState: @unchecked Sendable {
    private struct SampleAnchor {
        let sampleTime: AVAudioFramePosition
        let sampleRate: Double
        let timelineTime: CMTime
    }

    private var sampleAnchor: SampleAnchor?
    private var nextTimelineTime = CMTime.zero
    private var timelineStartUptimeNanoseconds: UInt64?
    var droppedBufferCount = 0

    func timing(
        for time: AVAudioTime,
        buffer: AVAudioPCMBuffer
    ) -> AudioTapTiming {
        var startsNewSourceSegment = false
        var bufferStartTime = nextTimelineTime

        if let sampleTime = validSampleTime(from: time) {
            if sampleAnchor == nil
                || sampleAnchor?.sampleRate != time.sampleRate
                || sampleTime < (sampleAnchor?.sampleTime ?? sampleTime) {
                startsNewSourceSegment = sampleAnchor != nil
                sampleAnchor = SampleAnchor(
                    sampleTime: sampleTime,
                    sampleRate: time.sampleRate,
                    timelineTime: nextTimelineTime
                )
            }

            if let sampleAnchor,
               let sampleOffset = duration(
                   frameCount: sampleTime - sampleAnchor.sampleTime,
                   sampleRate: sampleAnchor.sampleRate
               ) {
                let proposedStart = CMTimeAdd(
                    sampleAnchor.timelineTime,
                    sampleOffset
                )
                if CMTimeCompare(proposedStart, nextTimelineTime) >= 0 {
                    bufferStartTime = proposedStart
                } else {
                    // Rebase a reset/overlap to the end of already-published
                    // audio so SpeechAnalyzer never receives overlapping time.
                    startsNewSourceSegment = true
                    bufferStartTime = nextTimelineTime
                    self.sampleAnchor = SampleAnchor(
                        sampleTime: sampleTime,
                        sampleRate: time.sampleRate,
                        timelineTime: bufferStartTime
                    )
                }
            }
        }

        if let hostRelativeStart = hostRelativeTimelineTime(for: time) {
            let hostLead = CMTimeGetSeconds(
                CMTimeSubtract(hostRelativeStart, bufferStartTime)
            )
            if hostLead.isFinite, hostLead > 0.005 {
                // Host time continues across device/route resets. Preserve a
                // real pause instead of compressing it out of the analyzer's
                // input timeline.
                bufferStartTime = hostRelativeStart
                startsNewSourceSegment = true
                if let sampleTime = validSampleTime(from: time) {
                    sampleAnchor = SampleAnchor(
                        sampleTime: sampleTime,
                        sampleRate: time.sampleRate,
                        timelineTime: bufferStartTime
                    )
                }
            }
        }

        if let bufferDuration = duration(
            frameCount: AVAudioFramePosition(buffer.frameLength),
            sampleRate: buffer.format.sampleRate
        ) {
            nextTimelineTime = CMTimeAdd(bufferStartTime, bufferDuration)
        }

        establishTimelineOriginIfPossible(
            from: time,
            bufferStartTime: bufferStartTime
        )
        return AudioTapTiming(
            bufferStartTime: bufferStartTime,
            timelineStartUptimeNanoseconds: timelineStartUptimeNanoseconds,
            startsNewSourceSegment: startsNewSourceSegment
        )
    }

    private func validSampleTime(from time: AVAudioTime) -> AVAudioFramePosition? {
        guard time.isSampleTimeValid,
              time.sampleTime >= 0,
              time.sampleRate.isFinite,
              time.sampleRate > 0,
              time.sampleRate <= Double(Int32.max) else {
            return nil
        }
        return time.sampleTime
    }

    private func establishTimelineOriginIfPossible(
        from time: AVAudioTime,
        bufferStartTime: CMTime
    ) {
        guard timelineStartUptimeNanoseconds == nil,
              time.isHostTimeValid else {
            return
        }

        guard let hostUptimeNanoseconds = hostUptimeNanoseconds(for: time) else {
            return
        }
        let relativeSeconds = bufferStartTime.seconds
        guard relativeSeconds.isFinite,
              relativeSeconds >= 0,
              relativeSeconds <= Double(Int64.max) / 1_000_000_000 else {
            return
        }
        let relativeNanoseconds = UInt64(relativeSeconds * 1_000_000_000)
        guard hostUptimeNanoseconds >= relativeNanoseconds else { return }
        timelineStartUptimeNanoseconds = hostUptimeNanoseconds - relativeNanoseconds
    }

    private func hostRelativeTimelineTime(for time: AVAudioTime) -> CMTime? {
        guard let timelineStartUptimeNanoseconds,
              let hostUptimeNanoseconds = hostUptimeNanoseconds(for: time),
              hostUptimeNanoseconds >= timelineStartUptimeNanoseconds else {
            return nil
        }
        let relativeNanoseconds = hostUptimeNanoseconds - timelineStartUptimeNanoseconds
        guard relativeNanoseconds <= UInt64(Int64.max) else { return nil }
        return CMTime(
            value: CMTimeValue(relativeNanoseconds),
            timescale: 1_000_000_000
        )
    }

    private func hostUptimeNanoseconds(for time: AVAudioTime) -> UInt64? {
        guard time.isHostTimeValid else { return nil }
        let hostSeconds = AVAudioTime.seconds(forHostTime: time.hostTime)
        guard hostSeconds.isFinite,
              hostSeconds >= 0,
              hostSeconds <= Double(Int64.max) / 1_000_000_000 else {
            return nil
        }
        return UInt64(hostSeconds * 1_000_000_000)
    }

    private func duration(
        frameCount: AVAudioFramePosition,
        sampleRate: Double
    ) -> CMTime? {
        guard frameCount >= 0,
              sampleRate.isFinite,
              sampleRate > 0,
              sampleRate <= Double(Int32.max) else {
            return nil
        }
        return CMTime(
            value: frameCount,
            timescale: CMTimeScale(sampleRate.rounded())
        )
    }
}

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
    private var nextOutputStartTime: CMTime?
    private var expectedInputStartTime: CMTime?
    private var observedDroppedBufferCount = 0

    func convert(
        _ transfer: AudioBufferTransfer,
        to outputTransfer: AudioFormatTransfer
    ) throws -> [AnalyzerInput] {
        let input = transfer.buffer
        let outputFormat = outputTransfer.format
        guard input.frameLength > 0 else { return [] }

        if input.format == outputFormat {
            clearConversionState()
            return [
                AnalyzerInput(
                    buffer: input,
                    bufferStartTime: transfer.bufferStartTime
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
            nextOutputStartTime = transfer.bufferStartTime
            expectedInputStartTime = nil
            observedDroppedBufferCount = transfer.precedingDroppedBufferCount
        }

        guard let converter else {
            throw SpeechServiceError.audioConversionUnavailable
        }

        if inputTimelineIsDiscontinuous(transfer, sampleRate: input.format.sampleRate) {
            converter.reset()
            nextOutputStartTime = rebasedOutputStartTime(
                proposed: transfer.bufferStartTime
            )
        }
        observedDroppedBufferCount = transfer.precedingDroppedBufferCount

        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(
            (Double(input.frameLength) * ratio).rounded(.up)
        ) + 32
        let inputState = ConverterInputState(buffer: input)
        var analyzerInputs: [AnalyzerInput] = []

        for _ in 0..<Self.maximumConversionPasses {
            guard let output = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: capacity
            ) else {
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
                expectedInputStartTime = inputEndTime(for: transfer)
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

    func finish(to outputTransfer: AudioFormatTransfer) throws -> [AnalyzerInput] {
        guard let converter else { return [] }
        let outputFormat = outputTransfer.format
        let capacity = AVAudioFrameCount(
            max(256, min(4_096, outputFormat.sampleRate * 0.05))
        )
        var analyzerInputs: [AnalyzerInput] = []

        for _ in 0..<Self.maximumConversionPasses {
            guard let output = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: capacity
            ) else {
                throw SpeechServiceError.audioConversionUnavailable
            }
            var conversionError: NSError?
            let status = converter.convert(
                to: output,
                error: &conversionError
            ) { _, inputStatus in
                inputStatus.pointee = .endOfStream
                return nil
            }

            if let conversionError { throw conversionError }
            if output.frameLength > 0 {
                analyzerInputs.append(
                    analyzerInput(for: output, fallbackStartTime: nil)
                )
            }

            switch status {
            case .endOfStream:
                clearConversionState()
                return analyzerInputs
            case .inputRanDry where output.frameLength == 0:
                clearConversionState()
                return analyzerInputs
            case .haveData, .inputRanDry:
                continue
            case .error:
                throw SpeechServiceError.audioConversionFailed
            @unknown default:
                throw SpeechServiceError.audioConversionFailed
            }
        }

        throw SpeechServiceError.audioConversionFailed
    }

    func reset() {
        clearConversionState()
    }

    private func clearConversionState() {
        converter?.reset()
        converter = nil
        nextOutputStartTime = nil
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
              let actualStartTime = transfer.bufferStartTime else {
            return transfer.precedingDroppedBufferCount
                != observedDroppedBufferCount
        }

        let delta = abs(
            CMTimeGetSeconds(CMTimeSubtract(actualStartTime, expectedInputStartTime))
        )
        return delta.isFinite && delta > max(2 / sampleRate, 0.000_1)
    }

    private func rebasedOutputStartTime(proposed: CMTime?) -> CMTime? {
        guard let proposed else { return nil }
        guard let nextOutputStartTime else { return proposed }
        return CMTimeCompare(proposed, nextOutputStartTime) >= 0
            ? proposed
            : nextOutputStartTime
    }

    private func inputEndTime(for transfer: AudioBufferTransfer) -> CMTime? {
        guard let startTime = transfer.bufferStartTime,
              let duration = duration(
                frameCount: transfer.buffer.frameLength,
                sampleRate: transfer.buffer.format.sampleRate
              ) else {
            return nil
        }
        return CMTimeAdd(startTime, duration)
    }

    private func analyzerInput(
        for output: AVAudioPCMBuffer,
        fallbackStartTime: CMTime?
    ) -> AnalyzerInput {
        let startTime = nextOutputStartTime ?? fallbackStartTime
        if let startTime,
           let outputDuration = duration(
               frameCount: output.frameLength,
               sampleRate: output.format.sampleRate
           ) {
            nextOutputStartTime = CMTimeAdd(startTime, outputDuration)
        }
        return AnalyzerInput(buffer: output, bufferStartTime: startTime)
    }

    private func duration(
        frameCount: AVAudioFrameCount,
        sampleRate: Double
    ) -> CMTime? {
        guard sampleRate.isFinite,
              sampleRate > 0,
              sampleRate <= Double(Int32.max) else {
            return nil
        }
        return CMTime(
            value: CMTimeValue(frameCount),
            timescale: CMTimeScale(sampleRate.rounded())
        )
    }
}
