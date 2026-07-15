import CoreMedia
import XCTest

final class StreamingVoiceCommandScannerTests: XCTestCase {
    func testFindsCopyTenAmidFiller() throws {
        var scanner = StreamingVoiceCommandScanner()
        let update = scanner.ingest(
            segment(
                0...3,
                words: ["hmm", "this", "is", "important", "copy", "10", "please"]
            )
        )

        XCTAssertEqual(try commands(in: update), [.copyNumber(10)])
    }

    func testFindsMultipleCommandsInOneSegmentInAudioOrder() throws {
        var scanner = StreamingVoiceCommandScanner()
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

    func testFindsTemporaryNamedCopyAndPasteAmidFiller() throws {
        var scanner = StreamingVoiceCommandScanner()
        let update = scanner.ingest(
            segment(
                0...4,
                words: [
                    "hmm", "copy", "house", "and", "paste", "house", "please",
                ]
            )
        )

        XCTAssertEqual(
            try commands(in: update),
            [.copyNamed("house"), .pasteNamed("house")]
        )
    }

    func testFindsRequestedMultiwordTemporaryCopies() throws {
        for words in [
            ["my", "new", "york", "address"],
            ["this", "first", "paragraph"],
            ["green", "grapes", "passage"],
        ] {
            var scanner = StreamingVoiceCommandScanner()
            let update = scanner.ingest(
                segment(0...2, words: ["copy"] + words)
            )
            let candidate = try XCTUnwrap(upserts(in: update).first)

            XCTAssertEqual(
                candidate.command,
                .copyNamed(words.joined(separator: " "))
            )
            XCTAssertTrue(candidate.isReadyForDispatch)
        }
    }

    func testMultiwordTemporaryCopyGrowsUnderOneIdentity() throws {
        var scanner = StreamingVoiceCommandScanner()
        let first = scanner.ingest(
            StreamingVoiceCommandSegment(
                range: timeRange(0, 2),
                tokens: [
                    token("copy", 0.10, 0.30),
                    token("my", 0.31, 0.50),
                ]
            )
        )
        let initial = try XCTUnwrap(upserts(in: first).first)
        XCTAssertEqual(initial.command, .copyNamed("my"))
        XCTAssertTrue(initial.isReadyForDispatch)
        XCTAssertFalse(initial.isStableForCommit)

        let expanded = scanner.ingest(
            StreamingVoiceCommandSegment(
                range: timeRange(0, 2),
                tokens: [
                    token("copy", 0.10, 0.30),
                    token("my", 0.31, 0.50),
                    token("new", 0.51, 0.70),
                    token("york", 0.71, 0.90),
                    token("address", 0.91, 1.20),
                ]
            )
        )
        let complete = try XCTUnwrap(upserts(in: expanded).first)

        XCTAssertEqual(complete.id, initial.id)
        XCTAssertEqual(complete.command, .copyNamed("my new york address"))
        XCTAssertTrue(complete.isReadyForDispatch)
        XCTAssertFalse(complete.isStableForCommit)
    }

    func testKnownMultiwordPasteUsesVolatileFastPath() throws {
        var scanner = StreamingVoiceCommandScanner()
        let update = scanner.ingest(
            segment(
                0...2,
                words: ["paste", "my", "new", "york", "address"]
            ),
            knownNamedCopies: ["my new york address"]
        )
        let candidate = try XCTUnwrap(upserts(in: update).first)

        XCTAssertEqual(candidate.command, .pasteNamed("my new york address"))
        XCTAssertTrue(candidate.isReadyForDispatch)
    }

    func testMultiwordCopyAndPasteRemainSeparateInContinuousSpeech() throws {
        var scanner = StreamingVoiceCommandScanner()
        let update = scanner.ingest(
            segment(
                0...4,
                words: [
                    "copy", "green", "grapes", "passage", "and",
                    "paste", "green", "grapes", "passage",
                ]
            )
        )

        XCTAssertEqual(
            try commands(in: update),
            [
                .copyNamed("green grapes passage"),
                .pasteNamed("green grapes passage"),
            ]
        )
    }

    func testNamedCopyDispatchesVolatileResultAndKeepsIdentityAcrossRevisions() throws {
        var scanner = StreamingVoiceCommandScanner()
        let first = scanner.ingest(
            StreamingVoiceCommandSegment(
                range: timeRange(0, 1),
                tokens: [
                    token("copy", 0.10, 0.30),
                    token("G", 0.31, 0.45),
                ]
            )
        )
        let partial = try XCTUnwrap(upserts(in: first).first)

        XCTAssertEqual(partial.command, .copyNamed("g"))
        XCTAssertTrue(partial.isReadyForDispatch)
        XCTAssertFalse(partial.isStableForCommit)

        let revision = scanner.ingest(
            StreamingVoiceCommandSegment(
                range: timeRange(0, 1),
                tokens: [
                    token("copy", 0.10, 0.30),
                    token("GitHub", 0.31, 0.90),
                ]
            )
        )
        let completedWord = try XCTUnwrap(upserts(in: revision).first)

        XCTAssertEqual(completedWord.id, partial.id)
        XCTAssertEqual(completedWord.command, .copyNamed("github"))
        XCTAssertTrue(completedWord.isReadyForDispatch)
        XCTAssertFalse(completedWord.isStableForCommit)

        let finalized = scanner.advanceFinalization(
            to: time(1)
        )
        let stable = try XCTUnwrap(upserts(in: finalized).first)
        XCTAssertEqual(stable.id, partial.id)
        XCTAssertEqual(stable.command, .copyNamed("github"))
        XCTAssertTrue(stable.isReadyForDispatch)
        XCTAssertTrue(stable.isStableForCommit)
    }

    func testExplicitVolatileBoundaryDoesNotDelayOrDuplicateNamedCopy() throws {
        for name in ["point", "pointer", "house"] {
            var scanner = StreamingVoiceCommandScanner()
            let pendingUpdate = scanner.ingest(
                StreamingVoiceCommandSegment(
                    range: timeRange(0, 1),
                    tokens: [
                        token("copy", 0.10, 0.30),
                        token(name, 0.31, 0.90),
                    ]
                )
            )
            let immediate = try XCTUnwrap(upserts(in: pendingUpdate).first)
            XCTAssertEqual(immediate.command, .copyNamed(name))
            XCTAssertTrue(immediate.isReadyForDispatch)
            XCTAssertFalse(immediate.isStableForCommit)

            let boundaryUpdate = scanner.ingest(
                StreamingVoiceCommandSegment(
                    range: timeRange(0, 1),
                    tokens: [
                        token("copy", 0.10, 0.30),
                        token("\(name).", 0.31, 0.90),
                    ],
                    hasTrailingPhraseBoundary: true
                )
            )
            let stable = try XCTUnwrap(upserts(in: boundaryUpdate).first)
            XCTAssertEqual(stable.id, immediate.id)
            XCTAssertEqual(stable.command, .copyNamed(name))
            XCTAssertTrue(stable.isReadyForDispatch)
            XCTAssertTrue(stable.isStableForCommit)
        }
    }

    func testPointRevisesToPointerWithoutWaitingForVolatileBoundary() throws {
        var scanner = StreamingVoiceCommandScanner()
        let partialUpdate = scanner.ingest(
            StreamingVoiceCommandSegment(
                range: timeRange(0, 1),
                tokens: [
                    token("copy", 0.10, 0.30),
                    token("point", 0.31, 0.70),
                ]
            )
        )
        let partial = try XCTUnwrap(upserts(in: partialUpdate).first)
        XCTAssertEqual(partial.command, .copyNamed("point"))
        XCTAssertTrue(partial.isReadyForDispatch)
        XCTAssertFalse(partial.isStableForCommit)

        let completedUpdate = scanner.ingest(
            StreamingVoiceCommandSegment(
                range: timeRange(0, 1),
                tokens: [
                    token("copy", 0.10, 0.30),
                    token("pointer.", 0.31, 0.90),
                ],
                hasTrailingPhraseBoundary: true
            )
        )
        let completed = try XCTUnwrap(upserts(in: completedUpdate).first)
        XCTAssertEqual(completed.id, partial.id)
        XCTAssertEqual(completed.command, .copyNamed("pointer"))
        XCTAssertTrue(completed.isReadyForDispatch)
        XCTAssertTrue(completed.isStableForCommit)
    }

    func testNamedCopyDoesNotWaitForEnclosingResultFinalization() throws {
        var scanner = StreamingVoiceCommandScanner()
        let update = scanner.ingest(
            StreamingVoiceCommandSegment(
                range: timeRange(0, 1),
                tokens: [
                    token("copy", 0.10, 0.30),
                    token("portfolio", 0.31, 0.90),
                ],
                finalizationTime: time(0.60)
            )
        )

        let candidate = try XCTUnwrap(upserts(in: update).first)
        XCTAssertTrue(candidate.isReadyForDispatch)
        XCTAssertFalse(candidate.isStableForCommit)
    }

    func testShortNamesDispatchWhileVolatileAndFinalizationDoesNotDuplicate() throws {
        for partialName in ["G", "GET", "Sum"] {
            var scanner = StreamingVoiceCommandScanner()
            let update = scanner.ingest(
                StreamingVoiceCommandSegment(
                    range: timeRange(0, 1.20),
                    tokens: [
                        token("copy", 0.10, 0.30),
                        token(partialName, 0.31, 0.55),
                    ],
                    finalizationTime: time(0.70)
                )
            )
            let candidate = try XCTUnwrap(upserts(in: update).first)

            XCTAssertTrue(
                candidate.isReadyForDispatch,
                "A complete volatile named command should dispatch without waiting for finalization"
            )
            XCTAssertFalse(candidate.isStableForCommit)

            let finalizationUpdate = scanner.advanceFinalization(to: time(1.20))
            let stable = try XCTUnwrap(upserts(in: finalizationUpdate).first)
            XCTAssertEqual(stable.id, candidate.id)
            XCTAssertTrue(stable.isReadyForDispatch)
            XCTAssertTrue(stable.isStableForCommit)
        }
    }

    func testNamedCopyRevisionsStayImmediateAcrossArbitraryWordShapes() throws {
        let revisions = [
            (partial: "port", complete: "portfolio"),
            (partial: "note", complete: "notebook"),
            (partial: "auth", complete: "authentication"),
            (partial: "water", complete: "waterfall"),
        ]

        for revisionWords in revisions {
            var scanner = StreamingVoiceCommandScanner()
            let partialUpdate = scanner.ingest(
                StreamingVoiceCommandSegment(
                    range: timeRange(0, 1.20),
                    tokens: [
                        token("copy", 0.10, 0.30),
                        token(revisionWords.partial, 0.31, 0.55),
                    ],
                    finalizationTime: time(0.70)
                )
            )
            let partial = try XCTUnwrap(upserts(in: partialUpdate).first)
            XCTAssertTrue(partial.isReadyForDispatch)
            XCTAssertFalse(partial.isStableForCommit)

            let completeUpdate = scanner.ingest(
                StreamingVoiceCommandSegment(
                    range: timeRange(0, 1.20),
                    tokens: [
                        token("copy", 0.10, 0.30),
                        token(revisionWords.complete, 0.31, 0.95),
                    ],
                    finalizationTime: time(0.70)
                )
            )
            let complete = try XCTUnwrap(upserts(in: completeUpdate).first)
            XCTAssertEqual(complete.id, partial.id)
            XCTAssertEqual(complete.command, .copyNamed(revisionWords.complete))
            XCTAssertTrue(complete.isReadyForDispatch)
            XCTAssertFalse(complete.isStableForCommit)

            let finalizationUpdate = scanner.advanceFinalization(to: time(1.20))
            let stable = try XCTUnwrap(upserts(in: finalizationUpdate).first)
            XCTAssertEqual(stable.id, partial.id)
            XCTAssertEqual(stable.command, .copyNamed(revisionWords.complete))
            XCTAssertTrue(stable.isReadyForDispatch)
            XCTAssertTrue(stable.isStableForCommit)
        }
    }

    func testSummaryRevisionDoesNotWaitForResultFinalization() throws {
        var scanner = StreamingVoiceCommandScanner()
        let partialUpdate = scanner.ingest(
            StreamingVoiceCommandSegment(
                range: timeRange(0, 1.20),
                tokens: [
                    token("copy", 0.10, 0.30),
                    token("Sum", 0.31, 0.55),
                ],
                finalizationTime: time(0.70)
            )
        )
        let partial = try XCTUnwrap(upserts(in: partialUpdate).first)
        XCTAssertEqual(partial.command, .copyNamed("sum"))
        XCTAssertTrue(partial.isReadyForDispatch)
        XCTAssertFalse(partial.isStableForCommit)

        let revisionUpdate = scanner.ingest(
            StreamingVoiceCommandSegment(
                range: timeRange(0, 1.20),
                tokens: [
                    token("copy", 0.10, 0.30),
                    token("Summary", 0.31, 0.95),
                ],
                finalizationTime: time(0.70)
            )
        )
        let revision = try XCTUnwrap(upserts(in: revisionUpdate).first)
        XCTAssertEqual(revision.id, partial.id)
        XCTAssertEqual(revision.command, .copyNamed("summary"))
        XCTAssertTrue(revision.isReadyForDispatch)
        XCTAssertFalse(revision.isStableForCommit)

        let finalizationUpdate = scanner.advanceFinalization(to: time(1.20))
        let stable = try XCTUnwrap(upserts(in: finalizationUpdate).first)
        XCTAssertEqual(stable.id, partial.id)
        XCTAssertEqual(stable.command, .copyNamed("summary"))
        XCTAssertTrue(stable.isReadyForDispatch)
        XCTAssertTrue(stable.isStableForCommit)
    }

    func testExternalFinalizationCanArriveBeforeTheTextResult() throws {
        var scanner = StreamingVoiceCommandScanner()
        XCTAssertTrue(
            scanner.advanceFinalization(to: time(1)).mutations.isEmpty
        )

        let update = scanner.ingest(
            StreamingVoiceCommandSegment(
                range: timeRange(0, 1),
                tokens: [
                    token("copy", 0.10, 0.30),
                    token("github", 0.31, 0.90),
                ]
            )
        )
        let candidate = try XCTUnwrap(upserts(in: update).first)

        XCTAssertEqual(candidate.command, .copyNamed("github"))
        XCTAssertTrue(candidate.isReadyForDispatch)
    }

    func testFinalNamedResultWithoutTokenRangesIsReady() throws {
        var scanner = StreamingVoiceCommandScanner()
        let update = scanner.ingest(
            segment(0...1, words: ["copy", "summary"], isFinal: true)
        )

        let candidate = try XCTUnwrap(upserts(in: update).first)
        XCTAssertEqual(candidate.command, .copyNamed("summary"))
        XCTAssertTrue(candidate.isReadyForDispatch)
    }

    func testHighConfidenceKnownNameUsesVolatilePasteFastPath() throws {
        var scanner = StreamingVoiceCommandScanner()
        let update = scanner.ingest(
            StreamingVoiceCommandSegment(
                range: timeRange(0, 1),
                tokens: [
                    token("paste", 0.10, 0.30, confidence: 0.9),
                    token("house", 0.31, 0.80, confidence: 0.9),
                ]
            ),
            knownNamedCopies: ["house"]
        )
        let candidate = try XCTUnwrap(upserts(in: update).first)

        XCTAssertEqual(candidate.command, .pasteNamed("house"))
        XCTAssertTrue(candidate.isReadyForDispatch)
    }

    func testVolatileNamedPasteWaitsWhenStoredNameHasLongerPrefix() throws {
        var scanner = StreamingVoiceCommandScanner()
        let update = scanner.ingest(
            StreamingVoiceCommandSegment(
                range: timeRange(0, 1),
                tokens: [
                    token("paste", 0.10, 0.30, confidence: 0.9),
                    token("sum", 0.31, 0.80, confidence: 0.9),
                ]
            ),
            knownNamedCopies: ["sum", "summary"]
        )
        let candidate = try XCTUnwrap(upserts(in: update).first)

        XCTAssertEqual(candidate.command, .pasteNamed("sum"))
        XCTAssertFalse(candidate.isReadyForDispatch)
    }

    func testVolatilePasteQueuesBehindEarlierCopyOfPreviouslyUnknownName() throws {
        var scanner = StreamingVoiceCommandScanner()
        let update = scanner.ingest(
            StreamingVoiceCommandSegment(
                range: timeRange(0, 2),
                tokens: [
                    token("copy", 0.10, 0.30, confidence: 0.9),
                    token("house", 0.31, 0.70, confidence: 0.9),
                    token("paste", 1.00, 1.20, confidence: 0.9),
                    token("house", 1.21, 1.60, confidence: 0.9),
                ]
            )
        )
        let candidates = upserts(in: update)
        let paste = try XCTUnwrap(
            candidates.first { $0.command == .pasteNamed("house") }
        )

        XCTAssertTrue(paste.isReadyForDispatch)
    }

    func testKnownNamedPasteWithoutConfidenceDispatchesBeforeFinalization() throws {
        var scanner = StreamingVoiceCommandScanner()
        let immediate = scanner.ingest(
            StreamingVoiceCommandSegment(
                range: timeRange(0, 1),
                tokens: [
                    token("paste", 0.10, 0.30),
                    token("house", 0.31, 0.80),
                ]
            ),
            knownNamedCopies: ["house"]
        )
        let candidate = try XCTUnwrap(upserts(in: immediate).first)
        XCTAssertTrue(candidate.isReadyForDispatch)
        scanner.markCommitted(candidate.id)

        let finalEcho = scanner.ingest(
            StreamingVoiceCommandSegment(
                range: timeRange(0, 1),
                tokens: [
                    token("paste", 0.10, 0.30),
                    token("house", 0.31, 0.80),
                ],
                finalizationTime: time(1)
            ),
            knownNamedCopies: ["house"]
        )
        XCTAssertTrue(finalEcho.mutations.isEmpty)
    }

    func testNumberedCommandKeepsVolatileFastPath() throws {
        var scanner = StreamingVoiceCommandScanner()
        let update = scanner.ingest(segment(0...1, words: ["copy", "two"]))

        let candidate = try XCTUnwrap(upserts(in: update).first)
        XCTAssertEqual(candidate.command, .copyNumber(2))
        XCTAssertTrue(candidate.isReadyForDispatch)
    }

    func testUnknownNamedPasteIsIgnored() {
        var scanner = StreamingVoiceCommandScanner()
        let update = scanner.ingest(
            segment(0...2, words: ["please", "paste", "unknown"])
        )

        XCTAssertTrue(update.mutations.isEmpty)
    }

    func testRecognizesPasteVerbAliasesWithCaseAndPunctuation() throws {
        let aliases = [
            "pasting", "peace", "Pace", "hase", "pase", "pay", "pae", "Taste",
        ]
        var words: [String] = []
        for alias in aliases {
            words.append(contentsOf: ["\(alias.uppercased())...", "TWO?!", "then"])
        }

        var scanner = StreamingVoiceCommandScanner()
        let update = scanner.ingest(segment(0...8, words: words))

        XCTAssertEqual(
            try commands(in: update),
            Array(repeating: VoiceCommand.pasteNumber(2), count: aliases.count)
        )
    }

    func testPermanentCopyNumberDoesNotFallThroughToTemporaryCopy() {
        for modifier in ["permanent", "permanently", "permanny"] {
            var scanner = StreamingVoiceCommandScanner()
            let update = scanner.ingest(
                segment(0...2, words: [modifier, "copy", "one"])
            )
            XCTAssertTrue(
                update.mutations.isEmpty,
                "Expected \(modifier) copy one to avoid temporary slot 1"
            )
        }
    }

    func testPermanentNamedCopyUsesImmediateRevisableNamedPath() throws {
        var scanner = StreamingVoiceCommandScanner()
        let pending = scanner.ingest(
            StreamingVoiceCommandSegment(
                range: timeRange(0, 1.2),
                tokens: [
                    token("permanent", 0.10, 0.35),
                    token("copy", 0.36, 0.60),
                    token("house", 0.61, 1.05),
                ]
            )
        )
        let pendingCandidate = try XCTUnwrap(upserts(in: pending).first)
        XCTAssertEqual(pendingCandidate.command, .permanentCopy("house"))
        XCTAssertTrue(pendingCandidate.isReadyForDispatch)
        XCTAssertFalse(pendingCandidate.isStableForCommit)

        let finalized = scanner.advanceFinalization(to: time(1.20))
        let readyCandidate = try XCTUnwrap(upserts(in: finalized).first)
        XCTAssertEqual(readyCandidate.id, pendingCandidate.id)
        XCTAssertEqual(readyCandidate.command, .permanentCopy("house"))
        XCTAssertTrue(readyCandidate.isReadyForDispatch)
        XCTAssertTrue(readyCandidate.isStableForCommit)
    }

    func testPermanentFinalWordPartitionReleasesWithoutWholePhraseResult() throws {
        var scanner = StreamingVoiceCommandScanner()
        XCTAssertTrue(
            scanner.ingest(
                segment(
                    0...0.4,
                    words: ["permanent"],
                    finalizationTime: 0.4,
                    isFinal: true
                )
            ).mutations.isEmpty
        )
        XCTAssertTrue(
            scanner.ingest(
                segment(
                    0.4...0.8,
                    words: ["copy"],
                    finalizationTime: 0.8,
                    isFinal: true
                )
            ).mutations.isEmpty
        )

        let namePartition = scanner.ingest(
            segment(
                0.8...1.2,
                words: ["house"],
                finalizationTime: 1.2,
                isFinal: true
            )
        )
        let candidate = try XCTUnwrap(upserts(in: namePartition).first)

        XCTAssertEqual(candidate.command, .permanentCopy("house"))
        XCTAssertTrue(candidate.isReadyForDispatch)
    }

    func testPermanentModifierAliasesUsePermanentTokenPath() throws {
        for modifier in ["permanent", "permanently", "permanny"] {
            var scanner = StreamingVoiceCommandScanner()
            let update = scanner.ingest(
                segment(
                    0...1.2,
                    words: [modifier, "copy", "house"],
                    isFinal: true
                )
            )
            let candidate = try XCTUnwrap(upserts(in: update).first)
            XCTAssertEqual(candidate.command, .permanentCopy("house"))
            XCTAssertTrue(candidate.isReadyForDispatch)
        }
    }

    func testCanonicalPermanentPhraseCanUseOneAttributedToken() throws {
        var scanner = StreamingVoiceCommandScanner()
        let update = scanner.ingest(
            StreamingVoiceCommandSegment(
                range: timeRange(0, 1.2),
                tokens: [
                    token("permanent copy name", 0.10, 1.05),
                ],
                isFinal: true
            )
        )

        let candidate = try XCTUnwrap(upserts(in: update).first)
        XCTAssertEqual(candidate.command, .permanentCopy("name"))
        XCTAssertTrue(candidate.isReadyForDispatch)
    }

    func testNextCommandImmediatelyClosesPendingPermanentName() throws {
        var scanner = StreamingVoiceCommandScanner()
        let update = scanner.ingest(
            segment(
                0...2.4,
                words: [
                    "permanent", "copy", "name",
                    "permanent", "copy", "named",
                ]
            )
        )
        let candidates = upserts(in: update)

        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(candidates[0].command, .permanentCopy("name"))
        XCTAssertTrue(candidates[0].isReadyForDispatch)
        XCTAssertEqual(candidates[1].command, .permanentCopy("named"))
        XCTAssertTrue(candidates[1].isReadyForDispatch)
    }

    func testRepeatedCanonicalPermanentResultsCreateDistinctImmediateAttempts() throws {
        var scanner = StreamingVoiceCommandScanner()
        let first = scanner.ingest(
            StreamingVoiceCommandSegment(
                range: timeRange(0, 1.1),
                tokens: [
                    token("permanent copy named", 0.05, 1.05),
                ],
                isFinal: false
            )
        )
        let firstCandidate = try XCTUnwrap(upserts(in: first).first)
        XCTAssertEqual(firstCandidate.command, .permanentCopy("named"))
        XCTAssertTrue(firstCandidate.isReadyForDispatch)

        let retry = scanner.ingest(
            StreamingVoiceCommandSegment(
                range: timeRange(1.15, 2.25),
                tokens: [
                    token("permanent copy name", 1.20, 2.20),
                ],
                isFinal: false
            )
        )
        let candidates = upserts(in: retry)

        let retryCandidate = try XCTUnwrap(candidates.first)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertNotEqual(retryCandidate.id, firstCandidate.id)
        XCTAssertEqual(retryCandidate.command, .permanentCopy("name"))
        XCTAssertTrue(retryCandidate.isReadyForDispatch)
    }

    func testAndThenCommandClosesPendingPermanentName() throws {
        var scanner = StreamingVoiceCommandScanner()
        let update = scanner.ingest(
            segment(
                0...2,
                words: [
                    "permanent", "copy", "house",
                    "and", "copy", "one",
                ]
            )
        )
        let candidates = upserts(in: update)

        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(candidates[0].command, .permanentCopy("house"))
        XCTAssertTrue(candidates[0].isReadyForDispatch)
        XCTAssertEqual(candidates[1].command, .copyNumber(1))
        XCTAssertTrue(candidates[1].isReadyForDispatch)
    }

    func testPermanentMultiwordNameUsesSameAccumulatorAsTemporaryName() throws {
        var scanner = StreamingVoiceCommandScanner()
        let initialUpdate = scanner.ingest(
            StreamingVoiceCommandSegment(
                range: timeRange(0, 2),
                tokens: [
                    token("permanent", 0.10, 0.25),
                    token("copy", 0.26, 0.40),
                    token("my", 0.41, 0.55),
                ]
            )
        )
        let initial = try XCTUnwrap(upserts(in: initialUpdate).first)
        XCTAssertEqual(initial.command, .permanentCopy("my"))
        XCTAssertTrue(initial.isReadyForDispatch)
        XCTAssertFalse(initial.isStableForCommit)

        let expandedUpdate = scanner.ingest(
            StreamingVoiceCommandSegment(
                range: timeRange(0, 2),
                tokens: [
                    token("permanent", 0.10, 0.25),
                    token("copy", 0.26, 0.40),
                    token("my", 0.41, 0.55),
                    token("very", 0.56, 0.70),
                    token("important", 0.71, 0.85),
                    token("home", 0.86, 1.00),
                    token("address", 1.01, 1.20),
                ]
            )
        )
        let expanded = try XCTUnwrap(upserts(in: expandedUpdate).first)

        XCTAssertEqual(expanded.id, initial.id)
        XCTAssertEqual(
            expanded.command,
            .permanentCopy("my very important home address")
        )
        XCTAssertTrue(expanded.isReadyForDispatch)
        XCTAssertFalse(expanded.isStableForCommit)
    }

    func testMultiwordPermanentCopyAndFollowingCommandRemainSeparate() throws {
        var scanner = StreamingVoiceCommandScanner()
        let update = scanner.ingest(
            segment(
                0...3,
                words: [
                    "permanent", "copy", "my", "new", "york", "address",
                    "and", "copy", "one",
                ],
                isFinal: true
            )
        )
        let candidates = upserts(in: update)

        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(
            candidates[0].command,
            .permanentCopy("my new york address")
        )
        XCTAssertEqual(candidates[1].command, .copyNumber(1))
        XCTAssertTrue(candidates.allSatisfy(\.isReadyForDispatch))
    }

    func testRecognizesScopedNumberAliasesAndAllSlots() throws {
        let spoken = ["won", "too", "three", "fore", "five", "six", "seven", "ate", "nine", "ten"]
        var words: [String] = []
        for word in spoken {
            words.append(contentsOf: ["copy", word, "then"])
        }

        var scanner = StreamingVoiceCommandScanner()
        let update = scanner.ingest(segment(0...10, words: words))
        XCTAssertEqual(
            try commands(in: update),
            (1...10).map(VoiceCommand.copyNumber)
        )
    }

    func testBridgesVerbAndNumberAcrossAdjacentSegments() throws {
        var scanner = StreamingVoiceCommandScanner(maximumCrossSegmentGap: 0.5)
        XCTAssertTrue(
            scanner.ingest(segment(0...1, words: ["please", "copy"])).mutations.isEmpty
        )

        let update = scanner.ingest(segment(1.2...1.7, words: ["ten", "now"]))
        XCTAssertEqual(try commands(in: update), [.copyNumber(10)])
    }

    func testDoesNotBridgeAcrossAnUnboundedPause() {
        var scanner = StreamingVoiceCommandScanner(maximumCrossSegmentGap: 0.5)
        _ = scanner.ingest(segment(0...1, words: ["copy"]))

        XCTAssertTrue(
            scanner.ingest(segment(1.6...2, words: ["two"])).mutations.isEmpty
        )
    }

    func testRevisionKeepsIDAndUpdatesNumber() throws {
        var scanner = StreamingVoiceCommandScanner()
        let first = scanner.ingest(segment(0...1, words: ["paste", "two"]))
        let firstCandidate = try XCTUnwrap(upserts(in: first).first)

        let revision = scanner.ingest(segment(0...1, words: ["paste", "three"]))
        let revisedCandidate = try XCTUnwrap(upserts(in: revision).first)

        XCTAssertEqual(revisedCandidate.id, firstCandidate.id)
        XCTAssertEqual(revisedCandidate.command, .pasteNumber(3))
    }

    func testDisappearingUncommittedCandidateIsRevoked() throws {
        var scanner = StreamingVoiceCommandScanner()
        let first = scanner.ingest(segment(0...1, words: ["paste", "two"]))
        let id = try XCTUnwrap(upserts(in: first).first?.id)

        let revision = scanner.ingest(segment(0...1, words: ["ordinary", "speech"]))
        XCTAssertEqual(revision.mutations, [.revoke(id)])
    }

    func testRemovingAnEarlierCommandDoesNotChangeTheLaterCommandIdentity() throws {
        var scanner = StreamingVoiceCommandScanner()
        let first = scanner.ingest(
            StreamingVoiceCommandSegment(
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
            StreamingVoiceCommandSegment(
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
        var scanner = StreamingVoiceCommandScanner()
        let first = scanner.ingest(
            StreamingVoiceCommandSegment(
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
            StreamingVoiceCommandSegment(
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
        var scanner = StreamingVoiceCommandScanner()
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
        var scanner = StreamingVoiceCommandScanner()
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
        var scanner = StreamingVoiceCommandScanner()
        let instant = timeRange(0.5, 0.5)
        let observation = StreamingVoiceCommandSegment(
            range: timeRange(0, 1),
            tokens: [
                StreamingVoiceCommandToken("paste", range: instant),
                StreamingVoiceCommandToken("two", range: instant),
            ]
        )

        XCTAssertEqual(try commands(in: scanner.ingest(observation)), [.pasteNumber(2)])
        XCTAssertTrue(scanner.ingest(observation).mutations.isEmpty)
    }

    func testCommittedInstantCandidateDeduplicatesExpandedFinalTokenRanges() throws {
        var scanner = StreamingVoiceCommandScanner()
        let first = scanner.ingest(
            StreamingVoiceCommandSegment(
                range: timeRange(0, 2),
                tokens: [
                    StreamingVoiceCommandToken(
                        "paste",
                        range: timeRange(1.8, 1.8)
                    ),
                    StreamingVoiceCommandToken(
                        "ten",
                        range: timeRange(1.8, 1.8)
                    ),
                ]
            )
        )
        let id = try XCTUnwrap(upserts(in: first).first?.id)
        scanner.markCommitted(id)

        let final = scanner.ingest(
            StreamingVoiceCommandSegment(
                range: timeRange(0, 2),
                tokens: [
                    StreamingVoiceCommandToken(
                        "paste",
                        range: timeRange(0.35, 0.6)
                    ),
                    StreamingVoiceCommandToken(
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
        var scanner = StreamingVoiceCommandScanner()
        let first = scanner.ingest(
            StreamingVoiceCommandSegment(
                range: timeRange(0, 2),
                tokens: [
                    StreamingVoiceCommandToken(
                        "paste ten",
                        range: timeRange(1.8, 1.8)
                    ),
                ]
            )
        )
        let id = try XCTUnwrap(upserts(in: first).first?.id)
        scanner.markCommitted(id)

        let final = scanner.ingest(
            StreamingVoiceCommandSegment(
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
        var scanner = StreamingVoiceCommandScanner()
        let volatile = scanner.ingest(
            StreamingVoiceCommandSegment(
                range: timeRange(0, 1.665),
                tokens: [
                    StreamingVoiceCommandToken(
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
                StreamingVoiceCommandSegment(
                    range: timeRange(0, 0.660),
                    tokens: [token("okay", 0, 0.540), token("please", 0.540, 0.660)],
                    finalizationTime: time(0.660),
                    isFinal: true
                )
            ).mutations.isEmpty
        )
        XCTAssertTrue(
            scanner.ingest(
                StreamingVoiceCommandSegment(
                    range: timeRange(0.660, 1.320),
                    tokens: [token("paste", 0.660, 1.140), token("ten", 1.140, 1.320)],
                    finalizationTime: time(1.320),
                    isFinal: true
                )
            ).mutations.isEmpty
        )
        XCTAssertTrue(
            scanner.ingest(
                StreamingVoiceCommandSegment(
                    range: timeRange(1.320, 1.665),
                    tokens: [token("now", 1.320, 1.665)],
                    finalizationTime: time(1.665),
                    isFinal: true
                )
            ).mutations.isEmpty
        )
    }

    func testFinalPartitionCanRevealARealSecondRepeatedCommand() throws {
        var scanner = StreamingVoiceCommandScanner()
        let volatile = scanner.ingest(
            StreamingVoiceCommandSegment(
                range: timeRange(0, 2),
                tokens: [
                    StreamingVoiceCommandToken(
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
                StreamingVoiceCommandSegment(
                    range: timeRange(0, 0.8),
                    tokens: [token("paste", 0.2, 0.4), token("ten", 0.42, 0.6)],
                    finalizationTime: time(0.8),
                    isFinal: true
                )
            ).mutations.isEmpty
        )

        let second = scanner.ingest(
            StreamingVoiceCommandSegment(
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
        var scanner = StreamingVoiceCommandScanner()
        let point = timeRange(1, 1)
        let first = scanner.ingest(
            StreamingVoiceCommandSegment(
                range: timeRange(0, 1),
                tokens: [
                    StreamingVoiceCommandToken("paste", range: point),
                    StreamingVoiceCommandToken("two", range: point),
                ],
                finalizationTime: time(1),
                isFinal: true
            )
        )
        let firstID = try XCTUnwrap(upserts(in: first).first?.id)
        scanner.markCommitted(firstID)

        let second = scanner.ingest(
            StreamingVoiceCommandSegment(
                range: timeRange(1, 2),
                tokens: [
                    StreamingVoiceCommandToken("paste", range: point),
                    StreamingVoiceCommandToken("two", range: point),
                ]
            )
        )
        let secondCandidate = try XCTUnwrap(upserts(in: second).first)

        XCTAssertEqual(secondCandidate.command, .pasteNumber(2))
        XCTAssertNotEqual(secondCandidate.id, firstID)
    }

    func testIdenticalRepeatedCommandsHaveDistinctIDs() throws {
        var scanner = StreamingVoiceCommandScanner()
        let update = scanner.ingest(
            segment(0...2, words: ["paste", "two", "paste", "two"])
        )
        let candidates = upserts(in: update)

        XCTAssertEqual(candidates.map(\.command), [.pasteNumber(2), .pasteNumber(2)])
        XCTAssertEqual(Set(candidates.map(\.id)).count, 2)
    }

    func testUsesTokenRangesAndMinimumConfidence() throws {
        var scanner = StreamingVoiceCommandScanner()
        let update = scanner.ingest(
            StreamingVoiceCommandSegment(
                range: timeRange(0, 2),
                tokens: [
                    StreamingVoiceCommandToken(
                        "copy",
                        range: timeRange(0.5, 0.8),
                        confidence: 0.91
                    ),
                    StreamingVoiceCommandToken(
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
    ) -> StreamingVoiceCommandSegment {
        StreamingVoiceCommandSegment(
            range: timeRange(seconds.lowerBound, seconds.upperBound),
            tokens: words.map { StreamingVoiceCommandToken($0) },
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
        _ end: Double,
        confidence: Double? = nil
    ) -> StreamingVoiceCommandToken {
        StreamingVoiceCommandToken(
            text,
            range: timeRange(start, end),
            confidence: confidence
        )
    }

    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 1_000)
    }

    private func upserts(
        in update: StreamingVoiceCommandScannerUpdate
    ) -> [StreamingVoiceCommandCandidate] {
        update.mutations.compactMap { mutation in
            guard case .upsert(let candidate) = mutation else { return nil }
            return candidate
        }
    }

    private func commands(
        in update: StreamingVoiceCommandScannerUpdate
    ) throws -> [VoiceCommand] {
        upserts(in: update).map(\.command)
    }
}
