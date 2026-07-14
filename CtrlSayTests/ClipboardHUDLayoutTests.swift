import CoreGraphics
import XCTest

final class ClipboardHUDLayoutTests: XCTestCase {
    func testDefaultPlacementUsesTopRightInset() {
        let visible = CGRect(x: -1_920, y: 23, width: 1_920, height: 1_057)
        let frame = ClipboardHUDPlacement.defaultFrame(
            height: 300,
            visibleFrame: visible
        )

        XCTAssertEqual(frame.width, 360)
        XCTAssertEqual(frame.maxX, visible.maxX - 16)
        XCTAssertEqual(frame.maxY, visible.maxY - 16)
        XCTAssertTrue(visible.contains(frame))
    }

    func testHeightCapsAtExactlySeventyFivePercent() {
        let visible = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let height = ClipboardHUDMetrics.height(
            itemCount: 100,
            collection: .numbered,
            visibleFrame: visible
        )

        XCTAssertEqual(height, 675)
    }

    func testHeightGrowsUntilCap() {
        let visible = CGRect(x: 0, y: 0, width: 1_440, height: 1_000)
        let empty = ClipboardHUDMetrics.height(
            itemCount: 0,
            collection: .numbered,
            visibleFrame: visible
        )
        let one = ClipboardHUDMetrics.height(
            itemCount: 1,
            collection: .numbered,
            visibleFrame: visible
        )
        let ten = ClipboardHUDMetrics.height(
            itemCount: 10,
            collection: .numbered,
            visibleFrame: visible
        )

        XCTAssertGreaterThan(one, empty)
        XCTAssertEqual(ten, 750)
    }

    func testPermanentCollectionOmitsNumberedFooter() {
        let numbered = ClipboardHUDMetrics.idealHeight(
            itemCount: 3,
            collection: .numbered
        )
        let permanent = ClipboardHUDMetrics.idealHeight(
            itemCount: 3,
            collection: .permanent
        )

        XCTAssertEqual(
            numbered - permanent,
            ClipboardHUDMetrics.numberedFooterHeight
        )
    }

    func testPermanentStorageStatusIsIncludedWithoutDuplicatingEmptyState() {
        let loading = ClipboardHUDMetrics.idealHeight(
            itemCount: 0,
            collection: .permanent,
            permanentStatusLayout: .replacesContent
        )
        let failedWithCopies = ClipboardHUDMetrics.idealHeight(
            itemCount: 2,
            collection: .permanent,
            permanentStatusLayout: .precedesContent
        )

        XCTAssertEqual(
            loading,
            ClipboardHUDMetrics.headerHeight
                + ClipboardHUDMetrics.listVerticalPadding
                + ClipboardHUDMetrics.permanentStatusHeight
        )
        XCTAssertEqual(
            failedWithCopies - ClipboardHUDMetrics.permanentStatusHeight,
            ClipboardHUDMetrics.idealHeight(
                itemCount: 2,
                collection: .permanent
            )
        )
    }

    func testResizePreservesTopEdgeAndClampsBottom() {
        let visible = CGRect(x: 0, y: 25, width: 1_440, height: 875)
        let current = CGRect(x: 1_000, y: 500, width: 360, height: 250)
        let grown = ClipboardHUDPlacement.resizedFrame(
            from: current,
            height: 500,
            visibleFrame: visible
        )

        XCTAssertEqual(grown.maxY, current.maxY)
        XCTAssertEqual(grown.minY, 250)

        let clamped = ClipboardHUDPlacement.resizedFrame(
            from: CGRect(x: 1_000, y: 50, width: 360, height: 250),
            height: 600,
            visibleFrame: visible
        )
        XCTAssertEqual(clamped.minY, visible.minY)
    }

    func testNormalizedPositionRoundTripsOnNegativeOriginDisplay() {
        let visible = CGRect(x: -1_600, y: -900, width: 1_600, height: 900)
        let original = CGRect(x: -1_200, y: -720, width: 360, height: 400)
        let normalized = ClipboardHUDPlacement.normalizedPosition(
            for: original,
            visibleFrame: visible
        )
        let restored = ClipboardHUDPlacement.frame(
            normalizedPosition: normalized,
            size: original.size,
            visibleFrame: visible
        )

        XCTAssertEqual(restored.minX, original.minX, accuracy: 0.001)
        XCTAssertEqual(restored.maxY, original.maxY, accuracy: 0.001)
    }

    func testRestoreClampsAfterResolutionChange() {
        let normalized = ClipboardHUDNormalizedPosition(
            horizontal: 1,
            verticalFromTop: 1
        )
        let visible = CGRect(x: 0, y: 38, width: 1_024, height: 700)
        let frame = ClipboardHUDPlacement.frame(
            normalizedPosition: normalized,
            size: CGSize(width: 360, height: 525),
            visibleFrame: visible
        )

        XCTAssertEqual(frame.maxX, visible.maxX)
        XCTAssertEqual(frame.minY, visible.minY)
        XCTAssertTrue(visible.contains(frame))
    }

    func testPositionStoreKeepsIndependentDisplayEntries() {
        let suite = "ClipboardHUDLayoutTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ClipboardHUDPositionStore(defaults: defaults)
        let first = ClipboardHUDNormalizedPosition(
            horizontal: 0.1,
            verticalFromTop: 0.2
        )
        let second = ClipboardHUDNormalizedPosition(
            horizontal: 0.9,
            verticalFromTop: 0.8
        )

        store.save(first, for: "display-a")
        store.save(second, for: "display-b")

        XCTAssertEqual(store.position(for: "display-a"), first)
        XCTAssertEqual(store.position(for: "display-b"), second)
    }

    func testPositionForDisconnectedDisplayDoesNotAffectCurrentDisplay() {
        let suite = "ClipboardHUDLayoutTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ClipboardHUDPositionStore(defaults: defaults)
        store.save(
            .init(horizontal: 0.25, verticalFromTop: 0.75),
            for: "disconnected"
        )

        XCTAssertNil(store.position(for: "current"))
    }
}
