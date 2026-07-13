import Foundation

struct PasteboardRepresentation: Hashable, Sendable {
    let typeIdentifier: String
    let data: Data
}

struct PasteboardItemPayload: Hashable, Sendable {
    let representations: [PasteboardRepresentation]
}

enum ClipboardContentKind: String, Hashable, Sendable {
    case text
    case image
    case files
    case mixed
    case data

    var systemImage: String {
        switch self {
        case .text: "text.alignleft"
        case .image: "photo"
        case .files: "doc.on.doc"
        case .mixed: "square.stack.3d.up"
        case .data: "doc"
        }
    }
}

struct ClipboardPayload: Identifiable, Hashable, Sendable {
    private static let utf8PlainTextTypeIdentifier = "public.utf8-plain-text"
    static let maximumInlineEditableTextBytes = 256 * 1_024

    enum InlineTextEditability: Equatable, Sendable {
        case editable
        case notPlainText
        case tooLarge
        case invalidEncoding
    }

    let id: UUID
    let items: [PasteboardItemPayload]
    let kind: ClipboardContentKind
    let preview: String
    let byteCount: Int
    let capturedAt: Date
    private let hasValidInlineTextEncoding: Bool

    init(
        id: UUID = UUID(),
        items: [PasteboardItemPayload],
        kind: ClipboardContentKind,
        preview: String,
        byteCount: Int,
        capturedAt: Date = .now
    ) {
        self.id = id
        self.items = items
        self.kind = kind
        self.preview = preview
        self.byteCount = byteCount
        self.capturedAt = capturedAt
        self.hasValidInlineTextEncoding = Self.hasValidInlineTextEncoding(
            items: items,
            kind: kind
        )
    }

    var inlineTextEditability: InlineTextEditability {
        guard kind == .text,
              items.count == 1,
              items[0].representations.count == 1,
              let representation = items[0].representations.first,
              representation.typeIdentifier == Self.utf8PlainTextTypeIdentifier else {
            return .notPlainText
        }
        guard representation.data.count <= Self.maximumInlineEditableTextBytes else {
            return .tooLarge
        }
        guard hasValidInlineTextEncoding else {
            return .invalidEncoding
        }
        return .editable
    }

    var editableText: String? {
        guard inlineTextEditability == .editable,
              let representation = items[0].representations.first else {
            return nil
        }
        return String(data: representation.data, encoding: .utf8)
    }

    func replacingEditableText(with text: String) -> ClipboardPayload? {
        guard inlineTextEditability == .editable else { return nil }

        let data = Data(text.utf8)
        return ClipboardPayload(
            id: id,
            items: [
                PasteboardItemPayload(
                    representations: [
                        PasteboardRepresentation(
                            typeIdentifier: Self.utf8PlainTextTypeIdentifier,
                            data: data
                        ),
                    ]
                ),
            ],
            kind: .text,
            preview: Self.preview(forText: text),
            byteCount: data.count,
            capturedAt: capturedAt
        )
    }

    static func preview(forText text: String) -> String {
        var preview = ""
        preview.reserveCapacity(80)
        var needsNewlineSeparator = false

        for character in text {
            if character.isNewline {
                needsNewlineSeparator = !preview.isEmpty
                continue
            }
            if needsNewlineSeparator {
                preview.append(" ")
                needsNewlineSeparator = false
                if preview.count == 80 { break }
            }
            preview.append(character)
            if preview.count == 80 { break }
        }
        return preview
    }

    private static func hasValidInlineTextEncoding(
        items: [PasteboardItemPayload],
        kind: ClipboardContentKind
    ) -> Bool {
        guard kind == .text,
              items.count == 1,
              items[0].representations.count == 1,
              let representation = items[0].representations.first,
              representation.typeIdentifier == utf8PlainTextTypeIdentifier,
              representation.data.count <= maximumInlineEditableTextBytes else {
            return false
        }
        return String(data: representation.data, encoding: .utf8) != nil
    }
}
