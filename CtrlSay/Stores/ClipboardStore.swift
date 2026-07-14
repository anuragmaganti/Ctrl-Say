import Foundation
import Observation

@MainActor
@Observable
final class ClipboardStore {
    static let maximumRepresentationBytes = 64 * 1_024 * 1_024
    static let maximumPayloadBytes = 128 * 1_024 * 1_024
    static let maximumTotalStoredBytes = 256 * 1_024 * 1_024

    private(set) var numbered: [Int: ClipboardPayload] = [:]
    private(set) var temporaryNamed: [String: ClipboardPayload] = [:]
    private(set) var named: [String: ClipboardPayload] = [:]
    private(set) var totalByteCount = 0
    private var temporaryNamedOrder: [String] = []

    var numberedSlots: [(number: Int, payload: ClipboardPayload)] {
        numbered.keys.sorted().compactMap { number in
            numbered[number].map { (number, $0) }
        }
    }

    var namedSlots: [(name: String, payload: ClipboardPayload)] {
        named.keys.sorted().compactMap { name in
            named[name].map { (name, $0) }
        }
    }

    var temporaryNamedSlots: [(name: String, payload: ClipboardPayload)] {
        temporaryNamedOrder.compactMap { name in
            temporaryNamed[name].map { (name, $0) }
        }
    }

    var temporaryCopyCount: Int {
        numbered.count + temporaryNamed.count
    }

    var hasTemporaryCopies: Bool {
        !numbered.isEmpty || !temporaryNamed.isEmpty
    }

    var allNamedKeys: Set<String> {
        Set(named.keys).union(temporaryNamed.keys)
    }

    func set(_ payload: ClipboardPayload, at number: Int) throws {
        try ensureCapacity(
            replacingBytes: numbered[number]?.byteCount ?? 0,
            with: payload
        )
        totalByteCount += payload.byteCount - (numbered[number]?.byteCount ?? 0)
        numbered[number] = payload
    }

    func set(_ payload: ClipboardPayload, named name: String) throws {
        guard let normalizedName = VoiceCommandParser.validNormalizedPermanentName(
            name
        ) else {
            throw ClipboardStoreError.invalidPermanentName
        }
        let replacedBytes = (named[normalizedName]?.byteCount ?? 0)
            + (temporaryNamed[normalizedName]?.byteCount ?? 0)
        try ensureCapacity(
            replacingBytes: replacedBytes,
            with: payload
        )
        totalByteCount += payload.byteCount - replacedBytes
        if temporaryNamed.removeValue(forKey: normalizedName) != nil {
            temporaryNamedOrder.removeAll { $0 == normalizedName }
        }
        named[normalizedName] = payload
    }

    func validateTemporaryNameAvailable(_ name: String) throws -> String {
        guard let normalizedName = VoiceCommandParser.validNormalizedTemporaryName(
            name
        ) else {
            throw ClipboardStoreError.invalidTemporaryName
        }
        guard named[normalizedName] == nil else {
            throw ClipboardStoreError.nameProtectedByPermanentCopy(normalizedName)
        }
        return normalizedName
    }

    func setTemporaryNamed(
        _ payload: ClipboardPayload,
        named name: String
    ) throws {
        let normalizedName = try validateTemporaryNameAvailable(name)
        try ensureCapacity(
            replacingBytes: temporaryNamed[normalizedName]?.byteCount ?? 0,
            with: payload
        )
        totalByteCount += payload.byteCount
            - (temporaryNamed[normalizedName]?.byteCount ?? 0)
        if temporaryNamed[normalizedName] == nil {
            temporaryNamedOrder.append(normalizedName)
        }
        temporaryNamed[normalizedName] = payload
    }

    func payload(at number: Int) -> ClipboardPayload? {
        numbered[number]
    }

    func payload(named name: String) -> ClipboardPayload? {
        named[VoiceCommandParser.normalizeName(name)]
    }

    func payload(temporaryNamed name: String) -> ClipboardPayload? {
        temporaryNamed[VoiceCommandParser.normalizeName(name)]
    }

    func name(forPayloadID payloadID: UUID) -> String? {
        named.first { $0.value.id == payloadID }?.key
    }

    @discardableResult
    func removeNumbered(_ number: Int) -> ClipboardPayload? {
        guard let removed = numbered.removeValue(forKey: number) else { return nil }
        totalByteCount = max(0, totalByteCount - removed.byteCount)
        return removed
    }

    @discardableResult
    func removeNamed(_ name: String) -> ClipboardPayload? {
        let normalizedName = VoiceCommandParser.normalizeName(name)
        guard let removed = named.removeValue(forKey: normalizedName) else { return nil }
        totalByteCount = max(0, totalByteCount - removed.byteCount)
        return removed
    }

    @discardableResult
    func removeTemporaryNamed(_ name: String) -> ClipboardPayload? {
        let normalizedName = VoiceCommandParser.normalizeName(name)
        guard let removed = temporaryNamed.removeValue(
            forKey: normalizedName
        ) else {
            return nil
        }
        temporaryNamedOrder.removeAll { $0 == normalizedName }
        totalByteCount = max(0, totalByteCount - removed.byteCount)
        return removed
    }

    func validateRenameNamed(
        from currentName: String,
        to requestedName: String
    ) throws -> (normalizedName: String, payloadID: UUID) {
        guard let newName = VoiceCommandParser.validNormalizedPermanentName(requestedName) else {
            throw ClipboardStoreError.invalidPermanentName
        }

        let oldName = VoiceCommandParser.normalizeName(currentName)
        guard let payload = named[oldName] else {
            throw ClipboardStoreError.missingPermanentCopy
        }
        guard newName == oldName || named[newName] == nil else {
            throw ClipboardStoreError.permanentNameAlreadyExists(newName)
        }
        guard temporaryNamed[newName] == nil else {
            throw ClipboardStoreError.temporaryNameAlreadyExists(newName)
        }
        return (newName, payload.id)
    }

    func renameNamed(
        from currentName: String,
        to requestedName: String,
        expectedPayloadID: UUID? = nil
    ) throws -> String {
        let validation = try validateRenameNamed(
            from: currentName,
            to: requestedName
        )
        if let expectedPayloadID,
           validation.payloadID != expectedPayloadID {
            throw ClipboardStoreError.permanentCopyChanged
        }

        let oldName = VoiceCommandParser.normalizeName(currentName)
        let newName = validation.normalizedName
        guard newName != oldName else { return newName }
        guard let payload = named[oldName] else {
            throw ClipboardStoreError.missingPermanentCopy
        }

        var updatedNamed = named
        updatedNamed[newName] = payload
        updatedNamed.removeValue(forKey: oldName)
        named = updatedNamed
        return newName
    }

    func replaceNamedText(
        named name: String,
        text: String,
        expectedPayloadID: UUID? = nil
    ) throws {
        let normalizedName = VoiceCommandParser.normalizeName(name)
        guard let payload = named[normalizedName] else {
            throw ClipboardStoreError.missingPermanentCopy
        }
        if let expectedPayloadID,
           payload.id != expectedPayloadID {
            throw ClipboardStoreError.permanentCopyChanged
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ClipboardStoreError.emptyContent
        }
        guard text.utf8.count <= ClipboardPayload.maximumInlineEditableTextBytes else {
            throw ClipboardStoreError.contentTooLarge
        }
        guard let replacement = payload.replacingEditableText(with: text) else {
            throw ClipboardStoreError.noneditableContent
        }
        try ensureCapacity(
            replacingBytes: payload.byteCount,
            with: replacement
        )

        totalByteCount += replacement.byteCount - payload.byteCount
        named[normalizedName] = replacement
    }

    func clearTemporary() {
        let removedBytes = numbered.values.reduce(0) { $0 + $1.byteCount }
            + temporaryNamed.values.reduce(0) { $0 + $1.byteCount }
        numbered.removeAll(keepingCapacity: true)
        temporaryNamed.removeAll(keepingCapacity: true)
        temporaryNamedOrder.removeAll(keepingCapacity: true)
        totalByteCount = max(0, totalByteCount - removedBytes)
    }

    /// Validates an entire durable snapshot before publishing any of it. A
    /// malformed or oversized store therefore cannot leave a partial restore
    /// visible or corrupt the shared memory accounting.
    func restorePermanentCopies(
        _ restored: [PersistedPermanentCopy]
    ) throws {
        let existingTemporaryIDs = Set(numbered.values.map(\.id))
            .union(temporaryNamed.values.map(\.id))
        var names = Set<String>()
        var payloadIDs = Set<UUID>()
        var restoredNamed: [String: ClipboardPayload] = [:]
        var restoredBytes = 0

        for entry in restored {
            guard let normalizedName = VoiceCommandParser.validNormalizedPermanentName(
                entry.name
            ), normalizedName == entry.name else {
                throw ClipboardStoreError.invalidRestoredPermanentCopy
            }
            guard names.insert(normalizedName).inserted,
                  payloadIDs.insert(entry.payload.id).inserted,
                  !existingTemporaryIDs.contains(entry.payload.id) else {
                throw ClipboardStoreError.duplicateRestoredPermanentCopy
            }
            try validateRestoredPayload(entry.payload)
            restoredBytes = try addingWithoutOverflow(
                restoredBytes,
                entry.payload.byteCount
            )
            restoredNamed[normalizedName] = entry.payload
        }

        let temporaryBytes = numbered.values.reduce(0) { $0 + $1.byteCount }
            + temporaryNamed.values.reduce(0) { $0 + $1.byteCount }
        guard temporaryBytes <= Self.maximumTotalStoredBytes - restoredBytes else {
            throw ClipboardStoreError.storageLimitExceeded
        }

        named = restoredNamed
        totalByteCount = temporaryBytes + restoredBytes
    }

    func clearPermanentCopies() {
        let removedBytes = named.values.reduce(0) { $0 + $1.byteCount }
        named.removeAll(keepingCapacity: true)
        totalByteCount = max(0, totalByteCount - removedBytes)
    }

    private func ensureCapacity(
        replacingBytes: Int,
        with payload: ClipboardPayload
    ) throws {
        guard payload.byteCount >= 0,
              payload.byteCount <= Self.maximumPayloadBytes else {
            throw ClipboardStoreError.payloadTooLarge
        }
        let projectedBytes = totalByteCount - replacingBytes + payload.byteCount
        guard projectedBytes <= Self.maximumTotalStoredBytes else {
            throw ClipboardStoreError.storageLimitExceeded
        }
    }

    private func validateRestoredPayload(_ payload: ClipboardPayload) throws {
        guard !payload.items.isEmpty,
              payload.byteCount >= 0,
              payload.byteCount <= Self.maximumPayloadBytes else {
            throw ClipboardStoreError.invalidRestoredPermanentCopy
        }

        var measuredBytes = 0
        for item in payload.items {
            guard !item.representations.isEmpty else {
                throw ClipboardStoreError.invalidRestoredPermanentCopy
            }
            for representation in item.representations {
                guard !representation.typeIdentifier.isEmpty,
                      representation.data.count <= Self.maximumRepresentationBytes else {
                    throw ClipboardStoreError.invalidRestoredPermanentCopy
                }
                measuredBytes = try addingWithoutOverflow(
                    measuredBytes,
                    representation.data.count
                )
            }
        }
        guard measuredBytes == payload.byteCount else {
            throw ClipboardStoreError.invalidRestoredPermanentCopy
        }
    }

    private func addingWithoutOverflow(_ left: Int, _ right: Int) throws -> Int {
        let (sum, overflow) = left.addingReportingOverflow(right)
        guard !overflow else {
            throw ClipboardStoreError.invalidRestoredPermanentCopy
        }
        return sum
    }
}

enum ClipboardStoreError: LocalizedError, Equatable {
    case invalidTemporaryName
    case invalidPermanentName
    case nameProtectedByPermanentCopy(String)
    case temporaryNameAlreadyExists(String)
    case permanentNameAlreadyExists(String)
    case missingPermanentCopy
    case permanentCopyChanged
    case emptyContent
    case contentTooLarge
    case noneditableContent
    case payloadTooLarge
    case storageLimitExceeded
    case invalidRestoredPermanentCopy
    case duplicateRestoredPermanentCopy

    var errorDescription: String? {
        switch self {
        case .invalidTemporaryName:
            "Use a one-word name that is not a number."
        case .invalidPermanentName:
            "Use a name of one to three words that does not begin with a number."
        case .nameProtectedByPermanentCopy(let name):
            "“\(name)” is a permanent copy. Delete it or use a different temporary name."
        case .temporaryNameAlreadyExists(let name):
            "A temporary copy named “\(name)” already exists."
        case .permanentNameAlreadyExists(let name):
            "A permanent copy named “\(name)” already exists."
        case .missingPermanentCopy:
            "That permanent copy no longer exists."
        case .permanentCopyChanged:
            "That permanent copy changed before the edit could be saved."
        case .emptyContent:
            "Permanent copy content cannot be empty."
        case .contentTooLarge:
            "Permanent copy content must be 256 KB or smaller to edit here."
        case .noneditableContent:
            "Only a single valid plain-text clipboard item can be edited."
        case .payloadTooLarge:
            "That copy exceeds Ctrl-Say’s 128 MB per-copy limit."
        case .storageLimitExceeded:
            "Ctrl-Say’s 256 MB clipboard memory limit is full. Delete a copy, then try again."
        case .invalidRestoredPermanentCopy:
            "Permanent storage contains invalid or oversized clipboard data."
        case .duplicateRestoredPermanentCopy:
            "Permanent storage contains duplicate clipboard records."
        }
    }
}
