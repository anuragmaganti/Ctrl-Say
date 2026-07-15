import AppKit
import XCTest

@MainActor
final class NativeTooltipRegionTests: XCTestCase {
    func testRegistersNativeTooltipForExactRegionWithoutTakingHitTests() {
        let parent = RecordingTooltipView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 80)
        )
        let region = NativeTooltipRegion.RegistrationView(
            frame: NSRect(x: 12, y: 8, width: 280, height: 32)
        )
        let tooltip = "Bounded clipboard preview"
        region.tooltipText = tooltip

        parent.addSubview(region)
        region.layoutSubtreeIfNeeded()

        XCTAssertEqual(parent.registeredRect, region.frame)
        XCTAssertTrue(parent.registeredOwner === region)
        XCTAssertNil(region.hitTest(NSPoint(x: 2, y: 2)))
        XCTAssertEqual(
            region.view(
                parent,
                stringForToolTip: parent.registeredTag,
                point: .zero,
                userData: nil
            ),
            tooltip
        )
    }
}

@MainActor
private final class RecordingTooltipView: NSView {
    private(set) var registeredRect: NSRect?
    private(set) weak var registeredOwner: AnyObject?
    private(set) var registeredTag: NSView.ToolTipTag = 0

    override func addToolTip(
        _ rect: NSRect,
        owner: Any,
        userData data: UnsafeMutableRawPointer?
    ) -> NSView.ToolTipTag {
        registeredRect = rect
        registeredOwner = owner as AnyObject
        registeredTag = super.addToolTip(rect, owner: owner, userData: data)
        return registeredTag
    }
}
