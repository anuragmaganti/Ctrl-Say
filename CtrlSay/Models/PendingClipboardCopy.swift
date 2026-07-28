import Foundation

/// Presentation-only state for a copy command that macOS has not captured yet.
/// It never contains clipboard contents and is never a source for paste.
struct PendingClipboardCopy: Identifiable, Equatable, Sendable {
    typealias ID = StreamingVoiceCommandID

    enum Section: Equatable, Sendable {
        case temporary
        case permanent
    }

    enum Destination: Hashable, Sendable {
        case numbered(Int)
        case temporaryNamed(String)
        case permanentNamed(String)

        var section: Section {
            switch self {
            case .numbered, .temporaryNamed:
                .temporary
            case .permanentNamed:
                .permanent
            }
        }

        var displayTitle: String {
            switch self {
            case .numbered(let number):
                String(number)
            case .temporaryNamed(let name), .permanentNamed(let name):
                name.prefix(1).uppercased() + String(name.dropFirst())
            }
        }
    }

    let id: ID
    var destination: Destination
    let commandReadyAtNanoseconds: UInt64
}

struct PendingClipboardCopyState: Equatable, Sendable {
    enum UpsertResult: Equatable, Sendable {
        case inserted
        case updated
        case unchanged
    }

    private(set) var copies: [PendingClipboardCopy] = []

    @discardableResult
    mutating func upsert(
        id: PendingClipboardCopy.ID,
        destination: PendingClipboardCopy.Destination,
        commandReadyAtNanoseconds: UInt64
    ) -> UpsertResult {
        guard let index = copies.firstIndex(where: { $0.id == id }) else {
            copies.append(
                PendingClipboardCopy(
                    id: id,
                    destination: destination,
                    commandReadyAtNanoseconds: commandReadyAtNanoseconds
                )
            )
            return .inserted
        }
        guard copies[index].destination != destination else {
            return .unchanged
        }
        copies[index].destination = destination
        return .updated
    }

    @discardableResult
    mutating func remove(
        id: PendingClipboardCopy.ID
    ) -> PendingClipboardCopy? {
        guard let index = copies.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        return copies.remove(at: index)
    }

    mutating func removeAll() {
        copies.removeAll(keepingCapacity: true)
    }

    func copy(id: PendingClipboardCopy.ID) -> PendingClipboardCopy? {
        copies.first { $0.id == id }
    }

    /// Only the newest pending command for a destination is presented. This
    /// prevents rapid replacements of the same slot from creating duplicate
    /// rows while the serialized clipboard worker catches up.
    func latestCopies(
        in section: PendingClipboardCopy.Section
    ) -> [PendingClipboardCopy] {
        var result: [PendingClipboardCopy] = []
        for copy in copies where copy.destination.section == section {
            result.removeAll { $0.destination == copy.destination }
            result.append(copy)
        }
        return result
    }

    func visibleItemCount(
        in section: PendingClipboardCopy.Section,
        storedDestinations: Set<PendingClipboardCopy.Destination>
    ) -> Int {
        let pendingDestinations = Set(
            latestCopies(in: section).map(\.destination)
        )
        return storedDestinations.union(pendingDestinations).count
    }
}
