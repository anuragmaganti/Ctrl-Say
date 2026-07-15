import Foundation
import XCTest

final class ClipboardPayloadPreviewTests: XCTestCase {
    private let plainTextType = "public.utf8-plain-text"

    func testShortPreviewDoesNotClaimAdditionalText() {
        let payload = makePayload("Short preview")

        XCTAssertFalse(payload.hasAdditionalPreviewText)
        XCTAssertEqual(payload.expandedPreviewText, "Short preview")
        XCTAssertEqual(payload.tooltipPreviewText, "Short preview")
    }

    func testExpandedPreviewPreservesFormattingAndAppliesBound() {
        let line = "A readable line of copied text.\n"
        let text = String(repeating: line, count: 100)
        let payload = makePayload(text)

        XCTAssertTrue(payload.hasAdditionalPreviewText)
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
        let payload = makePayload(text)

        XCTAssertEqual(
            payload.expandedPreviewText.dropLast().count,
            ClipboardPayload.maximumExpandedPreviewCharacters
        )
        XCTAssertFalse(payload.expandedPreviewText.contains("�"))
        XCTAssertTrue(payload.expandedPreviewText.hasSuffix("…"))
    }

    func testTooltipPreviewCollapsesWhitespaceAndStaysBounded() {
        let phrase = "A readable copied sentence.\n\t"
        let payload = makePayload(String(repeating: phrase, count: 100))

        XCTAssertFalse(payload.tooltipPreviewText.contains("\n"))
        XCTAssertFalse(payload.tooltipPreviewText.contains("\t"))
        XCTAssertEqual(
            payload.tooltipPreviewText.count,
            ClipboardPayload.maximumTooltipPreviewCharacters
        )
        XCTAssertTrue(payload.tooltipPreviewText.hasSuffix("…"))
    }

    func testTooltipPreviewDoesNotSplitUnicodeCharacters() {
        let payload = makePayload(
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

    private func makePayload(_ text: String) -> ClipboardPayload {
        let data = Data(text.utf8)
        return ClipboardPayload(
            items: [
                PasteboardItemPayload(
                    representations: [
                        PasteboardRepresentation(
                            typeIdentifier: plainTextType,
                            data: data
                        ),
                    ]
                ),
            ],
            kind: .text,
            preview: ClipboardPayload.preview(forText: text),
            byteCount: data.count
        )
    }
}
