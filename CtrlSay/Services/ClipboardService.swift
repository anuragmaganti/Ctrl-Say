import AppKit
import CoreGraphics
import Foundation
import UniformTypeIdentifiers

struct CommandTarget: Equatable, Sendable {
    let processIdentifier: pid_t
    let launchDate: Date?
    let bundleIdentifier: String?
}

struct PasteDispatchMetrics: Equatable, Sendable {
    let milliseconds: Double
}

struct ClipboardWriteMetrics: Equatable, Sendable {
    let milliseconds: Double
}

struct ClipboardCaptureResult: Sendable {
    let payload: ClipboardPayload
    let milliseconds: Double
}

@MainActor
final class ClipboardService {
    private static let commandKeyCode: CGKeyCode = 55

    private let pasteboard: NSPasteboard
    private var didRequestEventPostingAccess = false
    private var activationGeneration: UInt64 = 0
    private var activationObserver: NSObjectProtocol?

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.activationGeneration &+= 1
            }
        }
    }

    var hasEventPostingAccess: Bool {
        CGPreflightPostEventAccess()
    }

    @discardableResult
    func requestEventPostingAccess() -> Bool {
        let granted = CGRequestPostEventAccess()
        if !granted {
            SystemSettingsLauncher.open()
        }
        return granted
    }

    func currentCommandTarget() -> CommandTarget? {
        guard let application = NSWorkspace.shared.frontmostApplication,
            application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
            !application.isTerminated
        else {
            return nil
        }
        return CommandTarget(
            processIdentifier: application.processIdentifier,
            launchDate: application.launchDate,
            bundleIdentifier: application.bundleIdentifier
        )
    }

    func captureSelection(target requestedTarget: CommandTarget?) async throws -> ClipboardCaptureResult {
        try requireEventPostingAccess()
        let target = try requireCurrentTarget(requestedTarget)

        let initialChangeCount = pasteboard.changeCount
        let initialActivationGeneration = activationGeneration
        let started = DispatchTime.now().uptimeNanoseconds
        try postCommandKey(keyCode: 8, target: target)  // C

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(750))
        while pasteboard.changeCount == initialChangeCount {
            guard activationGeneration == initialActivationGeneration else {
                throw ClipboardServiceError.commandTargetChanged
            }
            guard clock.now < deadline else {
                throw ClipboardServiceError.copyTimedOut
            }
            try await Task.sleep(for: .milliseconds(2))
        }

        guard activationGeneration == initialActivationGeneration else {
            throw ClipboardServiceError.commandTargetChanged
        }
        _ = try requireCurrentTarget(target)
        let payload = try snapshotCurrentClipboard()
        let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        Telemetry.clipboard.info("Copy captured in \(milliseconds, privacy: .public) ms")
        return ClipboardCaptureResult(
            payload: payload,
            milliseconds: milliseconds
        )
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
                let fileURL = URL(string: fileURLString)
            {
                firstFilePreview = firstFilePreview ?? fileURL.lastPathComponent
            }

            var representations: [PasteboardRepresentation] = []
            representations.reserveCapacity(item.types.count)

            for type in item.types {
                guard let data = item.data(forType: type),
                    data.count <= ClipboardStore.maximumRepresentationBytes,
                    totalBytes + data.count <= ClipboardStore.maximumPayloadBytes
                else {
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

    func paste(
        _ payload: ClipboardPayload,
        target requestedTarget: CommandTarget?
    ) throws -> PasteDispatchMetrics {
        try requireEventPostingAccess()
        let target = try requireCurrentTarget(requestedTarget)

        let started = DispatchTime.now().uptimeNanoseconds
        try write(payload)

        // Revalidate after the pasteboard write so an intentional app switch
        // cannot send a paste to a different destination.
        _ = try requireCurrentTarget(target)
        try postCommandKey(keyCode: 9, target: target)  // V
        let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        Telemetry.clipboard.info("Paste dispatched in \(milliseconds, privacy: .public) ms")
        return PasteDispatchMetrics(milliseconds: milliseconds)
    }

    func writeToSystemClipboard(
        _ payload: ClipboardPayload
    ) throws -> ClipboardWriteMetrics {
        let started = DispatchTime.now().uptimeNanoseconds
        try write(payload)
        let milliseconds =
            Double(
                DispatchTime.now().uptimeNanoseconds - started
            ) / 1_000_000
        Telemetry.clipboard.info(
            "Clipboard written in \(milliseconds, privacy: .public) ms"
        )
        return ClipboardWriteMetrics(milliseconds: milliseconds)
    }

    private func write(_ payload: ClipboardPayload) throws {
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
    }

    private func postCommandKey(
        keyCode: CGKeyCode,
        target: CommandTarget
    ) throws {
        guard let source = CGEventSource(stateID: .combinedSessionState),
            let commandDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: Self.commandKeyCode,
                keyDown: true
            ),
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false),
            let commandUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: Self.commandKeyCode,
                keyDown: false
            )
        else {
            throw ClipboardServiceError.couldNotCreateKeyboardEvent
        }

        // Quartz requires the complete modifier sequence. Posting only C/V
        // with a Command flag can be ignored by some target event loops, and
        // postToPid provides no delivery acknowledgement.
        commandDown.flags = .maskCommand
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        commandUp.flags = []

        commandDown.postToPid(target.processIdentifier)
        keyDown.postToPid(target.processIdentifier)
        keyUp.postToPid(target.processIdentifier)
        commandUp.postToPid(target.processIdentifier)
    }

    private func requireCurrentTarget(_ target: CommandTarget?) throws -> CommandTarget {
        guard let target,
            let application = NSRunningApplication(
                processIdentifier: target.processIdentifier
            ),
            !application.isTerminated
        else {
            throw ClipboardServiceError.commandTargetUnavailable
        }

        if let launchDate = target.launchDate,
            application.launchDate != launchDate
        {
            throw ClipboardServiceError.commandTargetUnavailable
        }
        if let bundleIdentifier = target.bundleIdentifier,
            application.bundleIdentifier != bundleIdentifier
        {
            throw ClipboardServiceError.commandTargetUnavailable
        }

        guard
            NSWorkspace.shared.frontmostApplication?.processIdentifier
                == target.processIdentifier
        else {
            throw ClipboardServiceError.commandTargetChanged
        }
        return target
    }

    private func requireEventPostingAccess() throws {
        guard hasEventPostingAccess else {
            if !didRequestEventPostingAccess {
                didRequestEventPostingAccess = true
                _ = requestEventPostingAccess()
            }
            throw ClipboardServiceError.accessibilityPermissionRequired
        }
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
                return ClipboardPayload.preview(forText: text)
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
    case commandTargetUnavailable
    case commandTargetChanged

    var errorDescription: String? {
        switch self {
        case .accessibilityPermissionRequired:
            "Grant Accessibility access, then repeat the Copy or Paste command."
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
        case .commandTargetUnavailable:
            "No destination app is ready for this Copy or Paste command."
        case .commandTargetChanged:
            "The active app changed before Ctrl-Say could send the command. Please repeat it."
        }
    }
}
