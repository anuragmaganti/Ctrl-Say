import Foundation
import SwiftData

struct PersistedPermanentCopy: Hashable, Sendable {
    let name: String
    let payload: ClipboardPayload
}

enum PermanentCopyMutation: Hashable, Sendable {
    case upsert(name: String, payload: ClipboardPayload)
    case rename(from: String, to: String, expectedPayloadID: UUID)
    case delete(name: String, expectedPayloadID: UUID)

    var byteCount: Int {
        switch self {
        case .upsert(_, let payload):
            payload.byteCount
        case .rename, .delete:
            0
        }
    }
}

protocol PermanentCopyPersisting: Sendable {
    func load() async throws -> [PersistedPermanentCopy]
    func apply(_ mutation: PermanentCopyMutation) async throws
    func retryPendingChanges() async throws
    func flush() async throws
    func reset() async throws
}

enum PermanentCopyRepositoryLocation: Sendable {
    case production
    case temporary(URL)
    case memory
}

enum PermanentCopyRepositoryError: LocalizedError, Equatable {
    case invalidRecord
    case missingRecord
    case recordChanged
    case duplicateName

    var errorDescription: String? {
        switch self {
        case .invalidRecord:
            "Permanent storage contains a record Ctrl-Say cannot safely load."
        case .missingRecord:
            "That permanent copy no longer exists in storage."
        case .recordChanged:
            "That permanent copy changed before it could be saved."
        case .duplicateName:
            "A permanent copy with that name already exists in storage."
        }
    }
}

actor PermanentCopyRepository: PermanentCopyPersisting {
    nonisolated static let applicationSupportDirectoryName = "com.anuragmaganti.CtrlSay"
    nonisolated static let storeFileName = "PermanentCopies.store"

    nonisolated private static let fileURLTypeIdentifier = "public.file-url"

    private let location: PermanentCopyRepositoryLocation
    private var container: ModelContainer?
    private var context: ModelContext?

    init(location: PermanentCopyRepositoryLocation = .production) {
        self.location = location
    }

    func load() throws -> [PersistedPermanentCopy] {
        let context = try modelContext()
        let descriptor = FetchDescriptor<PermanentCopyRecord>(
            sortBy: [SortDescriptor(\PermanentCopyRecord.normalizedName)]
        )
        let records = try context.fetch(descriptor)
        var restored: [PersistedPermanentCopy] = []
        restored.reserveCapacity(records.count)
        var refreshedBookmark = false

        for record in records {
            let decoded = try decode(record, refreshedBookmark: &refreshedBookmark)
            restored.append(decoded)
        }

        if refreshedBookmark, context.hasChanges {
            do {
                try context.save()
            } catch {
                // Bookmark refresh is opportunistic. The original URL bytes
                // remain durable and a refresh failure must not make every
                // permanent copy unavailable.
                context.rollback()
            }
        }
        return restored
    }

    func apply(_ mutation: PermanentCopyMutation) throws {
        let context = try modelContext()
        do {
            switch mutation {
            case .upsert(let name, let payload):
                if let existing = try record(named: name, in: context) {
                    try replace(existing, name: name, payload: payload, in: context)
                } else {
                    let record = PermanentCopyRecord(
                        normalizedName: name,
                        payloadID: payload.id,
                        kindRawValue: payload.kind.rawValue,
                        preview: payload.preview,
                        byteCount: Int64(payload.byteCount),
                        capturedAt: payload.capturedAt
                    )
                    context.insert(record)
                    try replace(record, name: name, payload: payload, in: context)
                }

            case .rename(let oldName, let newName, let expectedPayloadID):
                guard let existing = try record(named: oldName, in: context) else {
                    throw PermanentCopyRepositoryError.missingRecord
                }
                guard existing.payloadID == expectedPayloadID else {
                    throw PermanentCopyRepositoryError.recordChanged
                }
                if oldName != newName,
                   try record(named: newName, in: context) != nil {
                    throw PermanentCopyRepositoryError.duplicateName
                }
                existing.normalizedName = newName

            case .delete(let name, let expectedPayloadID):
                guard let existing = try record(named: name, in: context) else {
                    // Deleting an already-absent record is idempotent, which makes a
                    // retry after an uncertain disk result safe.
                    return
                }
                guard existing.payloadID == expectedPayloadID else {
                    throw PermanentCopyRepositoryError.recordChanged
                }
                context.delete(existing)
            }

            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    func retryPendingChanges() throws {
        try flush()
    }

    func flush() throws {
        let context = try modelContext()
        if context.hasChanges {
            do {
                try context.save()
            } catch {
                context.rollback()
                throw error
            }
        }
    }

    func reset() throws {
        if let context = try? modelContext() {
            do {
                for record in try context.fetch(
                    FetchDescriptor<PermanentCopyRecord>()
                ) {
                    context.delete(record)
                }
                if context.hasChanges {
                    try context.save()
                }
                return
            } catch {
                context.rollback()
                self.context = nil
                container = nil
            }
        }

        try removePersistentStoreArtifacts()
        let replacement = try modelContainer()
        context = ModelContext(replacement)
        context?.autosaveEnabled = false
    }

    private func modelContainer() throws -> ModelContainer {
        if let container { return container }

        let schema = Schema(versionedSchema: PermanentCopySchemaV1.self)
        let configuration: ModelConfiguration
        switch location {
        case .production:
            let directory = URL.applicationSupportDirectory
                .appending(
                    path: Self.applicationSupportDirectoryName,
                    directoryHint: .isDirectory
                )
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            configuration = ModelConfiguration(
                "PermanentCopies",
                schema: schema,
                url: directory.appending(path: Self.storeFileName),
                allowsSave: true,
                cloudKitDatabase: .none
            )

        case .temporary(let directory):
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            configuration = ModelConfiguration(
                "PermanentCopies",
                schema: schema,
                url: directory.appending(path: Self.storeFileName),
                allowsSave: true,
                cloudKitDatabase: .none
            )

        case .memory:
            configuration = ModelConfiguration(
                "PermanentCopies",
                schema: schema,
                isStoredInMemoryOnly: true,
                allowsSave: true,
                groupContainer: .none,
                cloudKitDatabase: .none
            )
        }

        let container = try ModelContainer(
            for: schema,
            migrationPlan: PermanentCopyMigrationPlan.self,
            configurations: [configuration]
        )
        self.container = container
        return container
    }

    private func removePersistentStoreArtifacts() throws {
        let directory: URL
        switch location {
        case .production:
            directory = URL.applicationSupportDirectory.appending(
                path: Self.applicationSupportDirectoryName,
                directoryHint: .isDirectory
            )
        case .temporary(let temporaryDirectory):
            directory = temporaryDirectory
        case .memory:
            return
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: directory.path,
            isDirectory: &isDirectory
        ) else {
            return
        }
        if !isDirectory.boolValue {
            try FileManager.default.removeItem(at: directory)
            return
        }

        for child in try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) where child.lastPathComponent.hasPrefix(Self.storeFileName) {
            try FileManager.default.removeItem(at: child)
        }
    }

    private func modelContext() throws -> ModelContext {
        if let context { return context }
        let context = ModelContext(try modelContainer())
        context.autosaveEnabled = false
        self.context = context
        return context
    }

    private func record(
        named name: String,
        in context: ModelContext
    ) throws -> PermanentCopyRecord? {
        let requestedName = name
        var descriptor = FetchDescriptor<PermanentCopyRecord>(
            predicate: #Predicate { record in
                record.normalizedName == requestedName
            }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func replace(
        _ record: PermanentCopyRecord,
        name: String,
        payload: ClipboardPayload,
        in context: ModelContext
    ) throws {
        let previousItems = record.items
        for item in previousItems {
            context.delete(item)
        }
        record.items.removeAll(keepingCapacity: false)
        record.normalizedName = name
        record.payloadID = payload.id
        record.kindRawValue = payload.kind.rawValue
        record.preview = payload.preview
        record.byteCount = Int64(payload.byteCount)
        record.capturedAt = payload.capturedAt

        for (itemIndex, itemPayload) in payload.items.enumerated() {
            let item = PermanentCopyItemRecord(itemIndex: itemIndex)
            context.insert(item)
            record.items.append(item)

            for (representationIndex, representation) in itemPayload.representations.enumerated() {
                let persisted = PermanentCopyRepresentationRecord(
                    representationIndex: representationIndex,
                    typeIdentifier: representation.typeIdentifier,
                    data: representation.data,
                    fileBookmarkData: bookmarkData(for: representation),
                    item: nil
                )
                context.insert(persisted)
                item.representations.append(persisted)
            }
        }
    }

    private func decode(
        _ record: PermanentCopyRecord,
        refreshedBookmark: inout Bool
    ) throws -> PersistedPermanentCopy {
        guard let kind = ClipboardContentKind(rawValue: record.kindRawValue),
              record.byteCount >= 0,
              record.byteCount <= Int64(Int.max) else {
            throw PermanentCopyRepositoryError.invalidRecord
        }

        let sortedItems = record.items.sorted { $0.itemIndex < $1.itemIndex }
        guard sortedItems.map(\.itemIndex) == Array(sortedItems.indices) else {
            throw PermanentCopyRepositoryError.invalidRecord
        }
        var items: [PasteboardItemPayload] = []
        items.reserveCapacity(sortedItems.count)
        var storedByteCount = 0
        var restoredByteCount = 0

        for item in sortedItems {
            let sortedRepresentations = item.representations.sorted {
                $0.representationIndex < $1.representationIndex
            }
            guard sortedRepresentations.map(\.representationIndex)
                == Array(sortedRepresentations.indices) else {
                throw PermanentCopyRepositoryError.invalidRecord
            }
            var representations: [PasteboardRepresentation] = []
            representations.reserveCapacity(sortedRepresentations.count)

            for representation in sortedRepresentations {
                var data = representation.data
                storedByteCount += representation.data.count
                if representation.typeIdentifier == Self.fileURLTypeIdentifier,
                   let bookmark = representation.fileBookmarkData,
                   let resolution = resolveBookmark(bookmark) {
                    let originalURL = String(
                        data: representation.data,
                        encoding: .utf8
                    ).flatMap(URL.init(string:))
                    let originalIsAvailable = originalURL.map {
                        FileManager.default.fileExists(atPath: $0.path)
                    } == true
                    let resolvedIsAvailable = FileManager.default.fileExists(
                        atPath: resolution.url.path
                    )
                    if !originalIsAvailable, resolvedIsAvailable {
                        data = Data(resolution.url.absoluteString.utf8)
                    }
                    if resolution.isStale,
                       let replacement = try? resolution.url.bookmarkData(
                        options: [],
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                       ) {
                        representation.fileBookmarkData = replacement
                        refreshedBookmark = true
                    }
                }
                representations.append(
                    PasteboardRepresentation(
                        typeIdentifier: representation.typeIdentifier,
                        data: data
                    )
                )
                restoredByteCount += data.count
            }
            items.append(PasteboardItemPayload(representations: representations))
        }

        guard storedByteCount == Int(record.byteCount) else {
            throw PermanentCopyRepositoryError.invalidRecord
        }

        return PersistedPermanentCopy(
            name: record.normalizedName,
            payload: ClipboardPayload(
                id: record.payloadID,
                items: items,
                kind: kind,
                preview: record.preview,
                byteCount: restoredByteCount,
                capturedAt: record.capturedAt
            )
        )
    }

    private func bookmarkData(
        for representation: PasteboardRepresentation
    ) -> Data? {
        guard representation.typeIdentifier == Self.fileURLTypeIdentifier,
              let string = String(data: representation.data, encoding: .utf8),
              let url = URL(string: string),
              url.isFileURL else {
            return nil
        }
        return try? url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    private func resolveBookmark(_ data: Data) -> (url: URL, isStale: Bool)? {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withoutUI, .withoutMounting],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return nil
        }
        return (url, isStale)
    }
}
