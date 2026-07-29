import Foundation
import XCTest

final class ClipboardPayloadPreviewTests: XCTestCase {
    func testShortPreviewRemainsUnchanged() {
        let payload = makeTextPayload("Short preview")

        XCTAssertEqual(payload.expandedPreviewText, "Short preview")
        XCTAssertEqual(payload.tooltipPreviewText, "Short preview")
    }

    func testExpandedPreviewPreservesFormattingAndAppliesBound() {
        let line = "A readable line of copied text.\n"
        let text = String(repeating: line, count: 100)
        let payload = makeTextPayload(text)

        XCTAssertTrue(payload.expandedPreviewText.contains("\n"))
        XCTAssertTrue(payload.expandedPreviewText.hasSuffix("…"))
        XCTAssertLessThanOrEqual(
            payload.expandedPreviewText.dropLast().count,
            ClipboardPayload.maximumExpandedPreviewCharacters
        )
    }

    func testExpandedPreviewDoesNotSplitUnicodeCharacters() {
        let text = String(
            repeating: "🫠",
            count: ClipboardPayload.maximumExpandedPreviewCharacters + 1
        )
        let payload = makeTextPayload(text)

        XCTAssertEqual(
            payload.expandedPreviewText.dropLast().count,
            ClipboardPayload.maximumExpandedPreviewCharacters
        )
        XCTAssertFalse(payload.expandedPreviewText.contains("�"))
        XCTAssertTrue(payload.expandedPreviewText.hasSuffix("…"))
    }

    func testTooltipPreviewCollapsesWhitespaceAndStaysBounded() {
        let phrase = "A readable copied sentence.\n\t"
        let payload = makeTextPayload(String(repeating: phrase, count: 100))

        XCTAssertFalse(payload.tooltipPreviewText.contains("\n"))
        XCTAssertFalse(payload.tooltipPreviewText.contains("\t"))
        XCTAssertEqual(
            payload.tooltipPreviewText.count,
            ClipboardPayload.maximumTooltipPreviewCharacters
        )
        XCTAssertTrue(payload.tooltipPreviewText.hasSuffix("…"))
    }

    func testTooltipPreviewDoesNotSplitUnicodeCharacters() {
        let payload = makeTextPayload(
            String(
                repeating: "🫠",
                count: ClipboardPayload.maximumTooltipPreviewCharacters + 1
            )
        )

        XCTAssertEqual(
            payload.tooltipPreviewText.count,
            ClipboardPayload.maximumTooltipPreviewCharacters
        )
        XCTAssertFalse(payload.tooltipPreviewText.contains("�"))
        XCTAssertTrue(payload.tooltipPreviewText.hasSuffix("…"))
    }
}
