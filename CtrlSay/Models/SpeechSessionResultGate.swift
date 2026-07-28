import CoreMedia

struct SpeechSessionResultGate {
    private static let timestampTolerance = CMTime(value: 1, timescale: 1_000)

    private var isAcceptingResults = false
    private var sessionStartTime: CMTime?

    mutating func beginSession() {
        isAcceptingResults = true
        sessionStartTime = nil
    }

    mutating func recordSessionStart(_ time: CMTime) {
        guard isAcceptingResults,
            sessionStartTime == nil,
            time.isNumeric
        else {
            return
        }
        sessionStartTime = time
    }

    mutating func endSession() {
        isAcceptingResults = false
        sessionStartTime = nil
    }

    func accepts(_ range: CMTimeRange) -> Bool {
        guard isAcceptingResults,
            let sessionStartTime,
            range.isValid,
            range.start.isNumeric,
            range.end.isNumeric
        else {
            return false
        }

        let earliestAcceptedStart = CMTimeSubtract(
            sessionStartTime,
            Self.timestampTolerance
        )
        return CMTimeCompare(range.start, earliestAcceptedStart) >= 0
    }

    func acceptsFinalizationTime(_ time: CMTime) -> Bool {
        guard isAcceptingResults,
            let sessionStartTime,
            time.isNumeric
        else {
            return false
        }
        let earliestAcceptedTime = CMTimeSubtract(
            sessionStartTime,
            Self.timestampTolerance
        )
        return CMTimeCompare(time, earliestAcceptedTime) >= 0
    }
}
