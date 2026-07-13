import CoreGraphics
import XCTest

final class DashboardPanelPlacementTests: XCTestCase {
    func testPlacesPanelCenteredBelowAnchor() throws {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1_440, height: 877)
        let anchor = CGRect(x: 700, y: 877, width: 32, height: 24)

        let frame = try XCTUnwrap(
            DashboardPanelPlacement.frame(
                below: anchor,
                preferredSize: DashboardPanelMetrics.preferredSize,
                visibleFrame: visibleFrame
            )
        )

        XCTAssertEqual(frame.midX, anchor.midX, accuracy: 0.001)
        assertBelowAndVisible(frame, anchor: anchor, visibleFrame: visibleFrame)
    }

    func testClampsPanelAtRightEdge() throws {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1_440, height: 877)
        let anchor = CGRect(x: 1_410, y: 877, width: 24, height: 24)
        let frame = try XCTUnwrap(
            DashboardPanelPlacement.frame(
                below: anchor,
                preferredSize: DashboardPanelMetrics.preferredSize,
                visibleFrame: visibleFrame
            )
        )

        XCTAssertEqual(frame.maxX, visibleFrame.maxX - 8, accuracy: 0.001)
        assertBelowAndVisible(frame, anchor: anchor, visibleFrame: visibleFrame)
    }

    func testSupportsNegativeOriginExternalDisplay() throws {
        let visibleFrame = CGRect(x: -1_440, y: 40, width: 1_440, height: 860)
        let anchor = CGRect(x: -1_430, y: 900, width: 30, height: 24)
        let frame = try XCTUnwrap(
            DashboardPanelPlacement.frame(
                below: anchor,
                preferredSize: DashboardPanelMetrics.preferredSize,
                visibleFrame: visibleFrame
            )
        )

        XCTAssertEqual(frame.minX, visibleFrame.minX + 8, accuracy: 0.001)
        assertBelowAndVisible(frame, anchor: anchor, visibleFrame: visibleFrame)
    }

    func testSupportsVerticallyOffsetDisplay() throws {
        let visibleFrame = CGRect(x: 120, y: 900, width: 1_600, height: 900)
        let anchor = CGRect(x: 900, y: 1_800, width: 30, height: 24)
        let frame = try XCTUnwrap(
            DashboardPanelPlacement.frame(
                below: anchor,
                preferredSize: DashboardPanelMetrics.preferredSize,
                visibleFrame: visibleFrame
            )
        )

        assertBelowAndVisible(frame, anchor: anchor, visibleFrame: visibleFrame)
    }

    func testShrinksTallPanelInsteadOfFlippingAbove() throws {
        let visibleFrame = CGRect(x: 0, y: 0, width: 900, height: 500)
        let anchor = CGRect(x: 430, y: 500, width: 30, height: 24)
        let frame = try XCTUnwrap(
            DashboardPanelPlacement.frame(
                below: anchor,
                preferredSize: CGSize(width: 388, height: 1_000),
                visibleFrame: visibleFrame
            )
        )

        XCTAssertLessThan(frame.height, 1_000)
        assertBelowAndVisible(frame, anchor: anchor, visibleFrame: visibleFrame)
    }

    func testChoosesScreenContainingAnchorInsteadOfKeyWindowScreen() {
        let screens = [
            CGRect(x: 0, y: 0, width: 1_440, height: 900),
            CGRect(x: 0, y: 900, width: 1_920, height: 1_080),
        ]
        let anchor = CGRect(x: 1_200, y: 1_950, width: 30, height: 24)

        XCTAssertEqual(
            DashboardPanelPlacement.bestScreenIndex(
                for: anchor,
                screenFrames: screens
            ),
            1
        )
    }

    func testChoosesNearestScreenWhenAnchorDoesNotIntersectOne() {
        let screens = [
            CGRect(x: 0, y: 0, width: 1_000, height: 800),
            CGRect(x: 1_200, y: 0, width: 1_000, height: 800),
        ]
        let anchor = CGRect(x: 1_130, y: 760, width: 20, height: 20)

        XCTAssertEqual(
            DashboardPanelPlacement.bestScreenIndex(
                for: anchor,
                screenFrames: screens
            ),
            1
        )
    }

    private func assertBelowAndVisible(
        _ frame: CGRect,
        anchor: CGRect,
        visibleFrame: CGRect,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertLessThanOrEqual(
            frame.maxY,
            anchor.minY - DashboardPanelMetrics.anchorGap + 0.001,
            file: file,
            line: line
        )
        XCTAssertTrue(
            visibleFrame.insetBy(
                dx: DashboardPanelMetrics.screenInset,
                dy: DashboardPanelMetrics.screenInset
            ).contains(frame),
            file: file,
            line: line
        )
    }
}
