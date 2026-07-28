import Foundation
import XCTest

final class NotchFeedbackTests: XCTestCase {
    func testListeningLifecycleMovesFromHiddenThroughPreparingToListening() {
        var state = NotchFeedbackReducerState()
        XCTAssertEqual(state.visualState, .hidden)

        state =
            NotchFeedbackReducer.reduce(
                state,
                event: .listeningActivityChanged(.preparing)
            ).state
        XCTAssertEqual(state.visualState, .preparing)

        state =
            NotchFeedbackReducer.reduce(
                state,
                event: .listeningActivityChanged(.listening)
            ).state
        XCTAssertEqual(state.visualState, .listening)
    }

    func testSuccessTemporarilyOverlaysListeningThenReturnsToIt() {
        var state = NotchFeedbackReducerState(
            listeningActivity: .listening
        )
        let presented = NotchFeedbackReducer.reduce(
            state,
            event: .present(.success(action: .copy, label: "House"))
        )
        state = presented.state

        XCTAssertEqual(
            state.visualState,
            .success(action: .copy, label: "House")
        )
        XCTAssertEqual(presented.expiration?.duration, .seconds(1))

        state =
            NotchFeedbackReducer.reduce(
                state,
                event: .transientExpired(
                    generation: presented.expiration!.generation
                )
            ).state
        XCTAssertEqual(state.visualState, .listening)
    }

    func testPendingCopyExpandsWithoutStartingAnExpiration() {
        let presented = NotchFeedbackReducer.reduce(
            .init(listeningActivity: .listening),
            event: .present(.pending(action: .copy, label: "House"))
        )

        XCTAssertEqual(
            presented.state.visualState,
            .pending(action: .copy, label: "House")
        )
        XCTAssertNil(presented.expiration)
    }

    func testSuccessReplacesPendingCopyAndStartsItsExpiration() {
        let pending = NotchFeedbackReducer.reduce(
            .init(listeningActivity: .listening),
            event: .present(.pending(action: .copy, label: "House"))
        ).state
        let succeeded = NotchFeedbackReducer.reduce(
            pending,
            event: .present(.success(action: .copy, label: "House"))
        )

        XCTAssertEqual(
            succeeded.state.visualState,
            .success(action: .copy, label: "House")
        )
        XCTAssertEqual(succeeded.expiration?.duration, .seconds(1))
    }

    func testPendingAndSuccessShareOnePresentationPhase() {
        let pending = NotchVisualState.pending(
            action: .copy,
            label: "House"
        )
        let success = NotchVisualState.success(
            action: .copy,
            label: "House"
        )

        XCTAssertEqual(pending.presentationPhase, .feedback)
        XCTAssertEqual(success.presentationPhase, .feedback)
        XCTAssertEqual(
            pending.presentationPhase,
            success.presentationPhase,
            "Pending-to-success must not restart the notch entrance animation"
        )
        XCTAssertNotEqual(
            NotchVisualState.listening.presentationPhase,
            pending.presentationPhase
        )
    }

    func testCancellingPendingCopyReturnsToListening() {
        let pending = NotchFeedbackReducer.reduce(
            .init(listeningActivity: .listening),
            event: .present(.pending(action: .copy, label: "House"))
        ).state
        let cancelled = NotchFeedbackReducer.reduce(
            pending,
            event: .clearTransient
        ).state

        XCTAssertEqual(cancelled.visualState, .listening)
        XCTAssertNil(cancelled.transientFeedback)
    }

    func testNewFeedbackMakesAnOlderExpirationHarmless() {
        var state = NotchFeedbackReducerState(
            listeningActivity: .listening
        )
        let first = NotchFeedbackReducer.reduce(
            state,
            event: .present(.success(action: .copy, label: "1"))
        )
        let second = NotchFeedbackReducer.reduce(
            first.state,
            event: .present(.success(action: .paste, label: "2"))
        )
        state =
            NotchFeedbackReducer.reduce(
                second.state,
                event: .transientExpired(
                    generation: first.expiration!.generation
                )
            ).state

        XCTAssertEqual(
            state.visualState,
            .success(action: .paste, label: "2")
        )
    }

    func testStoppingListeningImmediatelyClearsTransientFeedback() {
        let presented = NotchFeedbackReducer.reduce(
            .init(listeningActivity: .listening),
            event: .present(.failure(message: "Try again"))
        ).state
        let stopped = NotchFeedbackReducer.reduce(
            presented,
            event: .listeningActivityChanged(.inactive)
        ).state

        XCTAssertNil(stopped.transientFeedback)
        XCTAssertEqual(stopped.visualState, .hidden)
    }

    func testInteractionModesAreIndependentFromVisualFeedback() {
        let listening = NotchFeedbackReducerState(
            listeningActivity: .listening
        )
        let interactive = NotchFeedbackReducer.reduce(
            listening,
            event: .interactionModeChanged(.compactInteractive)
        ).state

        XCTAssertEqual(interactive.visualState, .listening)
        XCTAssertTrue(interactive.interactionMode.acceptsPointerEvents)
        XCTAssertFalse(NotchInteractionMode.passive.acceptsPointerEvents)
    }

    func testDisplayedLabelsAreBoundedAndNeverContainLineBreaks() {
        XCTAssertEqual(
            NotchFeedbackText.displayLabel("  gitHub\n"),
            "Github"
        )
        let result = NotchFeedbackText.displayLabel(String(repeating: "a", count: 80))
        XCTAssertEqual(result.count, 40)
        XCTAssertFalse(result.contains("\n"))
    }
}
