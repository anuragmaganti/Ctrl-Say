import AppKit
import CoreGraphics
import Foundation
import UniformTypeIdentifiers

@MainActor
final class ClipboardService {
    private let pasteboard = NSPasteboard.general
    private let maximumRepresentationBytes = 64 * 1_024 * 1_024
    private let maximumPayloadBytes = 128 * 1_024 * 1_024

    var hasEventPostingAccess: Bool {
        CGPreflightPostEventAccess()
    }

    @discardableResult
    func requestEventPostingAccess() -> Bool {
        CGRequestPostEventAccess()
    }

    func captureSelection() async throws -> ClipboardPayload {
        guard hasEventPostingAccess else {
            throw ClipboardServiceError.accessibilityPermissionRequired
        }

        let initialChangeCount = pasteboard.changeCount
        let started = DispatchTime.now().uptimeNanoseconds
        try postCommandKey(keyCode: 8) // C

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(750))
        while pasteboard.changeCount == initialChangeCount {
            guard clock.now < deadline else {
                throw ClipboardServiceError.copyTimedOut
            }
            try await Task.sleep(for: .milliseconds(2))
        }

        let payload = try snapshotCurrentClipboard()
        let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        Telemetry.clipboard.info("Copy captured in \(milliseconds, privacy: .public) ms; \(payload.byteCount, privacy: .public) bytes")
        return payload
    }

    func snapshotCurrentClipboard() throws -> ClipboardPayload {
        guard let pasteboardItems = pasteboard.pasteboardItems, !pasteboardItems.isEmpty else {
            throw ClipboardServiceError.clipboardIsEmpty
        }

        var totalBytes = 0
        var containsText = false
        var containsImage = false
        var containsFiles = false
        var firstTextPreview: String?
        var firstFilePreview: String?
        var payloadItems: [PasteboardItemPayload] = []
        payloadItems.reserveCapacity(pasteboardItems.count)

        for item in pasteboardItems {
            firstTextPreview = firstTextPreview ?? item.string(forType: .string)
            if let fileURLString = item.string(forType: .fileURL),
               let fileURL = URL(string: fileURLString) {
                firstFilePreview = firstFilePreview ?? fileURL.lastPathComponent
            }

            var representations: [PasteboardRepresentation] = []
            representations.reserveCapacity(item.types.count)

            for type in item.types {
                guard let data = item.data(forType: type),
                      data.count <= maximumRepresentationBytes,
                      totalBytes + data.count <= maximumPayloadBytes else {
                    continue
                }

                let identifier = type.rawValue
                let uniformType = UTType(identifier)
                containsText = containsText || uniformType?.conforms(to: .text) == true
                containsImage = containsImage || uniformType?.conforms(to: .image) == true
                containsFiles = containsFiles || type == .fileURL
                totalBytes += data.count
                representations.append(.init(typeIdentifier: identifier, data: data))
            }

            if !representations.isEmpty {
                payloadItems.append(.init(representations: representations))
            }
        }

        guard !payloadItems.isEmpty else {
            throw ClipboardServiceError.unsupportedOrOversizedContent
        }

        let kind = contentKind(text: containsText, image: containsImage, files: containsFiles)
        let preview = preview(
            kind: kind,
            text: firstTextPreview,
            file: firstFilePreview,
            itemCount: payloadItems.count
        )

        return ClipboardPayload(
            items: payloadItems,
            kind: kind,
            preview: preview,
            byteCount: totalBytes
        )
    }

    func paste(_ payload: ClipboardPayload) throws {
        guard hasEventPostingAccess else {
            throw ClipboardServiceError.accessibilityPermissionRequired
        }

        let started = DispatchTime.now().uptimeNanoseconds
        let items = payload.items.map { payloadItem in
            let item = NSPasteboardItem()
            for representation in payloadItem.representations {
                item.setData(
                    representation.data,
                    forType: NSPasteboard.PasteboardType(representation.typeIdentifier)
                )
            }
            return item
        }

        pasteboard.clearContents()
        guard pasteboard.writeObjects(items) else {
            throw ClipboardServiceError.couldNotWriteClipboard
        }

        try postCommandKey(keyCode: 9) // V
        let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        Telemetry.clipboard.info("Paste dispatched in \(milliseconds, privacy: .public) ms; \(payload.byteCount, privacy: .public) bytes")
    }

    private func postCommandKey(keyCode: CGKeyCode) throws {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            throw ClipboardServiceError.couldNotCreateKeyboardEvent
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cgSessionEventTap)
        keyUp.post(tap: .cgSessionEventTap)
    }

    private func contentKind(text: Bool, image: Bool, files: Bool) -> ClipboardContentKind {
        let count = [text, image, files].filter { $0 }.count
        if count > 1 { return .mixed }
        if files { return .files }
        if image { return .image }
        if text { return .text }
        return .data
    }

    private func preview(
        kind: ClipboardContentKind,
        text: String?,
        file: String?,
        itemCount: Int
    ) -> String {
        switch kind {
        case .text, .mixed:
            if let text {
                let singleLine = text.replacingOccurrences(of: "\n", with: " ")
                return String(singleLine.prefix(80))
            }
            return itemCount == 1 ? "Mixed content" : "\(itemCount) items"
        case .files:
            if itemCount > 1 { return "\(itemCount) files" }
            return file ?? "File"
        case .image:
            return itemCount == 1 ? "Image" : "\(itemCount) images"
        case .data:
            return itemCount == 1 ? "Clipboard item" : "\(itemCount) clipboard items"
        }
    }
}

enum ClipboardServiceError: LocalizedError {
    case accessibilityPermissionRequired
    case clipboardIsEmpty
    case copyTimedOut
    case unsupportedOrOversizedContent
    case couldNotWriteClipboard
    case couldNotCreateKeyboardEvent

    var errorDescription: String? {
        switch self {
        case .accessibilityPermissionRequired:
            "Accessibility permission is required to send Copy and Paste commands."
        case .clipboardIsEmpty:
            "The native clipboard is empty."
        case .copyTimedOut:
            "The frontmost app did not provide copied content."
        case .unsupportedOrOversizedContent:
            "The copied content is unsupported or exceeds the current safety limit."
        case .couldNotWriteClipboard:
            "Ctrl-Say could not write this slot to the native clipboard."
        case .couldNotCreateKeyboardEvent:
            "Ctrl-Say could not create the Copy or Paste keyboard event."
        }
    }
}
