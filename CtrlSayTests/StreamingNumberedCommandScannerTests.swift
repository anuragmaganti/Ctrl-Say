import CoreMedia
import XCTest

final class StreamingNumberedCommandScannerTests: XCTestCase {
    func testFindsCopyTenAmidFiller() throws {
        var scanner = StreamingNumberedCommandScanner()
        let update = scanner.ingest(
            segment(
                0...3,
                words: ["hmm", "this", "is", "important", "copy", "10", "please"]
            )
        )

        XCTAssertEqual(try commands(in: update), [.copyNumber(10)])
    }

    func testFindsMultipleCommandsInOneSegmentInAudioOrder() throws {
        var scanner = StreamingNumberedCommandScanner()
        let update = scanner.ingest(
            segment(
                0...8,
                words: [
                    "okay", "copy", "one", "and", "copy", "two", "then",
                    "paste", "one", "and", "paste", "two",
                ]
            )
        )

        XCTAssertEqual(
            try commands(in: update),
            [.copyNumber(1), .copyNumber(2), .pasteNumber(1), .pasteNumber(2)]
        )
    }

    func testRecognizesScopedNumberAliasesAndAllSlots() throws {
        let spoken = ["won", "too", "three", "fore", "five", "six", "seven", "ate", "nine", "ten"]
        var words: [String] = []
        for word in spoken {
            words.append(contentsOf: ["copy", word, "then"])
        }

        var scanner = StreamingNumberedCommandScanner()
        let update = scanner.ingest(segment(0...10, words: words))
        XCTAssertEqual(
            try commands(in: update),
            (1...10).map(VoiceCommand.copyNumber)
        )
    }

    func testBridgesVerbAndNumberAcrossAdjacentSegments() throws {
        var scanner = StreamingNumberedCommandScanner(maximumCrossSegmentGap: 0.5)
        XCTAssertTrue(
            scanner.ingest(segment(0...1, words: ["please", "copy"])).mutations.isEmpty
        )

        let update = scanner.ingest(segment(1.2...1.7, words: ["ten", "now"]))
        XCTAssertEqual(try commands(in: update), [.copyNumber(10)])
    }

    func testDoesNotBridgeAcrossAnUnboundedPause() {
        var scanner = StreamingNumberedCommandScanner(maximumCrossSegmentGap: 0.5)
        _ = scanner.ingest(segment(0...1, words: ["copy"]))

        XCTAssertTrue(
            scanner.ingest(segment(1.6...2, words: ["two"])).mutations.isEmpty
        )
    }

    func testRevisionKeepsIDAndUpdatesNumber() throws {
        var scanner = StreamingNumberedCommandScanner()
        let first = scanner.ingest(segment(0...1, words: ["paste", "two"]))
        let firstCandidate = try XCTUnwrap(upserts(in: first).first)

        let revision = scanner.ingest(segment(0...1, words: ["paste", "three"]))
        let revisedCandidate = try XCTUnwrap(upserts(in: revision).first)

        XCTAssertEqual(revisedCandidate.id, firstCandidate.id)
        XCTAssertEqual(revisedCandidate.command, .pasteNumber(3))
    }

    func testDisappearingUncommittedCandidateIsRevoked() throws {
        var scanner = StreamingNumberedCommandScanner()
        let first = scanner.ingest(segment(0...1, words: ["paste", "two"]))
        let id = try XCTUnwrap(upserts(in: first).first?.id)

        let revision = scanner.ingest(segment(0...1, words: ["ordinary", "speech"]))
        XCTAssertEqual(revision.mutations, [.revoke(id)])
    }

    func testRemovingAnEarlierCommandDoesNotChangeTheLaterCommandIdentity() throws {
        var scanner = StreamingNumberedCommandScanner()
        let first = scanner.ingest(
            StreamingNumberedCommandSegment(
                range: timeRange(0, 2),
                tokens: [
                    token("copy", 0.1, 0.3),
                    token("one", 0.31, 0.5),
                    token("paste", 1.0, 1.2),
                    token("two", 1.21, 1.4),
                ]
            )
        )
        let original = upserts(in: first)
        XCTAssertEqual(original.count, 2)

        let revision = scanner.ingest(
            StreamingNumberedCommandSegment(
                range: timeRange(0, 2),
                tokens: [
                    token("paste", 1.0, 1.2),
                    token("two", 1.21, 1.4),
                ]
            )
        )

        XCTAssertEqual(revision.mutations, [.revoke(original[0].id)])
    }

    func testRemovingAnEarlierIdenticalCommandDoesNotChangeTheLaterIdentity() throws {
        var scanner = StreamingNumberedCommandScanner()
        let first = scanner.ingest(
            StreamingNumberedCommandSegment(
                range: timeRange(0, 2),
                tokens: [
                    token("paste", 0.1, 0.3),
                    token("two", 0.31, 0.5),
                    token("paste", 1.0, 1.2),
                    token("two", 1.21, 1.4),
                ]
            )
        )
        let original = upserts(in: first)
        XCTAssertEqual(original.count, 2)

        let revision = scanner.ingest(
            StreamingNumberedCommandSegment(
                range: timeRange(0, 2),
                tokens: [
                    token("paste", 1.0, 1.2),
                    token("two", 1.21, 1.4),
                ]
            )
        )

        XCTAssertEqual(revision.mutations, [.revoke(original[0].id)])
    }

    func testCommittedCandidateBecomesTombstoneAcrossRevisionAndFinalEcho() throws {
        var scanner = StreamingNumberedCommandScanner()
        let first = scanner.ingest(segment(0...1, words: ["paste", "two"]))
        let id = try XCTUnwrap(upserts(in: first).first?.id)
        scanner.markCommitted(id)

        XCTAssertTrue(
            scanner.ingest(segment(0...1, words: ["paste", "three"])).mutations.isEmpty
        )
        XCTAssertTrue(
            scanner.ingest(
                segment(
                    0...1,
                    words: ["paste", "three"],
                    finalizationTime: 1,
                    isFinal: true
                )
            ).mutations.isEmpty
        )
        XCTAssertTrue(
            scanner.ingest(
                segment(
                    0...1,
                    words: ["paste", "three"],
                    finalizationTime: 1,
                    isFinal: true
                )
            ).mutations.isEmpty
        )
    }

    func testVolatileAndFinalEchoDoNotDuplicatePendingCandidate() throws {
        var scanner = StreamingNumberedCommandScanner()
        let first = scanner.ingest(segment(0...1, words: ["copy", "four"]))
        XCTAssertEqual(try commands(in: first), [.copyNumber(4)])

        let final = scanner.ingest(
            segment(
                0...1,
                words: ["copy", "four"],
                finalizationTime: 1,
                isFinal: true
            )
        )
        XCTAssertTrue(final.mutations.isEmpty)
    }

    func testZeroDurationTokenRangesStillKeepIdentityAcrossEcho() throws {
        var scanner = StreamingNumberedCommandScanner()
        let instant = timeRange(0.5, 0.5)
        let observation = StreamingNumberedCommandSegment(
            range: timeRange(0, 1),
            tokens: [
                StreamingNumberedCommandToken("paste", range: instant),
                StreamingNumberedCommandToken("two", range: instant),
            ]
        )

        XCTAssertEqual(try commands(in: scanner.ingest(observation)), [.pasteNumber(2)])
        XCTAssertTrue(scanner.ingest(observation).mutations.isEmpty)
    }

    func testCommittedInstantCandidateDeduplicatesExpandedFinalTokenRanges() throws {
        var scanner = StreamingNumberedCommandScanner()
        let first = scanner.ingest(
            StreamingNumberedCommandSegment(
                range: timeRange(0, 2),
                tokens: [
                    StreamingNumberedCommandToken(
                        "paste",
                        range: timeRange(1.8, 1.8)
                    ),
                    StreamingNumberedCommandToken(
                        "ten",
                        range: timeRange(1.8, 1.8)
                    ),
                ]
            )
        )
        let id = try XCTUnwrap(upserts(in: first).first?.id)
        scanner.markCommitted(id)

        let final = scanner.ingest(
            StreamingNumberedCommandSegment(
                range: timeRange(0, 2),
                tokens: [
                    StreamingNumberedCommandToken(
                        "paste",
                        range: timeRange(0.35, 0.6)
                    ),
                    StreamingNumberedCommandToken(
                        "ten",
                        range: timeRange(0.62, 0.9)
                    ),
                ],
                finalizationTime: time(2),
                isFinal: true
            )
        )

        XCTAssertTrue(final.mutations.isEmpty)
    }

    func testOneRunToTwoRunsKeepsCommittedIdentityWhenTimingMoves() throws {
        var scanner = StreamingNumberedCommandScanner()
        let first = scanner.ingest(
            StreamingNumberedCommandSegment(
                range: timeRange(0, 2),
                tokens: [
                    StreamingNumberedCommandToken(
                        "paste ten",
                        range: timeRange(1.8, 1.8)
                    ),
                ]
            )
        )
        let id = try XCTUnwrap(upserts(in: first).first?.id)
        scanner.markCommitted(id)

        let final = scanner.ingest(
            StreamingNumberedCommandSegment(
                range: timeRange(0, 2),
                tokens: [
                    token("paste", 0.35, 0.6),
                    token("ten", 0.62, 0.9),
                ],
                finalizationTime: time(2),
                isFinal: true
            )
        )

        XCTAssertTrue(final.mutations.isEmpty)
    }

    func testBroadVolatileCommandDeduplicatesFinalPartition() throws {
        var scanner = StreamingNumberedCommandScanner()
        let volatile = scanner.ingest(
            StreamingNumberedCommandSegment(
                range: timeRange(0, 1.665),
                tokens: [
                    StreamingNumberedCommandToken(
                        "okay please paste ten now",
                        range: timeRange(0, 1.665)
                    ),
                ]
            )
        )
        let id = try XCTUnwrap(upserts(in: volatile).first?.id)
        scanner.markCommitted(id)

        XCTAssertTrue(
            scanner.ingest(
                StreamingNumberedCommandSegment(
                    range: timeRange(0, 0.660),
                    tokens: [token("okay", 0, 0.540), token("please", 0.540, 0.660)],
                    finalizationTime: time(0.660),
                    isFinal: true
                )
            ).mutations.isEmpty
        )
        XCTAssertTrue(
            scanner.ingest(
                StreamingNumberedCommandSegment(
                    range: timeRange(0.660, 1.320),
                    tokens: [token("paste", 0.660, 1.140), token("ten", 1.140, 1.320)],
                    finalizationTime: time(1.320),
                    isFinal: true
                )
            ).mutations.isEmpty
        )
        XCTAssertTrue(
            scanner.ingest(
                StreamingNumberedCommandSegment(
                    range: timeRange(1.320, 1.665),
                    tokens: [token("now", 1.320, 1.665)],
                    finalizationTime: time(1.665),
                    isFinal: true
                )
            ).mutations.isEmpty
        )
    }

    func testFinalPartitionCanRevealARealSecondRepeatedCommand() throws {
        var scanner = StreamingNumberedCommandScanner()
        let volatile = scanner.ingest(
            StreamingNumberedCommandSegment(
                range: timeRange(0, 2),
                tokens: [
                    StreamingNumberedCommandToken(
                        "paste ten",
                        range: timeRange(0, 2)
                    ),
                ]
            )
        )
        let firstID = try XCTUnwrap(upserts(in: volatile).first?.id)
        scanner.markCommitted(firstID)

        XCTAssertTrue(
            scanner.ingest(
                StreamingNumberedCommandSegment(
                    range: timeRange(0, 0.8),
                    tokens: [token("paste", 0.2, 0.4), token("ten", 0.42, 0.6)],
                    finalizationTime: time(0.8),
                    isFinal: true
                )
            ).mutations.isEmpty
        )

        let second = scanner.ingest(
            StreamingNumberedCommandSegment(
                range: timeRange(1, 2),
                tokens: [token("paste", 1.2, 1.4), token("ten", 1.42, 1.6)],
                finalizationTime: time(2),
                isFinal: true
            )
        )
        let secondCandidate = try XCTUnwrap(upserts(in: second).first)
        XCTAssertEqual(secondCandidate.command, .pasteNumber(10))
        XCTAssertNotEqual(secondCandidate.id, firstID)
    }

    func testAdjacentRepeatedCommandAtPriorPointRangeGetsANewIdentity() throws {
        var scanner = StreamingNumberedCommandScanner()
        let point = timeRange(1, 1)
        let first = scanner.ingest(
            StreamingNumberedCommandSegment(
                range: timeRange(0, 1),
                tokens: [
                    StreamingNumberedCommandToken("paste", range: point),
                    StreamingNumberedCommandToken("two", range: point),
                ],
                finalizationTime: time(1),
                isFinal: true
            )
        )
        let firstID = try XCTUnwrap(upserts(in: first).first?.id)
        scanner.markCommitted(firstID)

        let second = scanner.ingest(
            StreamingNumberedCommandSegment(
                range: timeRange(1, 2),
                tokens: [
                    StreamingNumberedCommandToken("paste", range: point),
                    StreamingNumberedCommandToken("two", range: point),
                ]
            )
        )
        let secondCandidate = try XCTUnwrap(upserts(in: second).first)

        XCTAssertEqual(secondCandidate.command, .pasteNumber(2))
        XCTAssertNotEqual(secondCandidate.id, firstID)
    }

    func testIdenticalRepeatedCommandsHaveDistinctIDs() throws {
        var scanner = StreamingNumberedCommandScanner()
        let update = scanner.ingest(
            segment(0...2, words: ["paste", "two", "paste", "two"])
        )
        let candidates = upserts(in: update)

        XCTAssertEqual(candidates.map(\.command), [.pasteNumber(2), .pasteNumber(2)])
        XCTAssertEqual(Set(candidates.map(\.id)).count, 2)
    }

    func testUsesTokenRangesAndMinimumConfidence() throws {
        var scanner = StreamingNumberedCommandScanner()
        let update = scanner.ingest(
            StreamingNumberedCommandSegment(
                range: timeRange(0, 2),
                tokens: [
                    StreamingNumberedCommandToken(
                        "copy",
                        range: timeRange(0.5, 0.8),
                        confidence: 0.91
                    ),
                    StreamingNumberedCommandToken(
                        "ten",
                        range: timeRange(0.82, 1.1),
                        confidence: 0.73
                    ),
                ]
            )
        )
        let candidate = try XCTUnwrap(upserts(in: update).first)

        XCTAssertEqual(candidate.range, timeRange(0.5, 1.1))
        XCTAssertEqual(candidate.minimumConfidence, 0.73)
    }

    private func segment(
        _ seconds: ClosedRange<Double>,
        words: [String],
        finalizationTime: Double? = nil,
        isFinal: Bool = false
    ) -> StreamingNumberedCommandSegment {
        StreamingNumberedCommandSegment(
            range: timeRange(seconds.lowerBound, seconds.upperBound),
            tokens: words.map { StreamingNumberedCommandToken($0) },
            finalizationTime: finalizationTime.map(time) ?? .invalid,
            isFinal: isFinal
        )
    }

    private func timeRange(_ start: Double, _ end: Double) -> SpeechResultRange {
        SpeechResultRange(start: time(start), end: time(end))
    }

    private func token(
        _ text: String,
        _ start: Double,
        _ end: Double
    ) -> StreamingNumberedCommandToken {
        StreamingNumberedCommandToken(text, range: timeRange(start, end))
    }

    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 1_000)
    }

    private func upserts(
        in update: StreamingNumberedCommandScannerUpdate
    ) -> [StreamingNumberedCommandCandidate] {
        update.mutations.compactMap { mutation in
            guard case .upsert(let candidate) = mutation else { return nil }
            return candidate
        }
    }

    private func commands(
        in update: StreamingNumberedCommandScannerUpdate
    ) throws -> [VoiceCommand] {
        upserts(in: update).map(\.command)
    }
}
