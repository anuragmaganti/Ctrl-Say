import Foundation
import XCTest

final class RightOptionInteractionTests: XCTestCase {
    func testTapStartsListeningAndShowsHUDByDefault() {
        let state = RightOptionInteractionReducer.reduce(
            .init(wantsListening: false, isHUDPresented: false),
            gesture: .tap,
            showsHUDWhenListeningStarts: true
        )

        XCTAssertEqual(
            state,
            .init(wantsListening: true, isHUDPresented: true)
        )
    }

    func testTapCanStartListeningWithoutShowingHUD() {
        let state = RightOptionInteractionReducer.reduce(
            .init(wantsListening: false, isHUDPresented: false),
            gesture: .tap,
            showsHUDWhenListeningStarts: false
        )

        XCTAssertEqual(
            state,
            .init(wantsListening: true, isHUDPresented: false)
        )
    }

    func testTapStopsListeningAndPreservesHUDVisibility() {
        XCTAssertEqual(
            RightOptionInteractionReducer.reduce(
                .init(wantsListening: true, isHUDPresented: true),
                gesture: .tap,
                showsHUDWhenListeningStarts: true
            ),
            .init(wantsListening: false, isHUDPresented: true)
        )
        XCTAssertEqual(
            RightOptionInteractionReducer.reduce(
                .init(wantsListening: true, isHUDPresented: false),
                gesture: .tap,
                showsHUDWhenListeningStarts: true
            ),
            .init(wantsListening: false, isHUDPresented: false)
        )
    }

    func testHoldTogglesHUDWhileListeningIsOff() {
        XCTAssertEqual(
            RightOptionInteractionReducer.reduce(
                .init(wantsListening: false, isHUDPresented: false),
                gesture: .hold,
                showsHUDWhenListeningStarts: true
            ),
            .init(wantsListening: false, isHUDPresented: true)
        )
        XCTAssertEqual(
            RightOptionInteractionReducer.reduce(
                .init(wantsListening: false, isHUDPresented: true),
                gesture: .hold,
                showsHUDWhenListeningStarts: true
            ),
            .init(wantsListening: false, isHUDPresented: false)
        )
    }

    func testHoldStopsListeningAndHidesHUD() {
        XCTAssertEqual(
            RightOptionInteractionReducer.reduce(
                .init(wantsListening: true, isHUDPresented: true),
                gesture: .hold,
                showsHUDWhenListeningStarts: true
            ),
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
