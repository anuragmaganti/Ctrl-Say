@preconcurrency import AVFAudio
import Foundation
import Speech

nonisolated struct AudioBufferTransfer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
}

nonisolated struct AudioFormatTransfer: @unchecked Sendable {
    let format: AVAudioFormat
}

nonisolated func makeAudioTapBlock(
    continuation: AsyncStream<AudioBufferTransfer>.Continuation
) -> AVAudioNodeTapBlock {
    { buffer, _ in
        // Core Audio invokes taps on its real-time queue. Constructing this
        // block outside MainActor isolation prevents Swift 6 from asserting
        // that the callback must execute on the main dispatch queue.
        continuation.yield(AudioBufferTransfer(buffer: buffer))
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
    private var converter: AVAudioConverter?

    func convert(_ transfer: AudioBufferTransfer, to outputTransfer: AudioFormatTransfer) throws -> AnalyzerInput {
        let input = transfer.buffer
        let outputFormat = outputTransfer.format
        if input.format == outputFormat {
            return AnalyzerInput(buffer: input)
        }

        if converter?.inputFormat != input.format || converter?.outputFormat != outputFormat {
            guard let newConverter = AVAudioConverter(from: input.format, to: outputFormat) else {
                throw SpeechServiceError.audioConversionUnavailable
            }
            converter = newConverter
        }

        guard let converter else {
            throw SpeechServiceError.audioConversionUnavailable
        }

        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw SpeechServiceError.audioConversionUnavailable
        }

        var conversionError: NSError?
        let inputState = ConverterInputState(buffer: input)
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if inputState.suppliedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            inputState.suppliedInput = true
            inputStatus.pointee = .haveData
            return inputState.buffer
        }

        if let conversionError {
            throw conversionError
        }

        guard status == .haveData || status == .inputRanDry else {
            throw SpeechServiceError.audioConversionFailed
        }
        return AnalyzerInput(buffer: output)
    }
}
