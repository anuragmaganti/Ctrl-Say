@preconcurrency import AVFAudio
import CoreMedia
import Testing

@Suite("Speech audio timeline")
struct SpeechAudioTimelineTests {
    @Test("Microphone-off wall time is not inserted into a new input sequence")
    func compressesGapBetweenCaptureSessions() throws {
        let timeline = SpeechAudioTimeline()
        let buffer = try audioBuffer()

        timeline.beginCaptureSession()
        let first = timeline.timing(
            for: audioTime(hostSeconds: 100, sampleTime: 0),
            buffer: buffer
        )
        let second = timeline.timing(
            for: audioTime(hostSeconds: 100.1, sampleTime: 4_800),
            buffer: buffer
        )

        timeline.beginCaptureSession()
        let resumed = timeline.timing(
            for: audioTime(hostSeconds: 105, sampleTime: 0),
            buffer: buffer
        )
        let continued = timeline.timing(
            for: audioTime(hostSeconds: 105.1, sampleTime: 4_800),
            buffer: buffer
        )

        #expect(isApproximately(first.bufferStartTime?.seconds, 0))
        #expect(isApproximately(second.bufferStartTime?.seconds, 0.1))
        #expect(isApproximately(resumed.bufferStartTime?.seconds, 0.2))
        #expect(isApproximately(continued.bufferStartTime?.seconds, 0.3))
    }

    @Test("Each capture session maps analyzer time to its current host time")
    func reanchorsUptimeMappingBetweenCaptureSessions() throws {
        let timeline = SpeechAudioTimeline()
        let buffer = try audioBuffer()

        timeline.beginCaptureSession()
        _ = timeline.timing(
            for: audioTime(hostSeconds: 200, sampleTime: 0),
            buffer: buffer
        )

        timeline.beginCaptureSession()
        let resumedTime = audioTime(
            hostSeconds: 210,
            sampleTime: 0
        )
        let resumed = timeline.timing(
            for: resumedTime,
            buffer: buffer
        )

        let startSeconds = try #require(resumed.bufferStartTime?.seconds)
        let origin = try #require(resumed.timelineStartUptimeNanoseconds)
        let mappedHostNanoseconds =
            Double(origin) + startSeconds * 1_000_000_000
        let actualHostNanoseconds =
            AVAudioTime.seconds(forHostTime: resumedTime.hostTime)
            * 1_000_000_000

        #expect(abs(mappedHostNanoseconds - actualHostNanoseconds) < 1_000)
    }

    @Test("Host scheduling jitter does not become an analyzer input gap")
    func ignoresHostJitterWhenSampleTimeIsValid() throws {
        let timeline = SpeechAudioTimeline()
        let buffer = try audioBuffer()

        timeline.beginCaptureSession()
        _ = timeline.timing(
            for: audioTime(hostSeconds: 300, sampleTime: 0),
            buffer: buffer
        )
        let afterJitter = timeline.timing(
            for: audioTime(hostSeconds: 300.105_375, sampleTime: 4_800),
            buffer: buffer
        )

        #expect(isApproximately(afterJitter.bufferStartTime?.seconds, 0.1))
        #expect(!afterJitter.startsNewSourceSegment)
    }

    @Test("A real sample-time discontinuity remains visible to the analyzer")
    func preservesSampleTimeGapWithinCaptureSession() throws {
        let timeline = SpeechAudioTimeline()
        let buffer = try audioBuffer()

        timeline.beginCaptureSession()
        _ = timeline.timing(
            for: audioTime(hostSeconds: 400, sampleTime: 0),
            buffer: buffer
        )
        let afterDropout = timeline.timing(
            for: audioTime(hostSeconds: 401, sampleTime: 48_000),
            buffer: buffer
        )

        #expect(isApproximately(afterDropout.bufferStartTime?.seconds, 1))
    }

    @Test("A replacement analyzer sequence resumes at converted output end")
    func analyzerClockResumesAtConvertedOutputEnd() {
        var clock = SpeechAnalyzerInputClock()
        let firstDuration = CMTime(
            seconds: 0.105_375,
            preferredTimescale: 1_000_000
        )

        clock.beginCaptureSession()
        clock.prepareForInput(proposedStartTime: .zero)
        let first = clock.consumeOutput(
            duration: firstDuration,
            fallbackStartTime: .zero
        )

        clock.beginCaptureSession()
        clock.prepareForInput(
            proposedStartTime: CMTime(
                seconds: 0.110_750,
                preferredTimescale: 1_000_000
            )
        )
        let resumed = clock.consumeOutput(
            duration: CMTime(
                seconds: 0.1,
                preferredTimescale: 1_000_000
            ),
            fallbackStartTime: nil
        )

        #expect(isApproximately(first.end?.seconds, 0.105_375))
        #expect(isApproximately(resumed.start?.seconds, 0.105_375))
    }

    @Test("A real analyzer input discontinuity is not compressed")
    func analyzerClockPreservesActiveDiscontinuity() {
        var clock = SpeechAnalyzerInputClock()

        clock.beginCaptureSession()
        clock.prepareForInput(proposedStartTime: .zero)
        _ = clock.consumeOutput(
            duration: CMTime(
                seconds: 0.1,
                preferredTimescale: 1_000
            ),
            fallbackStartTime: .zero
        )
        clock.prepareForInput(
            proposedStartTime: CMTime(
                seconds: 1,
                preferredTimescale: 1_000
            )
        )
        let resumed = clock.consumeOutput(
            duration: CMTime(
                seconds: 0.1,
                preferredTimescale: 1_000
            ),
            fallbackStartTime: nil
        )

        #expect(isApproximately(resumed.start?.seconds, 1))
    }

    private func audioBuffer() throws -> AVAudioPCMBuffer {
        let format = try #require(
            AVAudioFormat(
                standardFormatWithSampleRate: 48_000,
                channels: 1
            )
        )
        let buffer = try #require(
            AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: 4_800
            )
        )
        buffer.frameLength = 4_800
        return buffer
    }

    private func audioTime(
        hostSeconds: TimeInterval,
        sampleTime: AVAudioFramePosition
    ) -> AVAudioTime {
        AVAudioTime(
            hostTime: AVAudioTime.hostTime(forSeconds: hostSeconds),
            sampleTime: sampleTime,
            atRate: 48_000
        )
    }

    private func isApproximately(
        _ actual: Double?,
        _ expected: Double,
        tolerance: Double = 0.000_001
    ) -> Bool {
        guard let actual else { return false }
        return abs(actual - expected) <= tolerance
    }
}
