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

    func testFrameUpdatesIgnoreSubpixelJitter() {
        let current = CGRect(x: 784, y: 1_125, width: 232, height: 44)

        XCTAssertFalse(
            NotchPanelLayoutCalculator.requiresFrameUpdate(
                current: current,
                target: current.offsetBy(dx: -0.25, dy: 0.25)
            )
        )
        XCTAssertTrue(
            NotchPanelLayoutCalculator.requiresFrameUpdate(
                current: current,
                target: CGRect(x: 784, y: 1_125, width: 320, height: 44)
            )
        )
    }

    func testNotchGeometryUsesTheGapBetweenAuxiliaryAreas() {
        XCTAssertEqual(
            NotchPanelLayoutCalculator.surfaceStyle(for: notchedDisplay),
            .attached(notchWidth: 220, notchHeight: 38)
        )
    }

    func testCornerRadiusIsProportionalAndCapped() {
        XCTAssertEqual(
            NotchPanelLayoutCalculator.attachedBottomCornerRadius(
                notchHeight: 38
            ),
            12
        )
        XCTAssertEqual(
            NotchPanelLayoutCalculator.attachedBottomCornerRadius(
                notchHeight: 30
            ),
            9.6,
            accuracy: 0.000_1
        )
    }

    func testAttachedSurfaceUsesTheExactRequestedBounds() {
        let rect = CGRect(x: 0, y: 0, width: 220, height: 38)
        let surface = AttachedNotchGeometry.surfacePath(
            in: rect,
            surfaceHeight: 38,
            bottomCornerRadius: 12
        ).boundingBoxOfPath

        XCTAssertEqual(surface, rect)
    }

    func testAttachedListeningCanvasKeepsThePhysicalNotchAsItsAnchor() {
        let layout = NotchPanelLayoutCalculator.layout(
            visualState: .listening,
            interactionMode: .passive,
            display: notchedDisplay
        )

        XCTAssertEqual(layout.frame.width, 520)
        XCTAssertEqual(layout.frame.height, 38)
        XCTAssertEqual(layout.frame.minX, 790)
        XCTAssertEqual(layout.frame.maxY, notchedDisplay.frame.maxY)
        XCTAssertEqual(layout.surfaceSize, CGSize(width: 220, height: 38))
        XCTAssertEqual(
            layout.frame.minX + layout.surfaceSize.width / 2,
            notchedDisplay.frame.midX
        )
    }

    func testAttachedListeningSurfaceExactlyMatchesTheReportedExclusion() {
        let layout = NotchPanelLayoutCalculator.layout(
            visualState: .listening,
            interactionMode: .passive,
            display: notchedDisplay
        )
        let reportedNotchLeft = notchedDisplay
            .auxiliaryTopLeftArea!
            .maxX
        let reportedNotchRight = notchedDisplay
            .auxiliaryTopRightArea!
            .minX
        let reportedNotchBottom =
            notchedDisplay.frame.maxY
            - notchedDisplay.safeAreaTop

        XCTAssertEqual(layout.frame.minX, reportedNotchLeft)
        XCTAssertEqual(
            layout.frame.minX + layout.surfaceSize.width,
            reportedNotchRight
        )
        XCTAssertEqual(
            layout.frame.maxY - layout.surfaceSize.height,
            reportedNotchBottom
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

        XCTAssertEqual(success.frame, listening.frame)
        XCTAssertGreaterThan(success.surfaceSize.width, listening.surfaceSize.width)
        XCTAssertEqual(success.surfaceSize.height, listening.surfaceSize.height)
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

        XCTAssertEqual(failure.frame, listening.frame)
        XCTAssertGreaterThan(failure.surfaceSize.width, listening.surfaceSize.width)
        XCTAssertEqual(failure.surfaceSize.height, listening.surfaceSize.height)
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
        XCTAssertEqual(layout.frame.width, 452)
        XCTAssertEqual(layout.frame.height, 38)
        XCTAssertEqual(
            layout.frame.maxY,
            display.visibleFrame.maxY
                - NotchPanelLayoutCalculator.floatingTopInset
        )
        XCTAssertEqual(layout.surfaceSize, CGSize(width: 152, height: 38))
        XCTAssertEqual(
            layout.frame.minX + layout.surfaceSize.width / 2,
            display.frame.midX
        )
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

        XCTAssertEqual(success.frame, listening.frame)
        XCTAssertGreaterThan(success.surfaceSize.width, listening.surfaceSize.width)
        XCTAssertEqual(success.surfaceSize.height, listening.surfaceSize.height)
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

        XCTAssertGreaterThan(compact.frame.height, passive.frame.height)
        XCTAssertGreaterThan(expanded.frame.height, compact.frame.height)
        XCTAssertEqual(compact.surfaceSize, compact.frame.size)
        XCTAssertEqual(expanded.surfaceSize, expanded.frame.size)
        XCTAssertEqual(compact.frame.maxY, passive.frame.maxY)
        XCTAssertEqual(expanded.frame.maxY, passive.frame.maxY)
    }
}
