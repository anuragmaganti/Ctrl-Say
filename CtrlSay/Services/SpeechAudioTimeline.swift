@preconcurrency import AVFAudio
import CoreMedia
import Foundation

nonisolated struct AudioTapTiming {
    let bufferStartTime: CMTime?
    let timelineStartUptimeNanoseconds: UInt64?
    let startsNewSourceSegment: Bool
}

/// Maintains SpeechAnalyzer time codes across multiple microphone sessions.
///
/// SpeechAnalyzer keeps one continuous audio timeline when a new input sequence
/// replaces an old one. Time while Ctrl-Say is not listening is not audio input,
/// so a new capture session resumes at the prior audio end instead of inserting
/// the microphone-off wall-clock interval as a gap.
nonisolated final class SpeechAudioTimeline: @unchecked Sendable {
    private struct SampleAnchor {
        let sampleTime: AVAudioFramePosition
        let sampleRate: Double
        let timelineTime: CMTime
    }

    private var sampleAnchor: SampleAnchor?
    private var nextTimelineTime = CMTime.zero
    private var timelineStartUptimeNanoseconds: UInt64?
    var droppedBufferCount = 0

    /// Reanchors host and sample time for a newly installed microphone tap while
    /// preserving the analyzer's next nonoverlapping audio time code.
    func beginCaptureSession() {
        sampleAnchor = nil
        timelineStartUptimeNanoseconds = nil
        droppedBufferCount = 0
    }

    func timing(
        for time: AVAudioTime,
        buffer: AVAudioPCMBuffer
    ) -> AudioTapTiming {
        var startsNewSourceSegment = false
        var bufferStartTime = nextTimelineTime
        let sampleTime = validSampleTime(from: time)

        if let sampleTime {
            if sampleAnchor == nil
                || sampleAnchor?.sampleRate != time.sampleRate
                || sampleTime < (sampleAnchor?.sampleTime ?? sampleTime)
            {
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
                )
            {
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

        if sampleTime == nil,
            let hostRelativeStart = hostRelativeTimelineTime(for: time)
        {
            let hostLead = CMTimeGetSeconds(
                CMTimeSubtract(hostRelativeStart, bufferStartTime)
            )
            if hostLead.isFinite, hostLead > 0.005 {
                // Host time is a fallback only when Core Audio supplies no
                // sample time. With valid sample time, host-clock scheduling
                // jitter must not become an artificial analyzer input gap.
                bufferStartTime = hostRelativeStart
                startsNewSourceSegment = true
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
            time.sampleRate <= Double(Int32.max)
        else {
            return nil
        }
        return time.sampleTime
    }

    private func establishTimelineOriginIfPossible(
        from time: AVAudioTime,
        bufferStartTime: CMTime
    ) {
        guard timelineStartUptimeNanoseconds == nil,
            time.isHostTimeValid
        else {
            return
        }

        guard let hostUptimeNanoseconds = hostUptimeNanoseconds(for: time) else {
            return
        }
        let relativeSeconds = bufferStartTime.seconds
        guard relativeSeconds.isFinite,
            relativeSeconds >= 0,
            relativeSeconds <= Double(Int64.max) / 1_000_000_000
        else {
            return
        }
        let relativeNanoseconds = UInt64(relativeSeconds * 1_000_000_000)
        guard hostUptimeNanoseconds >= relativeNanoseconds else { return }
        timelineStartUptimeNanoseconds = hostUptimeNanoseconds - relativeNanoseconds
    }

    private func hostRelativeTimelineTime(for time: AVAudioTime) -> CMTime? {
        guard let timelineStartUptimeNanoseconds,
            let hostUptimeNanoseconds = hostUptimeNanoseconds(for: time),
            hostUptimeNanoseconds >= timelineStartUptimeNanoseconds
        else {
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
            hostSeconds <= Double(Int64.max) / 1_000_000_000
        else {
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
            sampleRate <= Double(Int32.max)
        else {
            return nil
        }
        return CMTime(
            value: frameCount,
            timescale: CMTimeScale(sampleRate.rounded())
        )
    }
}

/// Tracks the time code of audio that was actually yielded to SpeechAnalyzer.
///
/// Converted output can end a few milliseconds before or after the source
/// buffer's time code. A replacement input sequence must resume from this
/// converted output end, not from the raw capture clock.
nonisolated struct SpeechAnalyzerInputClock {
    private(set) var nextOutputStartTime: CMTime?
    private var resumesContinuously = false

    mutating func beginCaptureSession() {
        resumesContinuously = nextOutputStartTime != nil
    }

    mutating func prepareForInput(proposedStartTime: CMTime?) {
        if resumesContinuously {
            resumesContinuously = false
            return
        }
        guard let proposedStartTime, proposedStartTime.isNumeric else { return }
        guard let nextOutputStartTime else {
            self.nextOutputStartTime = proposedStartTime
            return
        }
        if CMTimeCompare(proposedStartTime, nextOutputStartTime) > 0 {
            self.nextOutputStartTime = proposedStartTime
        }
    }

    mutating func consumeOutput(
        duration: CMTime?,
        fallbackStartTime: CMTime?
    ) -> (start: CMTime?, end: CMTime?) {
        let startTime = nextOutputStartTime ?? fallbackStartTime
        guard let startTime,
            startTime.isNumeric,
            let duration,
            duration.isNumeric
        else {
            return (startTime, nil)
        }
        let endTime = CMTimeAdd(startTime, duration)
        nextOutputStartTime = endTime
        return (startTime, endTime)
    }

    mutating func reset() {
        nextOutputStartTime = nil
        resumesContinuously = false
    }
}
