import Foundation
import SwiftData

enum PermanentCopySchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)

    static let models: [any PersistentModel.Type] = [
        PermanentCopyRecord.self,
        PermanentCopyItemRecord.self,
        PermanentCopyRepresentationRecord.self,
    ]
}

enum PermanentCopyMigrationPlan: SchemaMigrationPlan {
    static let schemas: [any VersionedSchema.Type] = [
        PermanentCopySchemaV1.self,
    ]

    static let stages: [MigrationStage] = []
}

@Model
final class PermanentCopyRecord {
    @Attribute(.unique) var normalizedName: String
    var payloadID: UUID
    var kindRawValue: String
    var preview: String
    var byteCount: Int64
    var capturedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \PermanentCopyItemRecord.copy)
    var items: [PermanentCopyItemRecord]

    init(
        normalizedName: String,
        payloadID: UUID,
        kindRawValue: String,
        preview: String,
        byteCount: Int64,
        capturedAt: Date,
        items: [PermanentCopyItemRecord] = []
    ) {
        self.normalizedName = normalizedName
        self.payloadID = payloadID
        self.kindRawValue = kindRawValue
        self.preview = preview
        self.byteCount = byteCount
        self.capturedAt = capturedAt
        self.items = items
    }
}

@Model
final class PermanentCopyItemRecord {
    var itemIndex: Int
    var copy: PermanentCopyRecord?

    @Relationship(
        deleteRule: .cascade,
        inverse: \PermanentCopyRepresentationRecord.item
    )
    var representations: [PermanentCopyRepresentationRecord]

    init(
        itemIndex: Int,
        copy: PermanentCopyRecord? = nil,
        representations: [PermanentCopyRepresentationRecord] = []
    ) {
        self.itemIndex = itemIndex
        self.copy = copy
        self.representations = representations
    }
}

@Model
final class PermanentCopyRepresentationRecord {
    var representationIndex: Int
    var typeIdentifier: String
    @Attribute(.externalStorage) var data: Data
    var fileBookmarkData: Data?
    var item: PermanentCopyItemRecord?

    init(
        representationIndex: Int,
        typeIdentifier: String,
        data: Data,
        fileBookmarkData: Data? = nil,
        item: PermanentCopyItemRecord? = nil
    ) {
        self.representationIndex = representationIndex
        self.typeIdentifier = typeIdentifier
        self.data = data
        self.fileBookmarkData = fileBookmarkData
        self.item = item
    }
}
