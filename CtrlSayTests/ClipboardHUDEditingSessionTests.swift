import XCTest

@MainActor
/// Regression coverage for the HUD's single, window-scoped inline editor.
final class ClipboardHUDEditingSessionTests: XCTestCase {
    func testBeginPublishesTargetAndDraftBeforePanelAcceptsFocus() throws {
        let session = ClipboardHUDEditingSession()
        let target = permanentNameTarget()
        var observedTarget: ClipboardHUDEditingSession.Target?
        var observedDraft: String?
        session.onBeginEditing = {
            observedTarget = session.activeTarget
            observedDraft = session.draft
        }

        let token = session.begin(
            target: target,
            initialDraft: "address",
            commit: { _ in }
        )

        XCTAssertNotNil(token)
        XCTAssertEqual(observedTarget, target)
        XCTAssertEqual(observedDraft, "address")
        XCTAssertEqual(session.activeTarget, target)
        XCTAssertTrue(session.isEditing)
    }

    func testCommitUsesObservableDraftAndEndsEditing() {
        let session = ClipboardHUDEditingSession()
        let target = permanentContentTarget()
        var committedText: String?
        var endCount = 0
        session.onEndEditing = { endCount += 1 }
        session.begin(
            target: target,
            initialDraft: "Old",
            commit: { committedText = $0 }
        )
        session.updateDraft("Updated directly in the HUD")

        XCTAssertTrue(session.commit(target))

        XCTAssertEqual(committedText, "Updated directly in the HUD")
        XCTAssertEqual(endCount, 1)
        XCTAssertFalse(session.isEditing)
        XCTAssertNil(session.activeTarget)
        XCTAssertEqual(session.draft, "")
    }

    func testTemporaryEditStateCoversNumberedAndNamedCopies() {
        let session = ClipboardHUDEditingSession()
        let numberedTarget = temporaryTarget(number: 1)
        let namedTarget = ClipboardHUDEditingSession.Target(
            payloadID: UUID(),
            location: .temporaryNamed("house"),
            field: .content
        )

        XCTAssertFalse(session.isEditingTemporaryCopy)

        session.begin(
            target: numberedTarget,
            initialDraft: "Numbered",
            commit: { _ in }
        )
        XCTAssertTrue(session.isEditingTemporaryCopy)

        session.begin(
            target: namedTarget,
            initialDraft: "Named",
            commit: { _ in }
        )
        XCTAssertTrue(session.isEditingTemporaryCopy)

        session.cancel(namedTarget)
        XCTAssertFalse(session.isEditingTemporaryCopy)
    }

    func testPermanentEditDoesNotHideTemporaryFooterAction() {
        let session = ClipboardHUDEditingSession()
        let target = permanentContentTarget()

        session.begin(
            target: target,
            initialDraft: "Permanent",
            commit: { _ in }
        )

        XCTAssertFalse(session.isEditingTemporaryCopy)
    }

    func testDismissalCommitsValidDraftAndEndsEditing() {
        let session = ClipboardHUDEditingSession()
        let target = temporaryTarget(number: 1)
        var committedText: String?
        session.begin(
            target: target,
            initialDraft: "Old",
            commit: { committedText = $0 }
        )
        session.updateDraft("New")

        session.prepareForDismissal()

        XCTAssertEqual(committedText, "New")
        XCTAssertFalse(session.isEditing)
    }

    func testDismissalDiscardsInvalidDraftAfterCommitFailure() {
        let session = ClipboardHUDEditingSession()
        let target = temporaryTarget(number: 1)
        var commitCount = 0
        var endCount = 0
        session.onEndEditing = { endCount += 1 }
        session.begin(
            target: target,
            initialDraft: "Invalid",
            commit: { _ in
                commitCount += 1
                throw TestError.invalidDraft
            }
        )

        session.prepareForDismissal()

        XCTAssertEqual(commitCount, 1)
        XCTAssertEqual(endCount, 1)
        XCTAssertFalse(session.isEditing)
    }

    func testBeginningAnotherEditorCommitsThePreviousEditor() {
        let session = ClipboardHUDEditingSession()
        let firstTarget = temporaryTarget(number: 1)
        let secondTarget = permanentNameTarget()
        var firstCommittedText: String?
        var beginCount = 0
        var endCount = 0
        session.onBeginEditing = { beginCount += 1 }
        session.onEndEditing = { endCount += 1 }
        session.begin(
            target: firstTarget,
            initialDraft: "First",
            commit: { firstCommittedText = $0 }
        )

        let secondToken = session.begin(
            target: secondTarget,
            initialDraft: "Second",
            commit: { _ in }
        )

        XCTAssertNotNil(secondToken)
        XCTAssertEqual(firstCommittedText, "First")
        XCTAssertEqual(beginCount, 2)
        XCTAssertEqual(endCount, 1)
        XCTAssertEqual(session.activeTarget, secondTarget)
    }

    func testFailedExistingCommitPreventsSecondEditorAndPreservesFirst() {
        let session = ClipboardHUDEditingSession()
        let firstTarget = temporaryTarget(number: 1)
        let secondTarget = permanentNameTarget()
        session.begin(
            target: firstTarget,
            initialDraft: "Invalid",
            commit: { _ in throw TestError.invalidDraft }
        )

        let secondToken = session.begin(
            target: secondTarget,
            initialDraft: "Second",
            commit: { _ in }
        )

        XCTAssertNil(secondToken)
        XCTAssertEqual(session.activeTarget, firstTarget)
        XCTAssertEqual(session.validationMessage, "Invalid draft")
    }

    func testOutsideInteractionCommitsCapturedEditor() throws {
        let session = ClipboardHUDEditingSession()
        let target = permanentNameTarget()
        var committedText: String?
        let token = try XCTUnwrap(
            session.begin(
                target: target,
                initialDraft: "address",
                commit: { committedText = $0 }
            )
        )

        session.prepareForOutsideInteraction(token)

        XCTAssertEqual(committedText, "address")
        XCTAssertFalse(session.isEditing)
    }

    func testStaleOutsideInteractionDoesNotCloseReplacementEditor() throws {
        let session = ClipboardHUDEditingSession()
        let firstToken = try XCTUnwrap(
            session.begin(
                target: temporaryTarget(number: 1),
                initialDraft: "First",
                commit: { _ in }
            )
        )
        let replacementTarget = permanentContentTarget()
        let replacementToken = try XCTUnwrap(
            session.begin(
                target: replacementTarget,
                initialDraft: "Replacement",
                commit: { _ in }
            )
        )

        session.prepareForOutsideInteraction(firstToken)

        XCTAssertTrue(session.isEditing)
        XCTAssertEqual(session.activeSessionToken, replacementToken)
        XCTAssertEqual(session.activeTarget, replacementTarget)
    }

    func testCancelOnlyAffectsMatchingTarget() {
        let session = ClipboardHUDEditingSession()
        let activeTarget = permanentContentTarget()
        session.begin(
            target: activeTarget,
            initialDraft: "Content",
            commit: { _ in }
        )

        session.cancel(temporaryTarget(number: 1))
        XCTAssertEqual(session.activeTarget, activeTarget)

        session.cancel(activeTarget)
        XCTAssertFalse(session.isEditing)
    }

    private func permanentNameTarget() -> ClipboardHUDEditingSession.Target {
        ClipboardHUDEditingSession.Target(
            payloadID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            location: .permanent,
            field: .name
        )
    }

    private func permanentContentTarget() -> ClipboardHUDEditingSession.Target {
        ClipboardHUDEditingSession.Target(
            payloadID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            location: .permanent,
            field: .content
        )
    }

    private func temporaryTarget(number: Int) -> ClipboardHUDEditingSession.Target {
        ClipboardHUDEditingSession.Target(
            payloadID: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            location: .numbered(number),
            field: .content
        )
    }
}

private enum TestError: LocalizedError {
    case invalidDraft

    var errorDescription: String? {
        "Invalid draft"
    }
}
