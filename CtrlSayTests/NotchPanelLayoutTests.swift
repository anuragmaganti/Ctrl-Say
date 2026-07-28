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
            NotchPanelLayoutCalculator.surfaceGeometry(for: notchedDisplay),
            NotchSurfaceGeometry(notchWidth: 220, notchHeight: 38)
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

    func testAttachedListeningCanvasKeepsThePhysicalNotchAsItsAnchor() throws {
        let layout = try attachedLayout(
            visualState: .listening,
            interactionMode: .passive
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

    func testAttachedListeningSurfaceExactlyMatchesTheReportedExclusion() throws {
        let layout = try attachedLayout(
            visualState: .listening,
            interactionMode: .passive
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

    func testSuccessExpandsOnlyRightFromPhysicalNotch() throws {
        let listening = try attachedLayout(
            visualState: .listening,
            interactionMode: .passive
        )
        let success = try attachedLayout(
            visualState: .success(action: .copy, label: "House"),
            interactionMode: .passive
        )

        XCTAssertEqual(success.frame, listening.frame)
        XCTAssertGreaterThan(success.surfaceSize.width, listening.surfaceSize.width)
        XCTAssertEqual(success.surfaceSize.height, listening.surfaceSize.height)
    }

    func testPendingCopyUsesTheSameRightwardGeometryAsSuccess() throws {
        let pending = try attachedLayout(
            visualState: .pending(action: .copy, label: "House"),
            interactionMode: .passive
        )
        let success = try attachedLayout(
            visualState: .success(action: .copy, label: "House"),
            interactionMode: .passive
        )

        XCTAssertEqual(pending.frame, success.frame)
        XCTAssertEqual(pending.surfaceSize, success.surfaceSize)
    }

    func testFailureAlsoExpandsOnlyRightFromPhysicalNotch() throws {
        let listening = try attachedLayout(
            visualState: .listening,
            interactionMode: .passive
        )
        let failure = try attachedLayout(
            visualState: .failure(message: "Clipboard unavailable"),
            interactionMode: .passive
        )

        XCTAssertEqual(failure.frame, listening.frame)
        XCTAssertGreaterThan(failure.surfaceSize.width, listening.surfaceSize.width)
        XCTAssertEqual(failure.surfaceSize.height, listening.surfaceSize.height)
    }

    func testDisplayWithoutNotchProducesNoPanelLayout() {
        let display = NotchDisplayGeometry(
            frame: CGRect(x: -1_440, y: 0, width: 1_440, height: 900),
            visibleFrame: CGRect(x: -1_440, y: 40, width: 1_440, height: 836),
            safeAreaTop: 0,
            auxiliaryTopLeftArea: nil,
            auxiliaryTopRightArea: nil
        )
        XCTAssertNil(NotchPanelLayoutCalculator.surfaceGeometry(for: display))
        XCTAssertNil(
            NotchPanelLayoutCalculator.layout(
                visualState: .listening,
                interactionMode: .passive,
                display: display
            )
        )
    }

    func testOnlyPrimaryBuiltInUnmirroredDisplayIsEligible() {
        XCTAssertTrue(
            NotchDisplayEligibility.allowsPresentation(
                isPrimary: true,
                isBuiltIn: true,
                isMirrored: false
            )
        )
        XCTAssertFalse(
            NotchDisplayEligibility.allowsPresentation(
                isPrimary: true,
                isBuiltIn: false,
                isMirrored: false
            )
        )
        XCTAssertFalse(
            NotchDisplayEligibility.allowsPresentation(
                isPrimary: false,
                isBuiltIn: true,
                isMirrored: false
            )
        )
        XCTAssertFalse(
            NotchDisplayEligibility.allowsPresentation(
                isPrimary: true,
                isBuiltIn: true,
                isMirrored: true
            )
        )
    }

    func testSafeInsetWithoutAuxiliaryAreasProducesNoNotchGeometry() {
        let display = NotchDisplayGeometry(
            frame: CGRect(x: 0, y: 0, width: 1_024, height: 768),
            visibleFrame: CGRect(x: 0, y: 30, width: 1_024, height: 714),
            safeAreaTop: 24,
            auxiliaryTopLeftArea: nil,
            auxiliaryTopRightArea: nil
        )

        XCTAssertNil(NotchPanelLayoutCalculator.surfaceGeometry(for: display))
    }

    func testFutureInteractiveModesReuseTheSameAnchoredSurface() throws {
        let passive = try attachedLayout(
            visualState: .listening,
            interactionMode: .passive
        )
        let compact = try attachedLayout(
            visualState: .listening,
            interactionMode: .compactInteractive
        )
        let expanded = try attachedLayout(
            visualState: .listening,
            interactionMode: .expandedInteractive
        )

        XCTAssertGreaterThan(compact.frame.height, passive.frame.height)
        XCTAssertGreaterThan(expanded.frame.height, compact.frame.height)
        XCTAssertEqual(compact.surfaceSize, compact.frame.size)
        XCTAssertEqual(expanded.surfaceSize, expanded.frame.size)
        XCTAssertEqual(compact.frame.maxY, passive.frame.maxY)
        XCTAssertEqual(expanded.frame.maxY, passive.frame.maxY)
    }

    private func attachedLayout(
        visualState: NotchVisualState,
        interactionMode: NotchInteractionMode
    ) throws -> NotchPanelLayout {
        try XCTUnwrap(
            NotchPanelLayoutCalculator.layout(
                visualState: visualState,
                interactionMode: interactionMode,
                display: notchedDisplay
            )
        )
    }
}
