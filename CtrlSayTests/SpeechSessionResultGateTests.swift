import CoreMedia
import Testing

@Suite("Speech session result gate")
struct SpeechSessionResultGateTests {
    @Test("Results are rejected until current-session audio begins")
    func rejectsBeforeAudioStarts() {
        var gate = SpeechSessionResultGate()
        gate.beginSession()

        #expect(!gate.accepts(range(start: 0, duration: 1)))
    }

    @Test("Current-session results are accepted")
    func acceptsCurrentSession() {
        var gate = SpeechSessionResultGate()
        gate.beginSession()
        gate.recordSessionStart(time(10))

        #expect(gate.accepts(range(start: 10, duration: 0.5)))
        #expect(gate.accepts(range(start: 10, duration: 0)))
        #expect(gate.acceptsFinalizationTime(time(10.25)))
    }

    @Test("Late results from the previous session are rejected")
    func rejectsPreviousSession() {
        var gate = SpeechSessionResultGate()
        gate.beginSession()
        gate.recordSessionStart(time(10))

        #expect(!gate.accepts(range(start: 4, duration: 2)))
        #expect(!gate.accepts(range(start: 9, duration: 2)))
        #expect(!gate.acceptsFinalizationTime(time(9)))
    }

    @Test("One millisecond of timestamp rounding is tolerated")
    func toleratesTimestampRounding() {
        var gate = SpeechSessionResultGate()
        gate.beginSession()
        gate.recordSessionStart(time(10))

        #expect(gate.accepts(range(start: 9.9995, duration: 0.5)))
    }

    @Test("Ending and restarting clears the previous session boundary")
    func resetsBetweenSessions() {
        var gate = SpeechSessionResultGate()
        gate.beginSession()
        gate.recordSessionStart(time(2))
        gate.endSession()

        #expect(!gate.accepts(range(start: 2, duration: 1)))

        gate.beginSession()
        #expect(!gate.accepts(range(start: 20, duration: 1)))
        gate.recordSessionStart(time(20))
        #expect(gate.accepts(range(start: 20, duration: 1)))
    }

    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 1_000_000)
    }

    private func range(start: Double, duration: Double) -> CMTimeRange {
        CMTimeRange(start: time(start), duration: time(duration))
    }
}
