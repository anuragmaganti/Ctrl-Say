import XCTest

final class PendingClipboardCopyTests: XCTestCase {
    func testRevisionKeepsIdentityTimestampAndArrivalPosition() {
        var state = PendingClipboardCopyState()
        let firstID = PendingClipboardCopy.ID(rawValue: 1)
        let secondID = PendingClipboardCopy.ID(rawValue: 2)

        XCTAssertEqual(
            state.upsert(
                id: firstID,
                destination: .temporaryNamed("sum"),
                commandReadyAtNanoseconds: 100
            ),
            .inserted
        )
        _ = state.upsert(
            id: secondID,
            destination: .numbered(2),
            commandReadyAtNanoseconds: 200
        )
        XCTAssertEqual(
            state.upsert(
                id: firstID,
                destination: .temporaryNamed("summary"),
                commandReadyAtNanoseconds: 300
            ),
            .updated
        )

        XCTAssertEqual(state.copies.map(\.id), [firstID, secondID])
        XCTAssertEqual(
            state.copy(id: firstID)?.destination,
            .temporaryNamed("summary")
        )
        XCTAssertEqual(
            state.copy(id: firstID)?.commandReadyAtNanoseconds,
            100
        )
    }

    func testRepeatedIdenticalObservationDoesNotRepublish() {
        var state = PendingClipboardCopyState()
        let id = PendingClipboardCopy.ID(rawValue: 7)

        _ = state.upsert(
            id: id,
            destination: .numbered(1),
            commandReadyAtNanoseconds: 100
        )
        XCTAssertEqual(
            state.upsert(
                id: id,
                destination: .numbered(1),
                commandReadyAtNanoseconds: 200
            ),
            .unchanged
        )
        XCTAssertEqual(state.copies.count, 1)
    }

    func testNewestCommandShadowsSameDestinationForPresentation() {
        var state = PendingClipboardCopyState()
        _ = state.upsert(
            id: .init(rawValue: 1),
            destination: .numbered(1),
            commandReadyAtNanoseconds: 100
        )
        _ = state.upsert(
            id: .init(rawValue: 2),
            destination: .temporaryNamed("house"),
            commandReadyAtNanoseconds: 200
        )
        _ = state.upsert(
            id: .init(rawValue: 3),
            destination: .numbered(1),
            commandReadyAtNanoseconds: 300
        )

        XCTAssertEqual(
            state.latestCopies(in: .temporary).map(\.id),
            [.init(rawValue: 2), .init(rawValue: 3)]
        )
    }

    func testVisibleCountReplacesStoredDestinationAndAddsNewDestination() {
        var state = PendingClipboardCopyState()
        _ = state.upsert(
            id: .init(rawValue: 1),
            destination: .numbered(1),
            commandReadyAtNanoseconds: 100
        )
        _ = state.upsert(
            id: .init(rawValue: 2),
            destination: .temporaryNamed("house"),
            commandReadyAtNanoseconds: 200
        )

        XCTAssertEqual(
            state.visibleItemCount(
                in: .temporary,
                storedDestinations: [.numbered(1), .numbered(2)]
            ),
            3
        )
        XCTAssertEqual(
            state.visibleItemCount(
                in: .permanent,
                storedDestinations: [.permanentNamed("address")]
            ),
            1
        )
    }

    func testRemoveAndResetClearOnlyPresentationState() {
        var state = PendingClipboardCopyState()
        _ = state.upsert(
            id: .init(rawValue: 1),
            destination: .permanentNamed("address"),
            commandReadyAtNanoseconds: 100
        )

        XCTAssertNotNil(state.remove(id: .init(rawValue: 1)))
        XCTAssertTrue(state.copies.isEmpty)

        _ = state.upsert(
            id: .init(rawValue: 2),
            destination: .numbered(2),
            commandReadyAtNanoseconds: 200
        )
        state.removeAll()
        XCTAssertTrue(state.copies.isEmpty)
    }
}
