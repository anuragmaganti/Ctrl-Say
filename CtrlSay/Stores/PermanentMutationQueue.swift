import Foundation

struct SequencedPermanentMutation: Equatable, Sendable {
    let sequence: UInt64
    let mutation: PermanentCopyMutation
}

struct PermanentMutationQueueState: Sendable {
    private(set) var entries: [SequencedPermanentMutation] = []
    private(set) var inFlightSequence: UInt64?
    private var nextSequence: UInt64 = 0

    var count: Int { entries.count }
    var isEmpty: Bool { entries.isEmpty }

    @discardableResult
    mutating func enqueue(
        _ mutation: PermanentCopyMutation
    ) -> SequencedPermanentMutation {
        nextSequence &+= 1
        let sequenced = SequencedPermanentMutation(
            sequence: nextSequence,
            mutation: mutation
        )

        if case .upsert(let name, _) = mutation,
           let redundantIndex = redundantPendingUpsertIndex(named: name) {
            entries.remove(at: redundantIndex)
        }
        entries.append(sequenced)
        return sequenced
    }

    mutating func beginNext() -> SequencedPermanentMutation? {
        guard inFlightSequence == nil, let first = entries.first else {
            return nil
        }
        inFlightSequence = first.sequence
        return first
    }

    mutating func complete(_ sequence: UInt64) -> Bool {
        guard inFlightSequence == sequence,
              entries.first?.sequence == sequence else {
            return false
        }
        entries.removeFirst()
        inFlightSequence = nil
        return true
    }

    mutating func fail(_ sequence: UInt64) {
        guard inFlightSequence == sequence else { return }
        inFlightSequence = nil
    }

    mutating func removeAll() {
        entries.removeAll(keepingCapacity: false)
        inFlightSequence = nil
    }

    private func redundantPendingUpsertIndex(named name: String) -> Int? {
        let firstMutableIndex = inFlightSequence == nil ? 0 : 1
        guard firstMutableIndex < entries.count else { return nil }

        for index in stride(
            from: entries.count - 1,
            through: firstMutableIndex,
            by: -1
        ) {
            switch entries[index].mutation {
            case .upsert(let pendingName, _) where pendingName == name:
                return index
            case .rename(let oldName, let newName, _)
                where oldName == name || newName == name:
                return nil
            case .delete(let pendingName, _) where pendingName == name:
                return nil
            default:
                continue
            }
        }
        return nil
    }
}
