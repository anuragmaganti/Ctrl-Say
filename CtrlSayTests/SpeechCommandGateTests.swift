import CoreMedia
import XCTest

final class SpeechCommandGateTests: XCTestCase {
    func testRecognitionFreshnessRejectsLateResultWithoutAddingDelay() {
        let maximum = SpeechCommandFreshnessPolicy.maximumRecognitionAgeNanoseconds
        let metadata = SpeechCommandMetadata(
            resultReceivedAtNanoseconds: 1_000,
            audioEndUptimeNanoseconds: 1_000,
            isFinalResult: false
        )

        XCTAssertNil(
            SpeechCommandFreshnessPolicy.rejectionReason(
                metadata,
                at: 1_000 + maximum
            )
        )
        XCTAssertEqual(
            SpeechCommandFreshnessPolicy.rejectionReason(
                metadata,
                at: 1_001 + maximum
            ),
            .recognition
        )
    }

    func testFinalResultGetsBoundedFallbackWindowWithoutAddingDelay() {
        let audioEnd: UInt64 = 1_000_000_000
        let resultReceived = audioEnd + 1_105_000_000
        let metadata = SpeechCommandMetadata(
            resultReceivedAtNanoseconds: resultReceived,
            audioEndUptimeNanoseconds: audioEnd,
            isFinalResult: true
        )

        XCTAssertNil(
            SpeechCommandFreshnessPolicy.rejectionReason(
                metadata,
                at: resultReceived
            )
        )
        XCTAssertEqual(
            SpeechCommandFreshnessPolicy.rejectionReason(
                metadata,
                at: audioEnd
                    + SpeechCommandFreshnessPolicy
                    .maximumFinalRecognitionAgeNanoseconds + 1
            ),
            .recognition
        )
    }

    func testDispatchFreshnessRemainsIndependentFromRecognitionAge() {
        let maximum = SpeechCommandFreshnessPolicy.maximumDispatchAgeNanoseconds
        let receivedAt: UInt64 = 10_000_000_000
        let metadata = SpeechCommandMetadata(
            resultReceivedAtNanoseconds: receivedAt,
            audioEndUptimeNanoseconds: nil,
            isFinalResult: false
        )

        XCTAssertNil(
            SpeechCommandFreshnessPolicy.rejectionReason(
                metadata,
                at: receivedAt + maximum
            )
        )
        XCTAssertEqual(
            SpeechCommandFreshnessPolicy.rejectionReason(
                metadata,
                at: receivedAt + maximum + 1
            ),
            .dispatch
        )
    }

    func testRecognitionStalenessWinsWhenBothLimitsAreExceeded() {
        let metadata = SpeechCommandMetadata(
            resultReceivedAtNanoseconds: 1_000,
            audioEndUptimeNanoseconds: 500,
            isFinalResult: false
        )
        let now = 1_000 + SpeechCommandFreshnessPolicy.maximumDispatchAgeNanoseconds + 1

        XCTAssertEqual(
            SpeechCommandFreshnessPolicy.rejectionReason(metadata, at: now),
            .recognition
        )
    }

    func testVolatileAndFinalRevisionExecuteOnlyOnce() {
        var gate = SpeechCommandGate()
        let range = makeRange(start: 0, end: 1)

        let first = gate.ingest(
            observation(
                range: range,
                finalizationTime: 0,
                command: .pasteNumber(2),
                acceptsVolatile: true
            )
        ).mutations
        XCTAssertEqual(first.count, 1)

        let final = gate.ingest(
            observation(
                range: range,
                finalizationTime: 1,
                isFinal: true,
                command: .pasteNumber(2),
                acceptsVolatile: true
            )
        ).mutations
        XCTAssertTrue(final.isEmpty)
    }

    func testParseableNumberRevisionUpdatesSameUtteranceBeforeCommit() throws {
        var gate = SpeechCommandGate()
        let range = makeRange(start: 0, end: 1)

        let first = gate.ingest(
            observation(
                range: range,
                finalizationTime: 0,
                command: .pasteNumber(2),
                acceptsVolatile: true
            )
        ).mutations
        let firstID = try XCTUnwrap(first.upsertID)

        let revision = gate.ingest(
            observation(
                range: range,
                finalizationTime: 0,
                command: .pasteNumber(3),
                acceptsVolatile: true
            )
        ).mutations

        XCTAssertEqual(revision.upsertID, firstID)
        XCTAssertEqual(revision.upsertCommand, .pasteNumber(3))

        XCTAssertTrue(
            gate.ingest(
                observation(
                    range: range,
                    finalizationTime: 1,
                    isFinal: true,
                    command: .pasteNumber(3),
                    acceptsVolatile: true
                )
            ).mutations.isEmpty
        )
    }

    func testImmediateRepeatWithDifferentAudioRangeIsDistinct() throws {
        var gate = SpeechCommandGate()
        let first = gate.ingest(
            observation(
                range: makeRange(start: 0, end: 0.8),
                finalizationTime: 0,
                command: .pasteNumber(2),
                acceptsVolatile: true
            )
        ).mutations
        let second = gate.ingest(
            observation(
                range: makeRange(start: 0.9, end: 1.7),
                finalizationTime: 0.85,
                command: .pasteNumber(2),
                acceptsVolatile: true
            )
        ).mutations

        let firstID = try XCTUnwrap(first.upsertID)
        let secondID = try XCTUnwrap(second.upsertID)
        XCTAssertNotEqual(firstID, secondID)
    }

    func testUnparseableRevisionRevokesPendingCommand() throws {
        var gate = SpeechCommandGate()
        let range = makeRange(start: 0, end: 1)
        let first = gate.ingest(
            observation(
                range: range,
                finalizationTime: 0,
                command: .pasteNumber(2),
                acceptsVolatile: true
            )
        ).mutations
        let id = try XCTUnwrap(first.upsertID)

        XCTAssertEqual(
            gate.ingest(
                observation(
                    range: range,
                    finalizationTime: 0,
                    command: nil,
                    acceptsVolatile: false
                )
            ).mutations,
            [.revoke(id)]
        )
    }

    func testFinalizationWatermarkReleasesStablePendingCommand() {
        var gate = SpeechCommandGate()
        XCTAssertTrue(
            gate.ingest(
                observation(
                    range: makeRange(start: 0, end: 1),
                    finalizationTime: 0,
                    command: .permanentCopy("house"),
                    acceptsVolatile: false
                )
            ).mutations.isEmpty
        )

        let mutations = gate.ingest(
            observation(
                range: makeRange(start: 2, end: 3),
                finalizationTime: 1.5,
                command: nil,
                acceptsVolatile: false
            )
        ).mutations
        XCTAssertEqual(mutations.count, 1)
        XCTAssertEqual(mutations.upsertCommand, .permanentCopy("house"))
    }

    func testFinalWordPartitionsPreservePendingPermanentCommand() {
        var gate = SpeechCommandGate()
        XCTAssertTrue(
            gate.ingest(
                observation(
                    range: makeRange(start: 0, end: 1.2),
                    finalizationTime: 0,
                    command: .permanentCopy("house"),
                    acceptsVolatile: false
                )
            ).mutations.isEmpty
        )

        XCTAssertTrue(
            gate.ingest(
                observation(
                    range: makeRange(start: 0, end: 0.4),
                    finalizationTime: 0.4,
                    isFinal: true,
                    command: nil,
                    acceptsVolatile: false
                )
            ).mutations.isEmpty
        )
        XCTAssertTrue(
            gate.ingest(
                observation(
                    range: makeRange(start: 0.4, end: 0.8),
                    finalizationTime: 0.8,
                    isFinal: true,
                    command: nil,
                    acceptsVolatile: false
                )
            ).mutations.isEmpty
        )

        let finalPartition = gate.ingest(
            observation(
                range: makeRange(start: 0.8, end: 1.2),
                finalizationTime: 1.2,
                isFinal: true,
                command: nil,
                acceptsVolatile: false
            )
        ).mutations

        XCTAssertEqual(finalPartition.upsertCommands, [.permanentCopy("house")])
    }

    func testCommittedCommandIgnoresLaterRevision() throws {
        var gate = SpeechCommandGate()
        let range = makeRange(start: 0, end: 1)
        let mutations = gate.ingest(
            observation(
                range: range,
                finalizationTime: 0,
                command: .pasteNumber(2),
                acceptsVolatile: true
            )
        ).mutations
        let id = try XCTUnwrap(mutations.upsertID)
        gate.markCommitted(id)

        XCTAssertTrue(
            gate.ingest(
                observation(
                    range: range,
                    finalizationTime: 1,
                    isFinal: true,
                    command: .copyNumber(2),
                    acceptsVolatile: true
                )
            ).mutations.isEmpty
        )
    }

    func testWatermarkQueuesEarlierHeldCommandBeforeCurrentCommand() {
        var gate = SpeechCommandGate()
        XCTAssertTrue(
            gate.ingest(
                observation(
                    range: makeRange(start: 0, end: 1),
                    finalizationTime: 0,
                    command: .copyNumber(2),
                    acceptsVolatile: false
                )
            ).mutations.isEmpty
        )

        let mutations = gate.ingest(
            observation(
                range: makeRange(start: 2, end: 3),
                finalizationTime: 1.5,
                command: .pasteNumber(2),
                acceptsVolatile: true
            )
        ).mutations

        XCTAssertEqual(
            mutations.upsertCommands,
            [.copyNumber(2), .pasteNumber(2)]
        )
    }

    func testLaterReadyCommandWaitsForEarlierUnresolvedCommand() {
        var gate = SpeechCommandGate()
        let earlierRange = makeRange(start: 0, end: 1)
        XCTAssertTrue(
            gate.ingest(
                observation(
                    range: earlierRange,
                    finalizationTime: 0,
                    command: .copyNumber(2),
                    acceptsVolatile: false
                )
            ).mutations.isEmpty
        )

        XCTAssertTrue(
            gate.ingest(
                observation(
                    range: makeRange(start: 1.1, end: 2),
                    finalizationTime: 0,
                    command: .pasteNumber(2),
                    acceptsVolatile: true
                )
            ).mutations.isEmpty
        )

        let mutations = gate.ingest(
            observation(
                range: earlierRange,
                finalizationTime: 1,
                isFinal: true,
                command: .copyNumber(2),
                acceptsVolatile: false
            )
        ).mutations

        XCTAssertEqual(
            mutations.upsertCommands,
            [.copyNumber(2), .pasteNumber(2)]
        )
    }

    func testWatermarkReleaseTimestampMeasuresActualGateDelay() throws {
        var gate = SpeechCommandGate()
        _ = gate.ingest(
            observation(
                range: makeRange(start: 0, end: 1),
                finalizationTime: 0,
                command: .permanentCopy("house"),
                acceptsVolatile: false,
                receivedAtNanoseconds: 2_000_000
            )
        )

        let update = gate.ingest(
            observation(
                range: makeRange(start: 2, end: 3),
                finalizationTime: 1.5,
                command: nil,
                acceptsVolatile: false,
                receivedAtNanoseconds: 9_000_000
            )
        )

        let metadata = try XCTUnwrap(update.mutations.upsertMetadata)
        XCTAssertEqual(metadata.resultReceivedAtNanoseconds, 9_000_000)
        XCTAssertTrue(metadata.isFinalResult)
    }

    func testEarlierUnsafeRevisionAlsoRevokesQueuedLaterCommand() throws {
        var gate = SpeechCommandGate()
        let earlierRange = makeRange(start: 0, end: 1)
        let earlier = gate.ingest(
            observation(
                range: earlierRange,
                finalizationTime: 0,
                command: .copyNumber(2),
                acceptsVolatile: true
            )
        )
        let later = gate.ingest(
            observation(
                range: makeRange(start: 2, end: 3),
                finalizationTime: 0,
                command: .pasteNumber(2),
                acceptsVolatile: true
            )
        )

        let earlierID = try XCTUnwrap(earlier.mutations.upsertID)
        let laterID = try XCTUnwrap(later.mutations.upsertID)
        let revision = gate.ingest(
            observation(
                range: earlierRange,
                finalizationTime: 0,
                command: .copyNumber(2),
                acceptsVolatile: false
            )
        )

        XCTAssertEqual(
            revision.mutations,
            [.revoke(earlierID), .revoke(laterID)]
        )
    }

    func testPotentialEarlierCommandPrefixBlocksLaterReadyCommand() {
        var gate = SpeechCommandGate()
        let earlierRange = makeRange(start: 0, end: 1)

        XCTAssertTrue(
            gate.ingest(
                observation(
                    range: earlierRange,
                    finalizationTime: 0,
                    command: nil,
                    isPotentialCommand: true,
                    acceptsVolatile: false
                )
            ).mutations.isEmpty
        )
        XCTAssertTrue(
            gate.ingest(
                observation(
                    range: makeRange(start: 1.1, end: 2),
                    finalizationTime: 0,
                    command: .pasteNumber(2),
                    acceptsVolatile: true
                )
            ).mutations.isEmpty
        )

        let mutations = gate.ingest(
            observation(
                range: earlierRange,
                finalizationTime: 1,
                isFinal: true,
                command: .copyNumber(2),
                acceptsVolatile: true
            )
        ).mutations

        XCTAssertEqual(mutations.upsertCommands, [.copyNumber(2), .pasteNumber(2)])
    }

    func testPotentialBarrierSurvivesUnrelatedVolatileRevision() {
        var gate = SpeechCommandGate()
        let earlierRange = makeRange(start: 0, end: 1)

        _ = gate.ingest(
            observation(
                range: earlierRange,
                finalizationTime: 0,
                command: nil,
                isPotentialCommand: true,
                acceptsVolatile: false
            )
        )
        _ = gate.ingest(
            observation(
                range: earlierRange,
                finalizationTime: 0,
                command: nil,
                isPotentialCommand: false,
                acceptsVolatile: false
            )
        )

        XCTAssertTrue(
            gate.ingest(
                observation(
                    range: makeRange(start: 1.1, end: 2),
                    finalizationTime: 0,
                    command: .pasteNumber(2),
                    acceptsVolatile: true
                )
            ).mutations.isEmpty
        )

        let mutations = gate.ingest(
            observation(
                range: earlierRange,
                finalizationTime: 1,
                isFinal: true,
                command: .copyNumber(2),
                acceptsVolatile: true
            )
        ).mutations
        XCTAssertEqual(mutations.upsertCommands, [.copyNumber(2), .pasteNumber(2)])
    }

    private func observation(
        range: CMTimeRange,
        finalizationTime: Double,
        isFinal: Bool = false,
        command: VoiceCommand?,
        isPotentialCommand: Bool? = nil,
        acceptsVolatile: Bool,
        receivedAtNanoseconds: UInt64 = 2_000_000
    ) -> SpeechCommandObservation {
        SpeechCommandObservation(
            range: SpeechResultRange(range),
            finalizationTime: time(finalizationTime),
            isFinal: isFinal,
            command: command,
            isPotentialCommand: isPotentialCommand ?? (command != nil),
            acceptsVolatileResult: acceptsVolatile,
            metadata: SpeechCommandMetadata(
                resultReceivedAtNanoseconds: receivedAtNanoseconds,
                audioEndUptimeNanoseconds: 1_000_000,
                isFinalResult: isFinal
            )
        )
    }

    private func makeRange(start: Double, end: Double) -> CMTimeRange {
        CMTimeRange(start: time(start), end: time(end))
    }

    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 1_000)
    }
}

extension Array where Element == SpeechCommandMutation {
    fileprivate var upsertID: SpeechUtteranceID? {
        for mutation in self {
            if case .upsert(let id, _, _) = mutation { return id }
        }
        return nil
    }

    fileprivate var upsertCommand: VoiceCommand? {
        for mutation in self {
            if case .upsert(_, let command, _) = mutation { return command }
        }
        return nil
    }

    fileprivate var upsertCommands: [VoiceCommand] {
        compactMap { mutation in
            if case .upsert(_, let command, _) = mutation { return command }
            return nil
        }
    }

    fileprivate var upsertMetadata: SpeechCommandMetadata? {
        for mutation in self {
            if case .upsert(_, _, let metadata) = mutation { return metadata }
        }
        return nil
    }
}
