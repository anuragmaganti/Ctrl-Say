import AppKit
import SwiftUI
import XCTest

final class ClipboardRowInteractionTests: XCTestCase {
    @MainActor
    func testTemporaryRowClickWritesPayloadToClipboard() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let service = ClipboardService(pasteboard: pasteboard)
        let payload = textPayload("Temporary row content")

        let row = NumberedCopyRow(
            number: 1,
            payload: payload,
            copyToClipboard: {
                _ = try? service.writeToSystemClipboard(payload)
            },
            paste: {},
            delete: {}
        )

        click(row, at: CGPoint(x: 120, y: 20))

        XCTAssertEqual(
            pasteboard.string(forType: .string),
            "Temporary row content"
        )
    }

    @MainActor
    func testTemporaryNamedRowClickWritesPayloadToClipboard() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let service = ClipboardService(pasteboard: pasteboard)
        let payload = textPayload("Temporary named row content")

        let row = TemporaryNamedCopyRow(
            name: "house",
            payload: payload,
            copyToClipboard: {
                _ = try? service.writeToSystemClipboard(payload)
            },
            paste: {},
            delete: {}
        )

        click(row, at: CGPoint(x: 120, y: 20))

        XCTAssertEqual(
            pasteboard.string(forType: .string),
            "Temporary named row content"
        )
    }

    @MainActor
    func testPermanentRowClickWritesPayloadToClipboard() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let service = ClipboardService(pasteboard: pasteboard)
        let payload = textPayload("Permanent row content")

        let row = PermanentCopyRow(
            name: "address",
            payload: payload,
            editingSession: ClipboardHUDEditingSession(),
            copyToClipboard: {
                _ = try? service.writeToSystemClipboard(payload)
            },
            paste: {},
            delete: {},
            rename: { _, requestedName in requestedName },
            updateText: { _, _ in }
        )

        click(row, at: CGPoint(x: 120, y: 20))

        XCTAssertEqual(
            pasteboard.string(forType: .string),
            "Permanent row content"
        )
    }

    @MainActor
    func testPermanentTitleDoubleClickStillBeginsRenaming() {
        let payload = textPayload("Permanent row content")
        let editingSession = ClipboardHUDEditingSession()
        var didBeginEditing = false
        editingSession.onBeginEditing = {
            didBeginEditing = true
        }
        let row = PermanentCopyRow(
            name: "address",
            payload: payload,
            editingSession: editingSession,
            copyToClipboard: {},
            paste: {},
            delete: {},
            rename: { _, requestedName in requestedName },
            updateText: { _, _ in }
        )

        click(row, at: CGPoint(x: 120, y: 42), clickCount: 2)

        XCTAssertTrue(didBeginEditing)
    }

    @MainActor
    func testIdlePermanentRowMatchesTemporaryRowHeight() {
        let payload = textPayload("Two-line clipboard preview content")
        let temporaryRow = NumberedCopyRow(
            number: 1,
            payload: payload,
            copyToClipboard: {},
            paste: {},
            delete: {}
        )
        let permanentRow = PermanentCopyRow(
            name: "address",
            payload: payload,
            editingSession: ClipboardHUDEditingSession(),
            copyToClipboard: {},
            paste: {},
            delete: {},
            rename: { _, requestedName in requestedName },
            updateText: { _, _ in }
        )

        XCTAssertEqual(
            fittingHeight(of: temporaryRow),
            ClipboardHUDMetrics.rowHeight,
            accuracy: 0.5
        )
        XCTAssertEqual(
            fittingHeight(of: permanentRow),
            ClipboardHUDMetrics.rowHeight,
            accuracy: 0.5
        )
    }

    @MainActor
    func testClipboardWritePreservesItemsRepresentationsAndOrder() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let service = ClipboardService(pasteboard: pasteboard)
        let richText = Data("{\\rtf1 Test}".utf8)
        let customData = Data([0x00, 0x01, 0xFE, 0xFF])
        let customType = "com.anuragmaganti.CtrlSayTests.custom"
        let plainText = Data("First item".utf8)
        let payload = ClipboardPayload(
            items: [
                PasteboardItemPayload(
                    representations: [
                        PasteboardRepresentation(
                            typeIdentifier: NSPasteboard.PasteboardType.string.rawValue,
                            data: plainText
                        ),
                        PasteboardRepresentation(
                            typeIdentifier: NSPasteboard.PasteboardType.rtf.rawValue,
                            data: richText
                        ),
                    ]
                ),
                PasteboardItemPayload(
                    representations: [
                        PasteboardRepresentation(
                            typeIdentifier: customType,
                            data: customData
                        ),
                    ]
                ),
            ],
            kind: .mixed,
            preview: "First item",
            byteCount: plainText.count + richText.count + customData.count
        )

        _ = try service.writeToSystemClipboard(payload)

        let items = try XCTUnwrap(pasteboard.pasteboardItems)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].string(forType: .string), "First item")
        XCTAssertEqual(items[0].data(forType: .rtf), richText)
        XCTAssertEqual(
            items[1].data(forType: NSPasteboard.PasteboardType(customType)),
            customData
        )
    }

    @MainActor
    private func click<V: View>(
        _ view: V,
        at point: CGPoint,
        clickCount: Int = 1
    ) {
        let size = CGSize(width: 344, height: ClipboardHUDMetrics.rowHeight)
        let hostingView = NSHostingView(
            rootView: view.frame(width: size.width, height: size.height)
        )
        hostingView.frame = CGRect(origin: .zero, size: size)

        let window = NSWindow(
            contentRect: CGRect(
                origin: CGPoint(x: -10_000, y: -10_000),
                size: size
            ),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        hostingView.layoutSubtreeIfNeeded()

        for count in 1...clickCount {
            sendMouseEvent(
                .leftMouseDown,
                to: window,
                at: point,
                clickCount: count
            )
            sendMouseEvent(
                .leftMouseUp,
                to: window,
                at: point,
                clickCount: count
            )
        }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        window.orderOut(nil)
    }

    @MainActor
    private func fittingHeight<V: View>(of view: V) -> CGFloat {
        let hostingView = NSHostingView(
            rootView: view.frame(width: 344).fixedSize(horizontal: false, vertical: true)
        )
        hostingView.layoutSubtreeIfNeeded()
        return hostingView.fittingSize.height
    }

    @MainActor
    private func sendMouseEvent(
        _ type: NSEvent.EventType,
        to window: NSWindow,
        at point: CGPoint,
        clickCount: Int
    ) {
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: type == .leftMouseDown ? 1 : 0
        ) else {
            XCTFail("Could not create mouse event")
            return
        }
        window.sendEvent(event)
    }

    private func textPayload(_ text: String) -> ClipboardPayload {
        let data = Data(text.utf8)
        return ClipboardPayload(
            items: [
                PasteboardItemPayload(
                    representations: [
                        PasteboardRepresentation(
                            typeIdentifier: NSPasteboard.PasteboardType.string.rawValue,
                            data: data
                        ),
                    ]
                ),
            ],
            kind: .text,
            preview: text,
            byteCount: data.count
        )
    }
}
