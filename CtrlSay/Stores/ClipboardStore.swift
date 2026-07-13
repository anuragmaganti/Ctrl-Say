import Foundation
import Observation

@MainActor
@Observable
final class ClipboardStore {
    static let maximumPayloadBytes = 128 * 1_024 * 1_024
    static let maximumTotalStoredBytes = 256 * 1_024 * 1_024

    private(set) var numbered: [Int: ClipboardPayload] = [:]
    private(set) var named: [String: ClipboardPayload] = [:]
    private(set) var totalByteCount = 0

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

    func set(_ payload: ClipboardPayload, at number: Int) throws {
        try ensureCapacity(
            replacingBytes: numbered[number]?.byteCount ?? 0,
            with: payload
        )
        totalByteCount += payload.byteCount - (numbered[number]?.byteCount ?? 0)
        numbered[number] = payload
    }

    func set(_ payload: ClipboardPayload, named name: String) throws {
        let normalizedName = VoiceCommandParser.normalizeName(name)
        try ensureCapacity(
            replacingBytes: named[normalizedName]?.byteCount ?? 0,
            with: payload
        )
        totalByteCount += payload.byteCount - (named[normalizedName]?.byteCount ?? 0)
        named[normalizedName] = payload
    }

    func payload(at number: Int) -> ClipboardPayload? {
        numbered[number]
    }

    func payload(named name: String) -> ClipboardPayload? {
        named[VoiceCommandParser.normalizeName(name)]
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

    func clearNumbered() {
        let removedBytes = numbered.values.reduce(0) { $0 + $1.byteCount }
        numbered.removeAll(keepingCapacity: true)
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
}

enum ClipboardStoreError: LocalizedError, Equatable {
    case invalidPermanentName
    case permanentNameAlreadyExists(String)
    case missingPermanentCopy
    case permanentCopyChanged
    case emptyContent
    case contentTooLarge
    case noneditableContent
    case payloadTooLarge
    case storageLimitExceeded

    var errorDescription: String? {
        switch self {
        case .invalidPermanentName:
            "Use a name of one to three words that does not begin with a number."
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
        }
    }
}
