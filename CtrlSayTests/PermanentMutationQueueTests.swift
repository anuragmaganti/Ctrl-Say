import Foundation
import XCTest

final class PermanentMutationQueueTests: XCTestCase {
    func testSequencesMutationsInArrivalOrder() {
        var queue = PermanentMutationQueueState()
        let first = queue.enqueue(.upsert(name: "house", payload: makeTextPayload("A")))
        let second = queue.enqueue(.upsert(name: "office", payload: makeTextPayload("B")))

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
            .upsert(name: "house", payload: makeTextPayload("Old"))
        )
        let office = queue.enqueue(
            .upsert(name: "office", payload: makeTextPayload("Office"))
        )
        let newestHouse = queue.enqueue(
            .upsert(name: "house", payload: makeTextPayload("New"))
        )

        XCTAssertEqual(queue.entries.map(\.sequence), [office.sequence, newestHouse.sequence])
        XCTAssertFalse(queue.entries.map(\.sequence).contains(firstHouse.sequence))
    }

    func testNeverCoalescesInFlightOrAcrossRenameBarrier() {
        var queue = PermanentMutationQueueState()
        let original = queue.enqueue(
            .upsert(name: "house", payload: makeTextPayload("Original"))
        )
        XCTAssertEqual(queue.beginNext(), original)

        let pending = queue.enqueue(
            .upsert(name: "house", payload: makeTextPayload("Pending"))
        )
        let rename = queue.enqueue(
            .rename(
                from: "house",
                to: "home",
                expectedPayloadID: payloadID(from: pending.mutation)
            )
        )
        let recreated = queue.enqueue(
            .upsert(name: "house", payload: makeTextPayload("Recreated"))
        )

        XCTAssertEqual(
            queue.entries.map(\.sequence),
            [original.sequence, pending.sequence, rename.sequence, recreated.sequence]
        )
    }

    func testFailedMutationRemainsFirstForRetry() {
        var queue = PermanentMutationQueueState()
        let mutation = queue.enqueue(
            .upsert(name: "house", payload: makeTextPayload("Retry"))
        )

        XCTAssertEqual(queue.beginNext(), mutation)
        queue.fail(mutation.sequence)
        XCTAssertEqual(queue.beginNext(), mutation)
    }

    func testStreamingPermanentNameRevisionsRemainOrderedAfterInitialUpsert() {
        var queue = PermanentMutationQueueState()
        let copiedPayload = makeTextPayload("Address")
        let upsert = queue.enqueue(
            .upsert(name: "my", payload: copiedPayload)
        )
        let firstRevision = queue.enqueue(
            .rename(
                from: "my",
                to: "my new",
                expectedPayloadID: copiedPayload.id
            )
        )
        let finalRevision = queue.enqueue(
            .rename(
                from: "my new",
                to: "my new york address",
                expectedPayloadID: copiedPayload.id
            )
        )

        XCTAssertEqual(
            queue.entries.map(\.sequence),
            [upsert.sequence, firstRevision.sequence, finalRevision.sequence]
        )
        for expected in [upsert, firstRevision, finalRevision] {
            XCTAssertEqual(queue.beginNext(), expected)
            XCTAssertTrue(queue.complete(expected.sequence))
        }
        XCTAssertTrue(queue.isEmpty)
    }

    private func payloadID(from mutation: PermanentCopyMutation) -> UUID {
        if case .upsert(_, let payload) = mutation { return payload.id }
        return UUID()
    }
}
