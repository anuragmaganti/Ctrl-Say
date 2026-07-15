import XCTest

@MainActor
final class DashboardEditingSessionTests: XCTestCase {
    func testDismissalCommitsValidDraftAndEndsEditing() {
        let session = DashboardEditingSession()
        var beginCount = 0
        var endCount = 0
        var commitCount = 0
        var cancelCount = 0
        session.onBeginEditing = { beginCount += 1 }
        session.onEndEditing = { endCount += 1 }

        session.begin(
            commit: {
                commitCount += 1
                return true
            },
            cancel: { cancelCount += 1 }
        )
        session.prepareForDismissal()

        XCTAssertEqual(beginCount, 1)
        XCTAssertEqual(endCount, 1)
        XCTAssertEqual(commitCount, 1)
        XCTAssertEqual(cancelCount, 0)
        XCTAssertFalse(session.isEditing)
    }

    func testDismissalCancelsInvalidDraftBeforeEndingEditing() {
        let session = DashboardEditingSession()
        var endCount = 0
        var cancelCount = 0
        session.onEndEditing = { endCount += 1 }

        session.begin(
            commit: { false },
            cancel: { cancelCount += 1 }
        )
        session.prepareForDismissal()

        XCTAssertEqual(cancelCount, 1)
        XCTAssertEqual(endCount, 1)
        XCTAssertFalse(session.isEditing)
    }

    func testBeginningAnotherEditorCommitsThePreviousEditor() {
        let session = DashboardEditingSession()
        var firstCommitCount = 0
        var firstCancelCount = 0
        var beginCount = 0
        var endCount = 0
        session.onBeginEditing = { beginCount += 1 }
        session.onEndEditing = { endCount += 1 }

        session.begin(
            commit: {
                firstCommitCount += 1
                return true
            },
            cancel: { firstCancelCount += 1 }
        )
        session.begin(commit: { true }, cancel: {})

        XCTAssertEqual(firstCommitCount, 1)
        XCTAssertEqual(firstCancelCount, 0)
        XCTAssertEqual(beginCount, 2)
        XCTAssertEqual(endCount, 1)
        XCTAssertTrue(session.isEditing)
    }

    func testFailedExistingCommitPreventsSecondEditorAndPreservesFirst() throws {
        let session = DashboardEditingSession()
        var firstCommitCount = 0
        var firstCancelCount = 0
        var secondCommitCount = 0
        var secondCancelCount = 0
        var beginCount = 0
        var endCount = 0
        session.onBeginEditing = { beginCount += 1 }
        session.onEndEditing = { endCount += 1 }

        let firstToken = try XCTUnwrap(
            session.begin(
                commit: {
                    firstCommitCount += 1
                    return false
                },
                cancel: { firstCancelCount += 1 }
            )
        )
        let secondToken = session.begin(
            commit: {
                secondCommitCount += 1
                return true
            },
            cancel: { secondCancelCount += 1 }
        )

        XCTAssertNil(secondToken)
        XCTAssertTrue(session.isEditing)
        XCTAssertEqual(firstCommitCount, 1)
        XCTAssertEqual(firstCancelCount, 0)
        XCTAssertEqual(secondCommitCount, 0)
        XCTAssertEqual(secondCancelCount, 0)
        XCTAssertEqual(beginCount, 1)
        XCTAssertEqual(endCount, 0)

        session.finish(firstToken)
        XCTAssertFalse(session.isEditing)
        XCTAssertEqual(endCount, 1)
    }

    func testStaleEditorTokenCannotFinishNewEditor() throws {
        let session = DashboardEditingSession()
        var endCount = 0
        session.onEndEditing = { endCount += 1 }

        let firstToken = try XCTUnwrap(
            session.begin(commit: { true }, cancel: {})
        )
        let secondToken = try XCTUnwrap(
            session.begin(commit: { true }, cancel: {})
        )
        XCTAssertEqual(endCount, 1)

        session.finish(firstToken)
        XCTAssertTrue(session.isEditing)
        XCTAssertEqual(endCount, 1)

        session.finish(secondToken)
        XCTAssertFalse(session.isEditing)
        XCTAssertEqual(endCount, 2)
    }

    func testOutsideInteractionCommitsCapturedEditor() throws {
        let session = DashboardEditingSession()
        var commitCount = 0
        let token = try XCTUnwrap(
            session.begin(
                commit: {
                    commitCount += 1
                    return true
                },
                cancel: {}
            )
        )

        session.prepareForOutsideInteraction(token)

        XCTAssertEqual(commitCount, 1)
        XCTAssertFalse(session.isEditing)
    }

    func testStaleOutsideInteractionDoesNotCloseReplacementEditor() throws {
        let session = DashboardEditingSession()
        let firstToken = try XCTUnwrap(
            session.begin(commit: { true }, cancel: {})
        )
        var replacementCommitCount = 0
        let replacementToken = try XCTUnwrap(
            session.begin(
                commit: {
                    replacementCommitCount += 1
                    return true
                },
                cancel: {}
            )
        )

        session.prepareForOutsideInteraction(firstToken)

        XCTAssertTrue(session.isEditing)
        XCTAssertEqual(session.activeSessionToken, replacementToken)
        XCTAssertEqual(replacementCommitCount, 0)
    }
}
