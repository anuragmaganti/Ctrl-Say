import Foundation
import XCTest

final class NotchFeedbackTests: XCTestCase {
    func testListeningLifecycleMovesFromHiddenThroughPreparingToListening() {
        var state = NotchFeedbackReducerState()
        XCTAssertEqual(state.visualState, .hidden)

        state = NotchFeedbackReducer.reduce(
            state,
            event: .listeningActivityChanged(.preparing)
        ).state
        XCTAssertEqual(state.visualState, .preparing)

        state = NotchFeedbackReducer.reduce(
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

        state = NotchFeedbackReducer.reduce(
            state,
            event: .transientExpired(
                generation: presented.expiration!.generation
            )
        ).state
        XCTAssertEqual(state.visualState, .listening)
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
        state = NotchFeedbackReducer.reduce(
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
