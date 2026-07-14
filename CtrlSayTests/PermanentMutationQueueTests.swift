import Foundation
import XCTest

final class PermanentMutationQueueTests: XCTestCase {
    func testSequencesMutationsInArrivalOrder() {
        var queue = PermanentMutationQueueState()
        let first = queue.enqueue(.upsert(name: "house", payload: payload("A")))
        let second = queue.enqueue(.upsert(name: "office", payload: payload("B")))

        XCTAssertLessThan(first.sequence, second.sequence)
        XCTAssertEqual(queue.beginNext(), first)
        XCTAssertTrue(queue.complete(first.sequence))
        XCTAssertEqual(queue.beginNext(), second)
        XCTAssertTrue(queue.complete(second.sequence))
        XCTAssertTrue(queue.isEmpty)
    }

    func testCoalescesOnlyRedundantPendingUpserts() {
        var queue = PermanentMutationQueueState()
        let firstHouse = queue.enqueue(
            .upsert(name: "house", payload: payload("Old"))
        )
        let office = queue.enqueue(
            .upsert(name: "office", payload: payload("Office"))
        )
        let newestHouse = queue.enqueue(
            .upsert(name: "house", payload: payload("New"))
        )

        XCTAssertEqual(queue.entries.map(\.sequence), [office.sequence, newestHouse.sequence])
        XCTAssertFalse(queue.entries.map(\.sequence).contains(firstHouse.sequence))
    }

    func testNeverCoalescesInFlightOrAcrossRenameBarrier() {
        var queue = PermanentMutationQueueState()
        let original = queue.enqueue(
            .upsert(name: "house", payload: payload("Original"))
        )
        XCTAssertEqual(queue.beginNext(), original)

        let pending = queue.enqueue(
            .upsert(name: "house", payload: payload("Pending"))
        )
        let rename = queue.enqueue(
            .rename(
                from: "house",
                to: "home",
                expectedPayloadID: payloadID(from: pending.mutation)
            )
        )
        let recreated = queue.enqueue(
            .upsert(name: "house", payload: payload("Recreated"))
        )

        XCTAssertEqual(
            queue.entries.map(\.sequence),
            [original.sequence, pending.sequence, rename.sequence, recreated.sequence]
        )
    }

    func testFailedMutationRemainsFirstForRetry() {
        var queue = PermanentMutationQueueState()
        let mutation = queue.enqueue(
            .upsert(name: "house", payload: payload("Retry"))
        )

        XCTAssertEqual(queue.beginNext(), mutation)
        queue.fail(mutation.sequence)
        XCTAssertEqual(queue.beginNext(), mutation)
    }

    private func payload(_ text: String) -> ClipboardPayload {
        let data = Data(text.utf8)
        return ClipboardPayload(
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
            byteCount: data.count
        )
    }

    private func payloadID(from mutation: PermanentCopyMutation) -> UUID {
        if case .upsert(_, let payload) = mutation { return payload.id }
        return UUID()
    }
}
