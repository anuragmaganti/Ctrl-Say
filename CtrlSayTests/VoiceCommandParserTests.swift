import XCTest

final class VoiceCommandParserTests: XCTestCase {
    func testPotentialCommandPrefixesAreDetectedWithoutRetainingTranscript() {
        XCTAssertTrue(VoiceCommandParser.isPotentialCommand("cop"))
        XCTAssertTrue(VoiceCommandParser.isPotentialCommand("copy"))
        XCTAssertTrue(VoiceCommandParser.isPotentialCommand("peace"))
        XCTAssertTrue(VoiceCommandParser.isPotentialCommand("TASTE!"))
        XCTAssertTrue(VoiceCommandParser.isPotentialCommand("permanent"))
        XCTAssertFalse(VoiceCommandParser.isPotentialCommand("ordinary dictation"))
    }

    func testNumberedCopyAndPasteAcceptFirstCompleteVolatileResult() {
        for number in VoiceCommandParser.numberedSlotRange {
            for command in [
                VoiceCommand.copyNumber(number),
                VoiceCommand.pasteNumber(number),
            ] {
                XCTAssertTrue(
                    VolatileCommandAcceptancePolicy.accepts(
                        command,
                        confidence: nil,
                        knownNamedCopies: []
                    )
                )
                XCTAssertTrue(
                    VolatileCommandAcceptancePolicy.accepts(
                        command,
                        confidence: 0,
                        knownNamedCopies: []
                    )
                )
            }
        }

        XCTAssertFalse(
            VolatileCommandAcceptancePolicy.accepts(
                .copyNamed("house"),
                confidence: nil,
                knownNamedCopies: []
            )
        )
    }

    func testClearVolatileCommandRequiresMeasuredConfidence() {
        for command in [VoiceCommand.clearTemporary] {
            XCTAssertFalse(
                VolatileCommandAcceptancePolicy.accepts(
                    command,
                    confidence: nil,
                    knownNamedCopies: []
                )
            )
            XCTAssertFalse(
                VolatileCommandAcceptancePolicy.accepts(
                    command,
                    confidence: VolatileCommandAcceptancePolicy.minimumGuardedConfidence - 0.01,
                    knownNamedCopies: []
                )
            )
            XCTAssertTrue(
                VolatileCommandAcceptancePolicy.accepts(
                    command,
                    confidence: VolatileCommandAcceptancePolicy.minimumGuardedConfidence,
                    knownNamedCopies: []
                )
            )
        }
    }

    func testVolatileNamedPasteUsesKnownUnambiguousNameWithoutConfidence() {
        XCTAssertTrue(
            VolatileCommandAcceptancePolicy.accepts(
                .pasteNamed("house"),
                confidence: nil,
                knownNamedCopies: ["house"]
            )
        )
        XCTAssertTrue(
            VolatileCommandAcceptancePolicy.accepts(
                .pasteNamed("house"),
                confidence: VolatileCommandAcceptancePolicy.minimumGuardedConfidence - 0.01,
                knownNamedCopies: ["house"]
            )
        )
        XCTAssertFalse(
            VolatileCommandAcceptancePolicy.accepts(
                .permanentCopy("house"),
                confidence: 0.9,
                knownNamedCopies: ["house"]
            )
        )
        XCTAssertFalse(
            VolatileCommandAcceptancePolicy.accepts(
                .pasteNamed("house"),
                confidence: 0.9,
                knownNamedCopies: ["office"]
            )
        )
        XCTAssertFalse(
            VolatileCommandAcceptancePolicy.accepts(
                .pasteNamed("home"),
                confidence: 0.9,
                knownNamedCopies: ["home", "home office"]
            )
        )
        XCTAssertFalse(
            VolatileCommandAcceptancePolicy.accepts(
                .pasteNamed("sum"),
                confidence: 0.9,
                knownNamedCopies: ["sum", "summary"]
            )
        )
        XCTAssertTrue(
            VolatileCommandAcceptancePolicy.accepts(
                .pasteNamed("house"),
                confidence: nil,
                knownNamedCopies: ["house"]
            )
        )
    }

    func testCanonicalNumberedCommands() {
        let spoken = VoiceCommandParser.canonicalSpokenSlotNumbers
        XCTAssertEqual(VoiceCommandParser.numberedSlotRange, 1...10)

        for number in VoiceCommandParser.numberedSlotRange {
            XCTAssertEqual(
                VoiceCommandParser.parse("paste \(number)"),
                .pasteNumber(number)
            )
            XCTAssertEqual(
                VoiceCommandParser.parse("copy \(spoken[number - 1])"),
                .copyNumber(number)
            )
        }

        XCTAssertEqual(VoiceCommandParser.parse("copy 10"), .copyNumber(10))
        XCTAssertEqual(VoiceCommandParser.parse("paste ten"), .pasteNumber(10))
        XCTAssertEqual(
            VoiceCommandParser.parse("copy house"),
            .copyNamed("house")
        )
        XCTAssertEqual(
            VoiceCommandParser.parse("permanent copy house"),
            .permanentCopy("house")
        )
        XCTAssertNil(VoiceCommandParser.parse("permanent copy ten"))
        XCTAssertNil(VoiceCommandParser.parse("save clipboard one"))
    }

    func testHighConfidenceNumberHomophonesAreScopedToNumberedCommands() {
        let aliases: [(String, Int)] = [
            ("won", 1),
            ("to", 2),
            ("too", 2),
            ("for", 4),
            ("fore", 4),
            ("foor", 4),
            ("ate", 8),
        ]

        for (word, number) in aliases {
            XCTAssertEqual(
                VoiceCommandParser.parse("paste \(word)"),
                .pasteNumber(number)
            )
            XCTAssertEqual(
                VoiceCommandParser.parse("copy \(word)"),
                .copyNumber(number)
            )
        }
    }

    func testNumberAliasesDoNotMatchInsideLongerNames() {
        XCTAssertNil(VoiceCommandParser.parse("paste to house"))
        XCTAssertNil(VoiceCommandParser.parse("permanent copy to"))
        XCTAssertNil(VoiceCommandParser.parse("permanent copy for later"))
        XCTAssertNil(VoiceCommandParser.parse("paste 11"))
        XCTAssertNil(VoiceCommandParser.parse("permanent copy 11"))
    }

    func testPunctuationAndCapitalizationRemainAccepted() {
        let cases: [(String, VoiceCommand)] = [
            ("Copy.... ONE", .copyNumber(1)),
            ("copy? two!", .copyNumber(2)),
            ("PASTE... too?!", .pasteNumber(2)),
            ("Pace!!! THREE.", .pasteNumber(3)),
            ("pase, four…", .pasteNumber(4)),
            ("COPY... House?!", .copyNamed("house")),
        ]

        for (transcript, expected) in cases {
            XCTAssertEqual(
                VoiceCommandParser.parse(transcript),
                expected,
                "Expected punctuation to be ignored in \(transcript.debugDescription)"
            )
        }
    }

    func testOnlyTrailingTerminalPunctuationIsAnExplicitPhraseBoundary() {
        for text in ["copy point.", "copy pointer!", "copy house?", "copy note…"] {
            XCTAssertTrue(VoiceCommandParser.hasExplicitPhraseBoundary(text))
        }
        for text in ["copy point", "copy... point", "copy house,"] {
            XCTAssertFalse(VoiceCommandParser.hasExplicitPhraseBoundary(text))
        }
    }

    func testPasteVerbAliasesAreCaseInsensitiveAndScopedToVerbPosition() {
        let aliases = [
            "pasting", "peace", "Pace", "hase", "pase", "pay", "pae", "Taste",
        ]

        for alias in aliases {
            for spelling in [alias.lowercased(), alias.uppercased()] {
                XCTAssertEqual(
                    VoiceCommandParser.parse("\(spelling) one"),
                    .pasteNumber(1)
                )
                XCTAssertEqual(
                    VoiceCommandParser.parse("\(spelling) house"),
                    .pasteNamed("house")
                )
            }
        }

        XCTAssertEqual(
            VoiceCommandParser.validNormalizedPermanentName("peace treaty"),
            "peace treaty"
        )
        XCTAssertEqual(
            VoiceCommandParser.parse("copy peace"),
            .copyNamed("peace")
        )
    }

    func testPermanentNameValidationNormalizesUsingVoiceGrammar() {
        XCTAssertEqual(
            VoiceCommandParser.validNormalizedPermanentName("  Main-Home! "),
            "main home"
        )
        XCTAssertEqual(
            VoiceCommandParser.validNormalizedPermanentName("Shipping Address"),
            "shipping address"
        )
        XCTAssertEqual(
            VoiceCommandParser.parse("paste main home"),
            .pasteNamed("main home")
        )

        for invalidName in [
            "",
            "2",
            "two",
            "too",
            "one place",
            "this name has four words",
        ] {
            XCTAssertNil(
                VoiceCommandParser.validNormalizedPermanentName(invalidName),
                "Expected \(invalidName.debugDescription) to be rejected"
            )
        }
    }

    func testTemporaryNamesAllowOneToFiveWordsAndCannotUseNumberAliases() {
        XCTAssertEqual(
            VoiceCommandParser.validNormalizedTemporaryName(" HOUSE! "),
            "house"
        )
        XCTAssertEqual(
            VoiceCommandParser.validNormalizedTemporaryName("My New York Address"),
            "my new york address"
        )
        XCTAssertEqual(
            VoiceCommandParser.parse("copy this first paragraph"),
            .copyNamed("this first paragraph")
        )
        XCTAssertEqual(
            VoiceCommandParser.parse("copy green grapes passage"),
            .copyNamed("green grapes passage")
        )
        XCTAssertEqual(
            VoiceCommandParser.parse("paste my new york address"),
            .pasteNamed("my new york address")
        )

        for invalidName in [
            "", "2", "two", "too", "this name has more than five words",
        ] {
            XCTAssertNil(
                VoiceCommandParser.validNormalizedTemporaryName(invalidName)
            )
        }
    }

    func testVoiceSlotManagementCommands() {
        let cases: [(String, VoiceCommand)] = [
            ("delete 2", .deleteNumber(2)),
            ("DELETE House!", .deleteNamed("house")),
            ("delete my new york address", .deleteNamed("my new york address")),
            ("clear temporary copies", .clearTemporary),
            ("make house permanent", .promoteTemporaryNamed("house")),
            (
                "rename house to home",
                .renameTemporaryNamed(from: "house", to: "home")
            ),
            (
                "rename my new york address to primary address",
                .renameTemporaryNamed(
                    from: "my new york address",
                    to: "primary address"
                )
            ),
        ]

        for (transcript, expected) in cases {
            XCTAssertEqual(VoiceCommandParser.parse(transcript), expected)
        }
    }

    func testVolatileManagementCommandsUseClosedVocabularySafety() {
        XCTAssertTrue(
            VolatileCommandAcceptancePolicy.accepts(
                .deleteNumber(2),
                confidence: nil,
                knownNamedCopies: []
            )
        )
        for command in [
            VoiceCommand.deleteNamed("house"),
            VoiceCommand.promoteTemporaryNamed("house"),
        ] {
            XCTAssertTrue(
                VolatileCommandAcceptancePolicy.accepts(
                    command,
                    confidence: nil,
                    knownNamedCopies: ["house"]
                )
            )
            XCTAssertFalse(
                VolatileCommandAcceptancePolicy.accepts(
                    command,
                    confidence: 1,
                    knownNamedCopies: ["house notes"]
                )
            )
        }
        XCTAssertFalse(
            VolatileCommandAcceptancePolicy.accepts(
                .renameTemporaryNamed(from: "house", to: "home"),
                confidence: 1,
                knownNamedCopies: ["house"]
            )
        )
    }

    func testPromotionRetainsPermanentNameLimit() {
        XCTAssertEqual(
            VoiceCommandParser.parse("make shipping address permanent"),
            .promoteTemporaryNamed("shipping address")
        )
        XCTAssertNil(
            VoiceCommandParser.parse("make my new york address permanent")
        )
    }
}
