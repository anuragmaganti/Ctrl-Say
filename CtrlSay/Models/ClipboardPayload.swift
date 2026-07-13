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
    let id: UUID
    let items: [PasteboardItemPayload]
    let kind: ClipboardContentKind
    let preview: String
    let byteCount: Int
    let capturedAt: Date

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
    }
}
