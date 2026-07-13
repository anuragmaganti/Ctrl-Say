import AppKit
import Foundation
import XCTest

final class ClipboardStoreMutationTests: XCTestCase {
    private let plainTextType = "public.utf8-plain-text"

    @MainActor
    func testRemoveNumberedRemovesOnlyRequestedSlotAndReturnsPayload() throws {
        let store = ClipboardStore()
        let first = makeTextPayload("First")
        let second = makeTextPayload("Second")
        try store.set(first, at: 1)
        try store.set(second, at: 2)

        XCTAssertEqual(store.removeNumbered(1), first)
        XCTAssertNil(store.payload(at: 1))
        XCTAssertEqual(store.payload(at: 2), second)
        XCTAssertNil(store.removeNumbered(1))
    }

    @MainActor
    func testTemporaryNamedCopyNormalizesReplacesAndRemoves() throws {
        let store = ClipboardStore()
        let first = makeTextPayload("First")
        let replacement = makeTextPayload("Replacement")

        try store.setTemporaryNamed(first, named: " HOUSE! ")
        XCTAssertEqual(store.payload(temporaryNamed: "house"), first)
        XCTAssertEqual(store.payload(resolvingNamed: "HOUSE"), first)

        try store.setTemporaryNamed(replacement, named: "house")
        XCTAssertEqual(store.payload(temporaryNamed: "house"), replacement)
        XCTAssertEqual(store.totalByteCount, replacement.byteCount)
        XCTAssertEqual(store.removeTemporaryNamed("HOUSE!"), replacement)
        XCTAssertEqual(store.totalByteCount, 0)
    }

    @MainActor
    func testTemporaryNamedCopyRejectsNumbersAndMultipleWords() {
        let store = ClipboardStore()
        let payload = makeTextPayload("Temporary")

        for name in ["", "1", "one", "too", "home office"] {
            XCTAssertThrowsError(
                try store.setTemporaryNamed(payload, named: name)
            ) { error in
                XCTAssertEqual(
                    error as? ClipboardStoreError,
                    .invalidTemporaryName
                )
            }
        }
        XCTAssertTrue(store.temporaryNamed.isEmpty)
        XCTAssertEqual(store.totalByteCount, 0)
    }

    @MainActor
    func testTemporaryCopyCannotOverwritePermanentName() throws {
        let store = ClipboardStore()
        let permanent = makeTextPayload("Permanent")
        try store.set(permanent, named: "house")

        XCTAssertThrowsError(
            try store.setTemporaryNamed(
                makeTextPayload("Temporary"),
                named: "HOUSE!"
            )
        ) { error in
            XCTAssertEqual(
                error as? ClipboardStoreError,
                .nameProtectedByPermanentCopy("house")
            )
        }
        XCTAssertEqual(store.payload(resolvingNamed: "house"), permanent)
        XCTAssertNil(store.payload(temporaryNamed: "house"))
    }

    @MainActor
    func testPermanentCopyPromotesAndReplacesTemporaryName() throws {
        let store = ClipboardStore()
        let temporary = makeTextPayload("Temporary")
        let permanent = makeTextPayload("Permanent")
        try store.setTemporaryNamed(temporary, named: "house")

        try store.set(permanent, named: "house")

        XCTAssertNil(store.payload(temporaryNamed: "house"))
        XCTAssertEqual(store.payload(named: "house"), permanent)
        XCTAssertEqual(store.payload(resolvingNamed: "house"), permanent)
        XCTAssertEqual(store.totalByteCount, permanent.byteCount)
    }

    @MainActor
    func testClearTemporaryRemovesNumberedAndNamedButKeepsPermanent() throws {
        let store = ClipboardStore()
        let numbered = makeTextPayload("Numbered")
        let temporaryNamed = makeTextPayload("Temporary named")
        let permanent = makeTextPayload("Permanent")
        try store.set(numbered, at: 1)
        try store.setTemporaryNamed(temporaryNamed, named: "house")
        try store.set(permanent, named: "office")

        store.clearTemporary()

        XCTAssertTrue(store.numbered.isEmpty)
        XCTAssertTrue(store.temporaryNamed.isEmpty)
        XCTAssertEqual(store.payload(named: "office"), permanent)
        XCTAssertEqual(store.totalByteCount, permanent.byteCount)
    }

    @MainActor
    func testRemoveNamedNormalizesLookupAndReturnsPayload() throws {
        let store = ClipboardStore()
        let payload = makeTextPayload("Home")
        try store.set(payload, named: "home office")

        XCTAssertEqual(store.removeNamed(" HOME-office! "), payload)
        XCTAssertNil(store.payload(named: "home office"))
        XCTAssertNil(store.removeNamed("home office"))
    }

    @MainActor
    func testRenameNormalizesNameAndPreservesPayload() throws {
        let store = ClipboardStore()
        let payload = makeTextPayload("Address")
        try store.set(payload, named: "house")

        let normalizedName = try store.renameNamed(
            from: "HOUSE",
            to: "  Main-Home!  ",
            expectedPayloadID: payload.id
        )

        XCTAssertEqual(normalizedName, "main home")
        XCTAssertNil(store.payload(named: "house"))
        XCTAssertEqual(store.payload(named: "main home"), payload)
    }

    @MainActor
    func testRenameToSameNormalizedNameIsNoOp() throws {
        let store = ClipboardStore()
        let payload = makeTextPayload("Address")
        try store.set(payload, named: "main home")

        let normalizedName = try store.renameNamed(
            from: "main home",
            to: "MAIN-home!"
        )

        XCTAssertEqual(normalizedName, "main home")
        XCTAssertEqual(store.named, ["main home": payload])
    }

    @MainActor
    func testPayloadIDLookupTracksRenameAndRemoval() throws {
        let store = ClipboardStore()
        let payload = makeTextPayload("Address")
        try store.set(payload, named: "house")

        XCTAssertEqual(store.name(forPayloadID: payload.id), "house")
        _ = try store.renameNamed(
            from: "house",
            to: "home",
            expectedPayloadID: payload.id
        )
        XCTAssertEqual(store.name(forPayloadID: payload.id), "home")

        store.removeNamed("home")
        XCTAssertNil(store.name(forPayloadID: payload.id))
    }

    @MainActor
    func testRenameRejectsCollisionAtomically() throws {
        let store = ClipboardStore()
        let house = makeTextPayload("House")
        let office = makeTextPayload("Office")
        try store.set(house, named: "house")
        try store.set(office, named: "office")
        let originalSlots = store.named

        XCTAssertThrowsError(
            try store.renameNamed(from: "house", to: "OFFICE!")
        ) { error in
            XCTAssertEqual(
                error as? ClipboardStoreError,
                .permanentNameAlreadyExists("office")
            )
        }
        XCTAssertEqual(store.named, originalSlots)
    }

    @MainActor
    func testPermanentRenameRejectsTemporaryNameCollision() throws {
        let store = ClipboardStore()
        let permanent = makeTextPayload("Permanent")
        let temporary = makeTextPayload("Temporary")
        try store.set(permanent, named: "house")
        try store.setTemporaryNamed(temporary, named: "office")

        XCTAssertThrowsError(
            try store.renameNamed(from: "house", to: "office")
        ) { error in
            XCTAssertEqual(
                error as? ClipboardStoreError,
                .temporaryNameAlreadyExists("office")
            )
        }
        XCTAssertEqual(store.payload(named: "house"), permanent)
        XCTAssertEqual(store.payload(temporaryNamed: "office"), temporary)
    }

    @MainActor
    func testRenameRejectsInvalidVoiceNamesWithoutMutation() throws {
        let invalidNames = [
            "",
            "   ",
            "2",
            "two",
            "too",
            "one place",
            "this name has four words",
        ]

        for invalidName in invalidNames {
            let store = ClipboardStore()
            let payload = makeTextPayload("House")
            try store.set(payload, named: "house")

            XCTAssertThrowsError(
                try store.renameNamed(from: "house", to: invalidName),
                "Expected \(invalidName.debugDescription) to be rejected"
            ) { error in
                XCTAssertEqual(error as? ClipboardStoreError, .invalidPermanentName)
            }
            XCTAssertEqual(store.named, ["house": payload])
        }
    }

    @MainActor
    func testRenameRejectsMissingSource() {
        let store = ClipboardStore()

        XCTAssertThrowsError(
            try store.renameNamed(from: "missing", to: "new name")
        ) { error in
            XCTAssertEqual(error as? ClipboardStoreError, .missingPermanentCopy)
        }
        XCTAssertTrue(store.named.isEmpty)
    }

    @MainActor
    func testRenameRejectsStaleExpectedPayloadIDWithoutMovingReplacement() throws {
        let store = ClipboardStore()
        let original = makeTextPayload("Original")
        let replacement = makeTextPayload("New voice capture")
        try store.set(original, named: "house")
        try store.set(replacement, named: "house")

        XCTAssertThrowsError(
            try store.renameNamed(
                from: "house",
                to: "home",
                expectedPayloadID: original.id
            )
        ) { error in
            XCTAssertEqual(error as? ClipboardStoreError, .permanentCopyChanged)
        }
        XCTAssertEqual(store.payload(named: "house"), replacement)
        XCTAssertNil(store.payload(named: "home"))
        XCTAssertEqual(store.totalByteCount, replacement.byteCount)
    }

    @MainActor
    func testReplaceNamedTextCanonicalizesRepresentationsAndPreservesMetadata() throws {
        let store = ClipboardStore()
        let id = UUID()
        let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let original = makeTextPayload(
            "Old text",
            id: id,
            capturedAt: capturedAt
        )
        try store.set(original, named: "note")
        let editedText = "  New\nText 👋  "

        try store.replaceNamedText(
            named: "NOTE!",
            text: editedText,
            expectedPayloadID: id
        )

        let replacement = try XCTUnwrap(store.payload(named: "note"))
        XCTAssertEqual(replacement.id, id)
        XCTAssertEqual(replacement.capturedAt, capturedAt)
        XCTAssertEqual(replacement.kind, .text)
        XCTAssertEqual(replacement.preview, "  New Text 👋  ")
        XCTAssertEqual(replacement.byteCount, Data(editedText.utf8).count)
        XCTAssertEqual(replacement.items.count, 1)
        XCTAssertEqual(
            replacement.items[0].representations,
            [
                PasteboardRepresentation(
                    typeIdentifier: plainTextType,
                    data: Data(editedText.utf8)
                ),
            ]
        )
        XCTAssertEqual(replacement.editableText, editedText)
    }

    @MainActor
    func testReplaceNamedTextRejectsWhitespaceWithoutChangingPayload() throws {
        let store = ClipboardStore()
        let payload = makeTextPayload("Keep me")
        try store.set(payload, named: "note")

        for emptyText in ["", "   ", "\n\t"] {
            XCTAssertThrowsError(
                try store.replaceNamedText(named: "note", text: emptyText)
            ) { error in
                XCTAssertEqual(error as? ClipboardStoreError, .emptyContent)
            }
            XCTAssertEqual(store.payload(named: "note"), payload)
        }
    }

    @MainActor
    func testReplaceNamedTextRejectsStaleExpectedPayloadIDWithoutChangingReplacement() throws {
        let store = ClipboardStore()
        let original = makeTextPayload("Original")
        let replacement = makeTextPayload("New voice capture")
        try store.set(original, named: "note")
        try store.set(replacement, named: "note")

        XCTAssertThrowsError(
            try store.replaceNamedText(
                named: "note",
                text: "Stale editor draft",
                expectedPayloadID: original.id
            )
        ) { error in
            XCTAssertEqual(error as? ClipboardStoreError, .permanentCopyChanged)
        }
        XCTAssertEqual(store.payload(named: "note"), replacement)
        XCTAssertEqual(store.totalByteCount, replacement.byteCount)
    }

    @MainActor
    func testReplaceNamedTextRejectsMissingCopy() {
        let store = ClipboardStore()

        XCTAssertThrowsError(
            try store.replaceNamedText(named: "missing", text: "New text")
        ) { error in
            XCTAssertEqual(error as? ClipboardStoreError, .missingPermanentCopy)
        }
    }

    @MainActor
    func testReplaceNamedTextAcceptsExactLimitAndRejectsOneByteOver() throws {
        let store = ClipboardStore()
        let payload = makeTextPayload("Keep me")
        try store.set(payload, named: "note")
        let maximumText = String(
            repeating: "a",
            count: ClipboardPayload.maximumInlineEditableTextBytes
        )
        let oversizedText = String(
            repeating: "a",
            count: ClipboardPayload.maximumInlineEditableTextBytes + 1
        )

        try store.replaceNamedText(named: "note", text: maximumText)
        let maximumPayload = try XCTUnwrap(store.payload(named: "note"))
        XCTAssertEqual(maximumPayload.editableText, maximumText)
        XCTAssertEqual(
            maximumPayload.byteCount,
            ClipboardPayload.maximumInlineEditableTextBytes
        )

        XCTAssertThrowsError(
            try store.replaceNamedText(named: "note", text: oversizedText)
        ) { error in
            XCTAssertEqual(error as? ClipboardStoreError, .contentTooLarge)
        }
        XCTAssertEqual(store.payload(named: "note"), maximumPayload)
    }

    @MainActor
    func testReplaceNamedTextRejectsAmbiguousOrUndecodablePayloads() throws {
        let payloads = [
            ClipboardPayload(
                items: [
                    PasteboardItemPayload(
                        representations: [plainTextRepresentation("First")]
                    ),
                    PasteboardItemPayload(
                        representations: [plainTextRepresentation("Second")]
                    ),
                ],
                kind: .text,
                preview: "First",
                byteCount: 11
            ),
            ClipboardPayload(
                items: [
                    PasteboardItemPayload(
                        representations: [
                            PasteboardRepresentation(
                                typeIdentifier: "public.png",
                                data: Data([0x00])
                            ),
                        ]
                    ),
                ],
                kind: .image,
                preview: "Image",
                byteCount: 1
            ),
            ClipboardPayload(
                items: [
                    PasteboardItemPayload(
                        representations: [
                            plainTextRepresentation("Caption"),
                            PasteboardRepresentation(
                                typeIdentifier: "public.rtf",
                                data: Data("{\\rtf1 Caption}".utf8)
                            ),
                        ]
                    ),
                ],
                kind: .text,
                preview: "Caption",
                byteCount: 23
            ),
            ClipboardPayload(
                items: [
                    PasteboardItemPayload(
                        representations: [
                            plainTextRepresentation("Caption"),
                            PasteboardRepresentation(
                                typeIdentifier: "public.png",
                                data: Data([0x00])
                            ),
                        ]
                    ),
                ],
                kind: .mixed,
                preview: "Caption",
                byteCount: 8
            ),
            ClipboardPayload(
                items: [
                    PasteboardItemPayload(
                        representations: [
                            PasteboardRepresentation(
                                typeIdentifier: plainTextType,
                                data: Data([0xFF])
                            ),
                        ]
                    ),
                ],
                kind: .text,
                preview: "Invalid text",
                byteCount: 1
            ),
        ]

        for payload in payloads {
            let store = ClipboardStore()
            try store.set(payload, named: "note")

            XCTAssertThrowsError(
                try store.replaceNamedText(named: "note", text: "New text")
            ) { error in
                XCTAssertEqual(error as? ClipboardStoreError, .noneditableContent)
            }
            XCTAssertEqual(store.payload(named: "note"), payload)
        }
    }

    func testMalformedUTF8IsNotExposedAsInlineEditable() {
        let payload = ClipboardPayload(
            items: [
                PasteboardItemPayload(
                    representations: [
                        PasteboardRepresentation(
                            typeIdentifier: plainTextType,
                            data: Data([0xFF])
                        ),
                    ]
                ),
            ],
            kind: .text,
            preview: "Invalid text",
            byteCount: 1
        )

        XCTAssertEqual(payload.inlineTextEditability, .invalidEncoding)
        XCTAssertNil(payload.editableText)
    }

    @MainActor
    func testReplaceNamedTextUsesFullUTF8ByteCountAndEightyCharacterPreview() throws {
        let store = ClipboardStore()
        try store.set(makeTextPayload("Old"), named: "note")
        let editedText = String(repeating: "é", count: 90)

        try store.replaceNamedText(named: "note", text: editedText)

        let replacement = try XCTUnwrap(store.payload(named: "note"))
        XCTAssertEqual(replacement.byteCount, Data(editedText.utf8).count)
        XCTAssertEqual(replacement.preview, String(editedText.prefix(80)))
        XCTAssertEqual(replacement.editableText, editedText)
    }

    @MainActor
    func testReplaceNamedTextFlattensAllNativeNewlineFormsInPreviewOnly() throws {
        let store = ClipboardStore()
        try store.set(makeTextPayload("Old"), named: "note")
        let editedText = "First\rSecond\r\nThird\nFourth"

        try store.replaceNamedText(named: "note", text: editedText)

        let replacement = try XCTUnwrap(store.payload(named: "note"))
        XCTAssertEqual(replacement.preview, "First Second Third Fourth")
        XCTAssertEqual(replacement.editableText, editedText)
    }

    @MainActor
    func testEditedUnicodeAndMultilineTextRoundTripsThroughNamedPasteboard() throws {
        let store = ClipboardStore()
        let original = makeTextPayload("Old")
        try store.set(original, named: "note")
        let editedText = "Café 👋\n東京\r\nLine three"
        try store.replaceNamedText(
            named: "note",
            text: editedText,
            expectedPayloadID: original.id
        )
        let payload = try XCTUnwrap(store.payload(named: "note"))

        let pasteboardName = NSPasteboard.Name(
            "com.anuragmaganti.CtrlSayTests.\(UUID().uuidString)"
        )
        let pasteboard = NSPasteboard(name: pasteboardName)
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()

        let pasteboardItem = NSPasteboardItem()
        for representation in payload.items[0].representations {
            XCTAssertTrue(
                pasteboardItem.setData(
                    representation.data,
                    forType: NSPasteboard.PasteboardType(
                        representation.typeIdentifier
                    )
                )
            )
        }
        XCTAssertTrue(pasteboard.writeObjects([pasteboardItem]))
        XCTAssertEqual(pasteboard.name, pasteboardName)
        XCTAssertEqual(pasteboard.string(forType: .string), editedText)
        let roundTrippedData = try XCTUnwrap(
            pasteboard.pasteboardItems?.first?.data(forType: .string)
        )
        XCTAssertEqual(String(data: roundTrippedData, encoding: .utf8), editedText)
    }

    @MainActor
    func testTotalByteCountTracksInsertReplaceRemoveAndClear() throws {
        let store = ClipboardStore()
        let first = makeAccountingPayload(byteCount: 10)
        let second = makeAccountingPayload(byteCount: 20)
        let permanent = makeAccountingPayload(byteCount: 30)

        try store.set(first, at: 1)
        try store.set(second, at: 2)
        try store.set(permanent, named: "archive")
        XCTAssertEqual(store.totalByteCount, 60)

        let replacement = makeAccountingPayload(byteCount: 15)
        try store.set(replacement, at: 1)
        XCTAssertEqual(store.totalByteCount, 65)

        XCTAssertEqual(store.removeNumbered(2), second)
        XCTAssertEqual(store.totalByteCount, 45)

        store.clearTemporary()
        XCTAssertEqual(store.totalByteCount, 30)

        XCTAssertEqual(store.removeNamed("archive"), permanent)
        XCTAssertEqual(store.totalByteCount, 0)
    }

    @MainActor
    func testPerPayloadLimitRejectsOversizeWithoutChangingStoredValueOrAccounting() throws {
        let store = ClipboardStore()
        let maximum = makeAccountingPayload(
            byteCount: ClipboardStore.maximumPayloadBytes
        )
        try store.set(maximum, at: 1)
        XCTAssertEqual(store.totalByteCount, ClipboardStore.maximumPayloadBytes)

        let oversized = makeAccountingPayload(
            byteCount: ClipboardStore.maximumPayloadBytes + 1
        )
        XCTAssertThrowsError(try store.set(oversized, at: 1)) { error in
            XCTAssertEqual(error as? ClipboardStoreError, .payloadTooLarge)
        }
        XCTAssertEqual(store.payload(at: 1), maximum)
        XCTAssertEqual(store.totalByteCount, ClipboardStore.maximumPayloadBytes)

        let negative = makeAccountingPayload(byteCount: -1)
        XCTAssertThrowsError(try store.set(negative, at: 2)) { error in
            XCTAssertEqual(error as? ClipboardStoreError, .payloadTooLarge)
        }
        XCTAssertNil(store.payload(at: 2))
        XCTAssertEqual(store.totalByteCount, ClipboardStore.maximumPayloadBytes)
    }

    @MainActor
    func testAggregateLimitSpansNamespacesAndRemovalFreesCapacity() throws {
        let store = ClipboardStore()
        let first = makeAccountingPayload(
            byteCount: ClipboardStore.maximumPayloadBytes
        )
        let second = makeAccountingPayload(
            byteCount: ClipboardStore.maximumPayloadBytes
        )
        try store.set(first, at: 1)
        try store.set(second, named: "archive")
        XCTAssertEqual(store.totalByteCount, ClipboardStore.maximumTotalStoredBytes)

        let oneByte = makeAccountingPayload(byteCount: 1)
        XCTAssertThrowsError(try store.set(oneByte, at: 2)) { error in
            XCTAssertEqual(error as? ClipboardStoreError, .storageLimitExceeded)
        }
        XCTAssertNil(store.payload(at: 2))
        XCTAssertEqual(store.totalByteCount, ClipboardStore.maximumTotalStoredBytes)

        XCTAssertEqual(store.removeNumbered(1), first)
        try store.set(oneByte, at: 2)
        XCTAssertEqual(
            store.totalByteCount,
            ClipboardStore.maximumPayloadBytes + 1
        )
    }

    @MainActor
    func testAggregateLimitIncludesTemporaryNamedCopies() throws {
        let store = ClipboardStore()
        let first = makeAccountingPayload(
            byteCount: ClipboardStore.maximumPayloadBytes
        )
        let second = makeAccountingPayload(
            byteCount: ClipboardStore.maximumPayloadBytes
        )
        try store.set(first, at: 1)
        try store.setTemporaryNamed(second, named: "house")
        XCTAssertEqual(
            store.totalByteCount,
            ClipboardStore.maximumTotalStoredBytes
        )

        XCTAssertThrowsError(
            try store.set(makeAccountingPayload(byteCount: 1), named: "office")
        ) { error in
            XCTAssertEqual(error as? ClipboardStoreError, .storageLimitExceeded)
        }
    }

    private func makeTextPayload(
        _ text: String,
        id: UUID = UUID(),
        capturedAt: Date = .now
    ) -> ClipboardPayload {
        let data = Data(text.utf8)
        return ClipboardPayload(
            id: id,
            items: [
                PasteboardItemPayload(
                    representations: [plainTextRepresentation(text)]
                ),
            ],
            kind: .text,
            preview: String(text.prefix(80)),
            byteCount: data.count,
            capturedAt: capturedAt
        )
    }

    private func plainTextRepresentation(_ text: String) -> PasteboardRepresentation {
        PasteboardRepresentation(
            typeIdentifier: plainTextType,
            data: Data(text.utf8)
        )
    }

    private func makeAccountingPayload(byteCount: Int) -> ClipboardPayload {
        ClipboardPayload(
            items: [],
            kind: .data,
            preview: "Accounting payload",
            byteCount: byteCount
        )
    }
}
