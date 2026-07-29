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

    func acceptedBoundary(for range: CMTimeRange) -> CMTime? {
        guard isAcceptingResults,
            let sessionStartTime,
            range.isValid,
            range.start.isNumeric,
            range.end.isNumeric
        else {
            return nil
        }

        let boundary = CMTimeSubtract(
            sessionStartTime,
            Self.timestampTolerance
        )
        guard CMTimeCompare(range.end, boundary) >= 0 else {
            return nil
        }
        return boundary
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
