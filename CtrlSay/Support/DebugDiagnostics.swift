#if DEBUG
import Foundation

struct DebugPipelineSnapshot {
    var transcript = ""
    var alternatives: [String] = []
    var resultState = "No speech result"
    var confidence = "—"
    var parseOutcome = "—"
    var recognitionLatency = "—"
    var queue = "Idle"
    var clipboardPath = "—"
    var target = "—"

    mutating func received(
        _ result: RecognizedSpeechResult,
        command: VoiceCommand?,
        acceptsVolatileResult: Bool
    ) {
        transcript = result.text
        alternatives = result.alternatives
        resultState = result.isFinal
            ? "Final"
            : (acceptsVolatileResult ? "Volatile • accepted" : "Volatile • pending")
        confidence = result.minimumConfidence.map { String(format: "%.2f", $0) } ?? "Unavailable"
        parseOutcome = command?.telemetryName ?? "No command match"

        let metadata = SpeechCommandMetadata(
            resultReceivedAtNanoseconds: result.receivedAtNanoseconds,
            audioEndUptimeNanoseconds: result.audioEndUptimeNanoseconds,
            minimumConfidence: result.minimumConfidence,
            isFinal: result.isFinal
        )
        recognitionLatency = metadata.recognitionLatencyMilliseconds
            .map { String(format: "%.1f ms", $0) }
            ?? "Unavailable"
    }

    mutating func queued(depth: Int, replacedRevision: Bool) {
        queue = replacedRevision
            ? "Revision replaced • depth \(depth)"
            : "Queued • depth \(depth)"
    }

    mutating func revoked(depth: Int) {
        queue = "Revision revoked • depth \(depth)"
    }

    mutating func began(queueWaitMilliseconds: Double, depth: Int) {
        queue = String(
            format: "Running • waited %.1f ms • depth %d",
            queueWaitMilliseconds,
            depth
        )
    }

    mutating func recordedClipboardPath(milliseconds: Double, targetWasFrontmost: Bool) {
        clipboardPath = String(format: "%.2f ms", milliseconds)
        target = targetWasFrontmost ? "Target verified" : "Target changed"
    }

    mutating func targetStatus(_ status: String) {
        target = status
    }
}
#endif
