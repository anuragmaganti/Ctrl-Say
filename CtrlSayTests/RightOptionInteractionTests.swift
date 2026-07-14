import Foundation
import XCTest

final class RightOptionInteractionTests: XCTestCase {
    func testTapStartsListeningAndShowsHUDByDefault() {
        let state = RightOptionInteractionReducer.reduce(
            .init(wantsListening: false, isHUDPresented: false),
            gesture: .tap
        )

        XCTAssertEqual(
            state,
            .init(wantsListening: true, isHUDPresented: true)
        )
    }

    func testTapStopsListeningAndClosesHUD() {
        XCTAssertEqual(
            RightOptionInteractionReducer.reduce(
                .init(wantsListening: true, isHUDPresented: true),
                gesture: .tap
            ),
            .init(wantsListening: false, isHUDPresented: false)
        )
        XCTAssertEqual(
            RightOptionInteractionReducer.reduce(
                .init(wantsListening: true, isHUDPresented: false),
                gesture: .tap
            ),
            .init(wantsListening: false, isHUDPresented: false)
        )
    }

    func testHoldDoesNothingWhileListeningIsOff() {
        XCTAssertEqual(
            RightOptionInteractionReducer.reduce(
                .init(wantsListening: false, isHUDPresented: false),
                gesture: .hold
            ),
            .init(wantsListening: false, isHUDPresented: false)
        )
        XCTAssertEqual(
            RightOptionInteractionReducer.reduce(
                .init(wantsListening: false, isHUDPresented: true),
                gesture: .hold
            ),
            .init(wantsListening: false, isHUDPresented: true)
        )
    }

    func testHoldMinimizesHUDWithoutStoppingListening() {
        XCTAssertEqual(
            RightOptionInteractionReducer.reduce(
                .init(wantsListening: true, isHUDPresented: true),
                gesture: .hold
            ),
            .init(wantsListening: true, isHUDPresented: false)
        )
    }

    func testHoldRestoresHUDWithoutInterruptingListening() {
        XCTAssertEqual(
            RightOptionInteractionReducer.reduce(
                .init(wantsListening: true, isHUDPresented: false),
                gesture: .hold
            ),
            .init(wantsListening: true, isHUDPresented: true)
        )
    }

    func testTapAndHoldSequenceMatchesListeningHUDLifecycle() {
        var state = RightOptionInteractionState(
            wantsListening: false,
            isHUDPresented: false
        )

        state = RightOptionInteractionReducer.reduce(state, gesture: .tap)
        XCTAssertEqual(
            state,
            .init(wantsListening: true, isHUDPresented: true)
        )

        state = RightOptionInteractionReducer.reduce(state, gesture: .hold)
        XCTAssertEqual(
            state,
            .init(wantsListening: true, isHUDPresented: false)
        )

        state = RightOptionInteractionReducer.reduce(state, gesture: .hold)
        XCTAssertEqual(
            state,
            .init(wantsListening: true, isHUDPresented: true)
        )

        state = RightOptionInteractionReducer.reduce(state, gesture: .tap)
        XCTAssertEqual(
            state,
            .init(wantsListening: false, isHUDPresented: false)
        )
    }

    func testOnlyPhysicalRightOptionIsRecognized() {
        XCTAssertTrue(RightOptionEventFilter.recognizes(keyCode: 61))
        XCTAssertFalse(RightOptionEventFilter.recognizes(keyCode: 58))
        XCTAssertFalse(RightOptionEventFilter.recognizes(keyCode: 55))
    }

    @MainActor
    func testClassifierEmitsTapOnlyOnRelease() async {
        var gestures: [RightOptionGesture] = []
        let classifier = RightOptionPressClassifier(
            holdDuration: .milliseconds(50),
            onGesture: { gestures.append($0) }
        )

        classifier.process(isDown: true)
        XCTAssertTrue(gestures.isEmpty)
        classifier.process(isDown: false)
        XCTAssertEqual(gestures, [.tap])
    }

    @MainActor
    func testClassifierEmitsOneHoldAndConsumesRelease() async {
        var gestures: [RightOptionGesture] = []
        let classifier = RightOptionPressClassifier(
            holdDuration: .milliseconds(10),
            onGesture: { gestures.append($0) }
        )

        classifier.process(isDown: true)
        try? await Task.sleep(for: .milliseconds(30))
        classifier.process(isDown: true)
        classifier.process(isDown: false)

        XCTAssertEqual(gestures, [.hold])
    }

    @MainActor
    func testClassifierResetCancelsPendingHold() async {
        var gestures: [RightOptionGesture] = []
        let classifier = RightOptionPressClassifier(
            holdDuration: .milliseconds(10),
            onGesture: { gestures.append($0) }
        )

        classifier.process(isDown: true)
        classifier.reset()
        try? await Task.sleep(for: .milliseconds(30))

        XCTAssertTrue(gestures.isEmpty)
    }

    @MainActor
    func testClassifierHandlesRapidRepeatedTaps() {
        var gestures: [RightOptionGesture] = []
        let classifier = RightOptionPressClassifier(
            holdDuration: .seconds(1),
            onGesture: { gestures.append($0) }
        )

        for _ in 0..<4 {
            classifier.process(isDown: true)
            classifier.process(isDown: false)
        }

        XCTAssertEqual(gestures, [.tap, .tap, .tap, .tap])
    }
}
