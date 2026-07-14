import CoreGraphics
import XCTest

final class NotchPanelLayoutTests: XCTestCase {
    private let notchedDisplay = NotchDisplayGeometry(
        frame: CGRect(x: 0, y: 0, width: 1_800, height: 1_169),
        visibleFrame: CGRect(x: 0, y: 59, width: 1_800, height: 1_071),
        safeAreaTop: 38,
        auxiliaryTopLeftArea: CGRect(x: 0, y: 1_131, width: 790, height: 38),
        auxiliaryTopRightArea: CGRect(x: 1_010, y: 1_131, width: 790, height: 38)
    )

    func testNotchGeometryUsesTheGapBetweenAuxiliaryAreas() {
        XCTAssertEqual(
            NotchPanelLayoutCalculator.surfaceStyle(for: notchedDisplay),
            .attached(notchWidth: 220, notchHeight: 38)
        )
    }

    func testAttachedListeningCanvasSurroundsSystemReportedNotch() {
        let layout = NotchPanelLayoutCalculator.layout(
            visualState: .listening,
            interactionMode: .passive,
            display: notchedDisplay
        )

        XCTAssertEqual(layout.frame.width, 232)
        XCTAssertEqual(layout.frame.height, 44)
        XCTAssertEqual(layout.frame.minX, 784)
        XCTAssertEqual(layout.frame.midX, notchedDisplay.frame.midX)
        XCTAssertEqual(layout.frame.maxY, notchedDisplay.frame.maxY)
        XCTAssertEqual(
            layout.frame.minX
                + NotchPanelLayoutCalculator
                    .attachedHorizontalCanvasOutset,
            790
        )
        XCTAssertEqual(
            layout.frame.minY
                + NotchPanelLayoutCalculator.attachedBottomCanvasOutset,
            1_131
        )
    }

    func testVisibleBorderSitsOutsideHardwareExclusionOnEveryEdge() {
        let layout = NotchPanelLayoutCalculator.layout(
            visualState: .listening,
            interactionMode: .passive,
            display: notchedDisplay
        )
        let horizontalCanvas = NotchPanelLayoutCalculator
            .attachedHorizontalCanvasOutset
        let borderOutset = NotchPanelLayoutCalculator
            .attachedVisibleBorderOutset
        let reportedNotchLeft = notchedDisplay
            .auxiliaryTopLeftArea!
            .maxX
        let reportedNotchRight = notchedDisplay
            .auxiliaryTopRightArea!
            .minX
        let reportedNotchBottom = notchedDisplay.frame.maxY
            - notchedDisplay.safeAreaTop

        XCTAssertLessThan(
            layout.frame.minX + horizontalCanvas - borderOutset,
            reportedNotchLeft
        )
        XCTAssertGreaterThan(
            layout.frame.maxX - horizontalCanvas + borderOutset,
            reportedNotchRight
        )
        XCTAssertLessThan(
            layout.frame.maxY
                - notchedDisplay.safeAreaTop
                - borderOutset,
            reportedNotchBottom
        )
        XCTAssertGreaterThan(
            NotchPanelLayoutCalculator.attachedBottomCanvasOutset,
            borderOutset
        )
    }

    func testSuccessExpandsOnlyRightFromPhysicalNotch() {
        let listening = NotchPanelLayoutCalculator.layout(
            visualState: .listening,
            interactionMode: .passive,
            display: notchedDisplay
        )
        let success = NotchPanelLayoutCalculator.layout(
            visualState: .success(action: .copy, label: "House"),
            interactionMode: .passive,
            display: notchedDisplay
        )

        XCTAssertGreaterThan(success.frame.width, listening.frame.width)
        XCTAssertEqual(success.frame.height, listening.frame.height)
        XCTAssertEqual(success.frame.minX, listening.frame.minX)
        XCTAssertEqual(success.frame.minY, listening.frame.minY)
        XCTAssertEqual(success.frame.maxY, listening.frame.maxY)
        XCTAssertGreaterThan(success.frame.maxX, listening.frame.maxX)
    }

    func testFailureAlsoExpandsOnlyRightFromPhysicalNotch() {
        let listening = NotchPanelLayoutCalculator.layout(
            visualState: .listening,
            interactionMode: .passive,
            display: notchedDisplay
        )
        let failure = NotchPanelLayoutCalculator.layout(
            visualState: .failure(message: "Clipboard unavailable"),
            interactionMode: .passive,
            display: notchedDisplay
        )

        XCTAssertEqual(failure.frame.minX, listening.frame.minX)
        XCTAssertEqual(failure.frame.minY, listening.frame.minY)
        XCTAssertEqual(failure.frame.height, listening.frame.height)
        XCTAssertGreaterThan(failure.frame.maxX, listening.frame.maxX)
    }

    func testDisplayWithoutNotchUsesFloatingPanelBelowMenuBar() {
        let display = NotchDisplayGeometry(
            frame: CGRect(x: -1_440, y: 0, width: 1_440, height: 900),
            visibleFrame: CGRect(x: -1_440, y: 40, width: 1_440, height: 836),
            safeAreaTop: 0,
            auxiliaryTopLeftArea: nil,
            auxiliaryTopRightArea: nil
        )
        let layout = NotchPanelLayoutCalculator.layout(
            visualState: .listening,
            interactionMode: .passive,
            display: display
        )

        XCTAssertEqual(layout.surfaceStyle, .floating)
        XCTAssertEqual(layout.frame.width, 152)
        XCTAssertEqual(layout.frame.height, 38)
        XCTAssertEqual(
            layout.frame.maxY,
            display.visibleFrame.maxY
                - NotchPanelLayoutCalculator.floatingTopInset
        )
        XCTAssertEqual(layout.frame.midX, display.frame.midX)
    }

    func testNotchlessSuccessKeepsListeningCapsuleLeftEdge() {
        let display = NotchDisplayGeometry(
            frame: CGRect(x: -1_440, y: 0, width: 1_440, height: 900),
            visibleFrame: CGRect(x: -1_440, y: 40, width: 1_440, height: 836),
            safeAreaTop: 0,
            auxiliaryTopLeftArea: nil,
            auxiliaryTopRightArea: nil
        )
        let listening = NotchPanelLayoutCalculator.layout(
            visualState: .listening,
            interactionMode: .passive,
            display: display
        )
        let success = NotchPanelLayoutCalculator.layout(
            visualState: .success(action: .paste, label: "2"),
            interactionMode: .passive,
            display: display
        )

        XCTAssertEqual(success.frame.minX, listening.frame.minX)
        XCTAssertEqual(success.frame.height, listening.frame.height)
        XCTAssertGreaterThan(success.frame.maxX, listening.frame.maxX)
    }

    func testSafeInsetWithoutAuxiliaryAreasFallsBackInsteadOfGuessing() {
        let display = NotchDisplayGeometry(
            frame: CGRect(x: 0, y: 0, width: 1_024, height: 768),
            visibleFrame: CGRect(x: 0, y: 30, width: 1_024, height: 714),
            safeAreaTop: 24,
            auxiliaryTopLeftArea: nil,
            auxiliaryTopRightArea: nil
        )

        XCTAssertEqual(
            NotchPanelLayoutCalculator.surfaceStyle(for: display),
            .floating
        )
    }

    func testFutureInteractiveModesReuseTheSameAnchoredSurface() {
        let passive = NotchPanelLayoutCalculator.layout(
            visualState: .listening,
            interactionMode: .passive,
            display: notchedDisplay
        )
        let compact = NotchPanelLayoutCalculator.layout(
            visualState: .listening,
            interactionMode: .compactInteractive,
            display: notchedDisplay
        )
        let expanded = NotchPanelLayoutCalculator.layout(
            visualState: .listening,
            interactionMode: .expandedInteractive,
            display: notchedDisplay
        )

        XCTAssertGreaterThan(compact.frame.width, passive.frame.width)
        XCTAssertGreaterThan(compact.frame.height, passive.frame.height)
        XCTAssertGreaterThan(expanded.frame.width, compact.frame.width)
        XCTAssertGreaterThan(expanded.frame.height, compact.frame.height)
        XCTAssertEqual(compact.frame.maxY, passive.frame.maxY)
        XCTAssertEqual(expanded.frame.maxY, passive.frame.maxY)
    }
}
