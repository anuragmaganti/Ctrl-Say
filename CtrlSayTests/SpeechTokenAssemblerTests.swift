import CoreMedia
import XCTest

final class SpeechTokenAssemblerTests: XCTestCase {
    func testReassemblesPointerSplitAcrossAttributeRuns() throws {
        let assembly = SpeechTokenAssembler.assemble([
            fragment("copy ", 0.10, 0.30, confidence: 0.95),
            fragment("p", 0.31, 0.36, confidence: 0.90),
            fragment("ointer", 0.36, 0.85, confidence: 0.82),
        ])

        XCTAssertEqual(assembly.tokens.map(\.text), ["copy", "pointer"])
        XCTAssertEqual(assembly.sourceFragmentCount, 3)
        XCTAssertEqual(assembly.inWordBoundaryMergeCount, 1)

        let pointer = try XCTUnwrap(assembly.tokens.last)
        XCTAssertEqual(pointer.range, speechRange(0.31, 0.85))
        XCTAssertEqual(pointer.confidence, 0.82)
    }

    func testReassemblesBringingWithoutTreatingSuffixAsAnotherWord() {
        let assembly = SpeechTokenAssembler.assemble([
            SpeechAttributedTextFragment("copy bring"),
            SpeechAttributedTextFragment("ing"),
        ])

        XCTAssertEqual(assembly.tokens.map(\.text), ["copy", "bringing"])
        XCTAssertEqual(assembly.inWordBoundaryMergeCount, 1)
    }

    func testWhitespaceAndPunctuationRemainLexicalBoundaries() {
        let assembly = SpeechTokenAssembler.assemble([
            SpeechAttributedTextFragment("copy"),
            SpeechAttributedTextFragment(" pointer"),
            SpeechAttributedTextFragment("."),
        ])

        XCTAssertEqual(assembly.tokens.map(\.text), ["copy", "pointer"])
        XCTAssertEqual(assembly.inWordBoundaryMergeCount, 0)
    }

    func testMissingAttributesDoNotOverstateMergedTokenMetadata() throws {
        let assembly = SpeechTokenAssembler.assemble([
            fragment("copy ", 0.10, 0.30, confidence: 0.95),
            fragment("point", 0.31, 0.70, confidence: 0.90),
            SpeechAttributedTextFragment("er"),
        ])

        let pointer = try XCTUnwrap(assembly.tokens.last)
        XCTAssertEqual(pointer.text, "pointer")
        XCTAssertNil(pointer.range)
        XCTAssertNil(pointer.confidence)
    }

    func testReassembledTokensDriveFullNamedCommandImmediately() throws {
        let assembly = SpeechTokenAssembler.assemble([
            fragment("copy ", 0.10, 0.30, confidence: 0.95),
            fragment("p", 0.31, 0.36, confidence: 0.90),
            fragment("ointer", 0.36, 0.85, confidence: 0.82),
        ])
        var scanner = StreamingNumberedCommandScanner()
        let update = scanner.ingest(
            StreamingNumberedCommandSegment(
                range: speechRange(0, 1),
                tokens: assembly.tokens
            )
        )
        let candidate = try XCTUnwrap(
            update.mutations.compactMap {
                mutation -> StreamingNumberedCommandCandidate? in
                guard case .upsert(let candidate) = mutation else { return nil }
                return candidate
            }.first
        )

        XCTAssertEqual(candidate.command, .copyNamed("pointer"))
        XCTAssertTrue(candidate.isReadyForDispatch)
    }

    private func fragment(
        _ text: String,
        _ start: Double,
        _ end: Double,
        confidence: Double
    ) -> SpeechAttributedTextFragment {
        SpeechAttributedTextFragment(
            text,
            range: speechRange(start, end),
            confidence: confidence
        )
    }

    private func speechRange(
        _ start: Double,
        _ end: Double
    ) -> SpeechResultRange {
        SpeechResultRange(
            start: CMTime(seconds: start, preferredTimescale: 48_000),
            end: CMTime(seconds: end, preferredTimescale: 48_000)
        )
    }
}
