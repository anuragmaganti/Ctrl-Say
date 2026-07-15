import Foundation
import SwiftData
import XCTest

final class PermanentCopyRepositoryTests: XCTestCase {
    func testExactPayloadRoundTripsAcrossRepositoryInstances() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let fileURL = directory.appending(path: "referenced-file.txt")
        try Data("file".utf8).write(to: fileURL)

        let payload = makeMixedPayload(fileURL: fileURL)
        let writer = PermanentCopyRepository(location: .temporary(directory))
        try await writer.apply(.upsert(name: "project files", payload: payload))
        try await writer.flush()

        let reader = PermanentCopyRepository(location: .temporary(directory))
        let loaded = try await reader.load()

        XCTAssertEqual(
            loaded,
            [PersistedPermanentCopy(name: "project files", payload: payload)]
        )
    }

    func testReplaceRenameDeleteAndResetSurviveRelaunch() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = PermanentCopyRepository(location: .temporary(directory))
        let original = makeTextPayload("First", date: Date(timeIntervalSince1970: 10))
        let replacement = makeTextPayload("Second", date: Date(timeIntervalSince1970: 20))

        try await repository.apply(.upsert(name: "house", payload: original))
        try await repository.apply(.upsert(name: "house", payload: replacement))
        try await repository.apply(
            .rename(from: "house", to: "home", expectedPayloadID: replacement.id)
        )

        var relaunched = PermanentCopyRepository(location: .temporary(directory))
        let renamedRecords = try await relaunched.load()
        XCTAssertEqual(
            renamedRecords,
            [PersistedPermanentCopy(name: "home", payload: replacement)]
        )

        try await relaunched.apply(
            .delete(name: "home", expectedPayloadID: replacement.id)
        )
        relaunched = PermanentCopyRepository(location: .temporary(directory))
        let deletedRecords = try await relaunched.load()
        XCTAssertEqual(deletedRecords, [])

        try await relaunched.apply(.upsert(name: "again", payload: original))
        try await relaunched.reset()
        let afterReset = PermanentCopyRepository(location: .temporary(directory))
        let resetRecords = try await afterReset.load()
        XCTAssertEqual(resetRecords, [])
    }

    func testDeleteIsIdempotentButChangedRecordIsProtected() async throws {
        let repository = PermanentCopyRepository(location: .memory)
        let payload = makeTextPayload("Protected")
        try await repository.apply(.upsert(name: "house", payload: payload))

        do {
            try await repository.apply(
                .delete(name: "house", expectedPayloadID: UUID())
            )
            XCTFail("Expected stale mutation protection")
        } catch {
            XCTAssertEqual(
                error as? PermanentCopyRepositoryError,
                .recordChanged
            )
        }

        try await repository.apply(
            .delete(name: "missing", expectedPayloadID: UUID())
        )
        let remainingCount = try await repository.load().count
        XCTAssertEqual(remainingCount, 1)
    }

    func testFileBookmarkFollowsMovedFileWithoutCopyingContents() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let originalURL = directory.appending(path: "original.txt")
        let movedURL = directory.appending(path: "moved.txt")
        try Data("bookmark".utf8).write(to: originalURL)
        let repository = PermanentCopyRepository(location: .temporary(directory))
        try await repository.apply(
            .upsert(name: "file", payload: makeFilePayload(originalURL))
        )

        try FileManager.default.moveItem(at: originalURL, to: movedURL)
        let relaunched = PermanentCopyRepository(location: .temporary(directory))
        let loaded = try await relaunched.load()
        let storedURL = loaded.first?.payload.items.first?.representations.first
            .flatMap { String(data: $0.data, encoding: .utf8) }
            .flatMap(URL.init(string:))

        XCTAssertEqual(storedURL?.standardizedFileURL, movedURL.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: movedURL), Data("bookmark".utf8))
    }

    func testUnavailableFileRetainsOriginalReference() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let fileURL = directory.appending(path: "deleted.txt")
        try Data("temporary".utf8).write(to: fileURL)
        let originalPayload = makeFilePayload(fileURL)
        let repository = PermanentCopyRepository(location: .temporary(directory))
        try await repository.apply(
            .upsert(name: "file", payload: originalPayload)
        )
        try FileManager.default.removeItem(at: fileURL)

        let relaunched = PermanentCopyRepository(location: .temporary(directory))
        let loaded = try await relaunched.load()

        XCTAssertEqual(loaded.first?.payload, originalPayload)
    }

    func testFailedContainerCreationDoesNotDeleteDataUntilExplicitReset() async throws {
        let parent = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )
        let invalidDirectory = parent.appending(path: "not-a-directory")
        let sentinel = Data("keep until reset".utf8)
        try sentinel.write(to: invalidDirectory)
        let repository = PermanentCopyRepository(
            location: .temporary(invalidDirectory)
        )

        do {
            _ = try await repository.load()
            XCTFail("Expected model-container creation to fail")
        } catch {
            XCTAssertEqual(try Data(contentsOf: invalidDirectory), sentinel)
        }

        try await repository.reset()
        let payload = makeTextPayload("Recovered")
        try await repository.apply(.upsert(name: "house", payload: payload))
        let loaded = try await repository.load()
        XCTAssertEqual(
            loaded,
            [PersistedPermanentCopy(name: "house", payload: payload)]
        )
    }

    func testMalformedItemOrderingIsRejectedWithoutDeletingStore() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let storeURL = directory.appending(
            path: PermanentCopyRepository.storeFileName
        )
        let data = Data("Invalid index".utf8)
        let record = PermanentCopyRecord(
            normalizedName: "house",
            payloadID: UUID(),
            kindRawValue: ClipboardContentKind.text.rawValue,
            preview: "Invalid index",
            byteCount: Int64(data.count),
            capturedAt: Date(timeIntervalSince1970: 1)
        )
        let item = PermanentCopyItemRecord(itemIndex: 4)
        let representation = PermanentCopyRepresentationRecord(
            representationIndex: 0,
            typeIdentifier: "public.utf8-plain-text",
            data: data
        )
        record.items.append(item)
        item.representations.append(representation)
        try persistRawRecord(record, in: directory)

        let repository = PermanentCopyRepository(location: .temporary(directory))
        do {
            _ = try await repository.load()
            XCTFail("Expected malformed ordering to be rejected")
        } catch {
            XCTAssertEqual(
                error as? PermanentCopyRepositoryError,
                .invalidRecord
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: storeURL.path))
        }
    }

    func testOversizedDeclaredPayloadIsRejectedWithoutDeletingStore() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(
            path: PermanentCopyRepository.storeFileName
        )
        let data = Data("Small external blob".utf8)
        let record = PermanentCopyRecord(
            normalizedName: "house",
            payloadID: UUID(),
            kindRawValue: ClipboardContentKind.text.rawValue,
            preview: "Small external blob",
            byteCount: Int64(ClipboardStore.maximumPayloadBytes + 1),
            capturedAt: Date(timeIntervalSince1970: 1)
        )
        let item = PermanentCopyItemRecord(itemIndex: 0)
        let representation = PermanentCopyRepresentationRecord(
            representationIndex: 0,
            typeIdentifier: "public.utf8-plain-text",
            data: data
        )
        record.items.append(item)
        item.representations.append(representation)
        try persistRawRecord(record, in: directory)

        let repository = PermanentCopyRepository(location: .temporary(directory))
        do {
            _ = try await repository.load()
            XCTFail("Expected oversized declared payload to be rejected")
        } catch {
            XCTAssertEqual(
                error as? PermanentCopyRepositoryError,
                .invalidRecord
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: storeURL.path))
        }
    }

    @MainActor
    func testAtomicRestorePublishesOnlyValidatedPermanentCopies() throws {
        let store = ClipboardStore()
        let temporary = makeTextPayload("Temporary")
        let permanent = makeTextPayload("Permanent")
        try store.set(temporary, at: 1)

        try store.restorePermanentCopies([
            PersistedPermanentCopy(name: "house", payload: permanent),
        ])

        XCTAssertEqual(store.payload(at: 1), temporary)
        XCTAssertEqual(store.payload(named: "house"), permanent)
        XCTAssertEqual(
            store.totalByteCount,
            temporary.byteCount + permanent.byteCount
        )
    }

    @MainActor
    func testMalformedRestoreDoesNotPublishPartialResults() throws {
        let store = ClipboardStore()
        let existing = makeTextPayload("Existing")
        let valid = makeTextPayload("Valid")
        let malformed = ClipboardPayload(
            items: valid.items,
            kind: valid.kind,
            preview: valid.preview,
            byteCount: valid.byteCount + 1
        )
        try store.set(existing, named: "existing")

        XCTAssertThrowsError(
            try store.restorePermanentCopies([
                PersistedPermanentCopy(name: "valid", payload: valid),
                PersistedPermanentCopy(name: "broken", payload: malformed),
            ])
        )
        XCTAssertEqual(store.named, ["existing": existing])
        XCTAssertEqual(store.totalByteCount, existing.byteCount)
    }

    @MainActor
    func testRestoreRejectsDuplicatePayloadIDs() throws {
        let store = ClipboardStore()
        let payload = makeTextPayload("Same payload")

        XCTAssertThrowsError(
            try store.restorePermanentCopies([
                PersistedPermanentCopy(name: "house", payload: payload),
                PersistedPermanentCopy(name: "office", payload: payload),
            ])
        ) { error in
            XCTAssertEqual(
                error as? ClipboardStoreError,
                .duplicateRestoredPermanentCopy
            )
        }
        XCTAssertTrue(store.named.isEmpty)
    }

    @MainActor
    func testRestoreRejectsNoncanonicalPermanentName() {
        let store = ClipboardStore()
        let payload = makeTextPayload("Invalid name")

        XCTAssertThrowsError(
            try store.restorePermanentCopies([
                PersistedPermanentCopy(name: "HOUSE!", payload: payload),
            ])
        ) { error in
            XCTAssertEqual(
                error as? ClipboardStoreError,
                .invalidRestoredPermanentCopy
            )
        }
        XCTAssertTrue(store.named.isEmpty)
    }

    private func makeTemporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(
            path: "CtrlSayPermanentCopyTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
    }

    private func persistRawRecord(
        _ record: PermanentCopyRecord,
        in directory: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let schema = Schema(versionedSchema: PermanentCopySchemaV1.self)
        let configuration = ModelConfiguration(
            "PermanentCopies",
            schema: schema,
            url: directory.appending(path: PermanentCopyRepository.storeFileName),
            allowsSave: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(
            for: schema,
            migrationPlan: PermanentCopyMigrationPlan.self,
            configurations: [configuration]
        )
        let context = ModelContext(container)
        context.insert(record)
        try context.save()
    }

    private func makeTextPayload(
        _ text: String,
        id: UUID = UUID(),
        date: Date = Date(timeIntervalSince1970: 1)
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
                        ),
                    ]
                ),
            ],
            kind: .text,
            preview: text,
            byteCount: data.count,
            capturedAt: date
        )
    }

    private func makeMixedPayload(fileURL: URL) -> ClipboardPayload {
        let id = UUID(uuidString: "DEADBEEF-CAFE-4000-8000-000000000001")!
        let text = Data("Hello".utf8)
        let richText = Data([0x7B, 0x5C, 0x72, 0x74, 0x66, 0x31, 0x7D])
        let image = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])
        let file = Data(fileURL.absoluteString.utf8)
        let items = [
            PasteboardItemPayload(
                representations: [
                    PasteboardRepresentation(
                        typeIdentifier: "public.utf8-plain-text",
                        data: text
                    ),
                    PasteboardRepresentation(
                        typeIdentifier: "public.rtf",
                        data: richText
                    ),
                ]
            ),
            PasteboardItemPayload(
                representations: [
                    PasteboardRepresentation(
                        typeIdentifier: "public.png",
                        data: image
                    ),
                    PasteboardRepresentation(
                        typeIdentifier: "public.file-url",
                        data: file
                    ),
                ]
            ),
        ]
        return ClipboardPayload(
            id: id,
            items: items,
            kind: .mixed,
            preview: "Mixed clipboard payload",
            byteCount: text.count + richText.count + image.count + file.count,
            capturedAt: Date(timeIntervalSince1970: 1_234_567)
        )
    }

    private func makeFilePayload(_ fileURL: URL) -> ClipboardPayload {
        let data = Data(fileURL.absoluteString.utf8)
        return ClipboardPayload(
            items: [
                PasteboardItemPayload(
                    representations: [
                        PasteboardRepresentation(
                            typeIdentifier: "public.file-url",
                            data: data
                        ),
                    ]
                ),
            ],
            kind: .files,
            preview: "File",
            byteCount: data.count,
            capturedAt: Date(timeIntervalSince1970: 1)
        )
    }
}
