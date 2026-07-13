import XCTest

final class SerialCommandQueueTests: XCTestCase {
    func testRevisionReplacementPreservesPositionAndOriginalQueueTime() throws {
        var queue = SerialCommandQueueState<String, Int>()
        queue.upsert("first", identity: 1, enqueuedAtNanoseconds: 10)
        queue.upsert("second", identity: 2, enqueuedAtNanoseconds: 20)

        XCTAssertTrue(
            queue.upsert("revised first", identity: 1, enqueuedAtNanoseconds: 30)
        )

        let first = try XCTUnwrap(queue.popFirst())
        XCTAssertEqual(first.element, "revised first")
        XCTAssertEqual(first.identity, 1)
        XCTAssertEqual(first.enqueuedAtNanoseconds, 10)
        XCTAssertEqual(queue.popFirst()?.element, "second")
    }

    func testRevocationRemovesOnlyMatchingPendingUtterance() {
        var queue = SerialCommandQueueState<String, Int>()
        queue.upsert("first", identity: 1, enqueuedAtNanoseconds: 10)
        queue.upsert("second", identity: 2, enqueuedAtNanoseconds: 20)

        XCTAssertTrue(queue.revoke(identity: 1))
        XCTAssertEqual(queue.count, 1)
        XCTAssertEqual(queue.popFirst()?.element, "second")
    }

    func testManualCommandsWithNoIdentityAreNeverCoalesced() {
        var queue = SerialCommandQueueState<String, Int>()
        queue.upsert("paste", identity: nil, enqueuedAtNanoseconds: 10)
        queue.upsert("paste", identity: nil, enqueuedAtNanoseconds: 11)

        XCTAssertEqual(queue.count, 2)
    }
}
