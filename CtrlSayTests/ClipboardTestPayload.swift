import Foundation

func makeTextPayload(
    _ text: String,
    id: UUID = UUID(),
    capturedAt: Date = .now
) -> ClipboardPayload {
    let data = Data(text.utf8)
    return ClipboardPayload(
        id: id,
        items: [
            PasteboardItemPayload(
                representations: [
                    PasteboardRepresentation(
                        typeIdentifier: "public.utf8-plain-text",
                        data: data
                    )
                ]
            )
        ],
        kind: .text,
        preview: ClipboardPayload.preview(forText: text),
        byteCount: data.count,
        capturedAt: capturedAt
    )
}
