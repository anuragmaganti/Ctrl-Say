import Foundation

struct SerialCommandQueueState<Element, Identity: Hashable> {
    struct Entry {
        var element: Element
        let identity: Identity?
        let enqueuedAtNanoseconds: UInt64
    }

    private var entries: [Entry] = []

    var count: Int { entries.count }

    @discardableResult
    mutating func upsert(
        _ element: Element,
        identity: Identity?,
        enqueuedAtNanoseconds: UInt64
    ) -> Bool {
        if let identity,
            let index = entries.firstIndex(where: { $0.identity == identity })
        {
            entries[index].element = element
            return true
        }

        entries.append(
            Entry(
                element: element,
                identity: identity,
                enqueuedAtNanoseconds: enqueuedAtNanoseconds
            )
        )
        return false
    }

    @discardableResult
    mutating func revoke(identity: Identity) -> Bool {
        guard let index = entries.firstIndex(where: { $0.identity == identity }) else {
            return false
        }
        entries.remove(at: index)
        return true
    }

    mutating func popFirst() -> Entry? {
        guard !entries.isEmpty else { return nil }
        return entries.removeFirst()
    }
}
