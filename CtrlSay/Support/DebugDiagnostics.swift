#if DEBUG
import Foundation

struct DebugPipelineSnapshot {
    var transcript = ""
    var alternatives: [String] = []
    var resultState = "No speech result"
    var confidence = "—"
    var parseOutcome = "—"
    var recognitionLatency = "—"
    var tokenization = "—"
    var namedCopyRevision = "—"
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
        resultState =
            result.isFinal
            ? "Final"
            : (acceptsVolatileResult ? "Volatile • accepted" : "Volatile • pending")
        confidence = result.minimumConfidence.map { String(format: "%.2f", $0) } ?? "Unavailable"
        parseOutcome = command?.telemetryName ?? "No command match"

        let metadata = SpeechCommandMetadata(
            resultReceivedAtNanoseconds: result.receivedAtNanoseconds,
            audioEndUptimeNanoseconds: result.audioEndUptimeNanoseconds,
            isFinalResult: result.isFinal
        )
        recognitionLatency =
            metadata.recognitionLatencyMilliseconds
            .map { String(format: "%.1f ms", $0) }
            ?? "Unavailable"
        if result.inWordAttributeRunMergeCount > 0 {
            tokenization =
                "\(result.tokens.count) words from \(result.attributeRunCount) runs • \(result.inWordAttributeRunMergeCount) in-word join(s), same result"
        } else {
            tokenization = "\(result.tokens.count) words from \(result.attributeRunCount) run(s) • no in-word joins"
        }
    }

    mutating func queued(depth: Int, replacedRevision: Bool) {
        queue =
            replacedRevision
            ? "Revision replaced • depth \(depth)"
            : "Queued • depth \(depth)"
    }

    mutating func namedCopyCandidateStarted(
        characterCount: Int,
        isStable: Bool
    ) {
        namedCopyRevision = "First candidate • \(characterCount) chars • \(isStable ? "stable" : "revisable")"
    }

    mutating func namedCopyCandidateRevised(
        previousCharacterCount: Int,
        currentCharacterCount: Int,
        revisionMilliseconds: Double,
        totalMilliseconds: Double,
        isStable: Bool
    ) {
        namedCopyRevision = String(
            format: "%d→%d chars • +%.1f ms • %.1f ms total • %@",
            previousCharacterCount,
            currentCharacterCount,
            revisionMilliseconds,
            totalMilliseconds,
            isStable ? "stable" : "revisable"
        )
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
