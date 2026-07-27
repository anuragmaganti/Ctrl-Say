import CoreGraphics
import Foundation

enum ClipboardCollection: String, CaseIterable, Identifiable, Sendable {
    case numbered = "Temporary"
    case permanent = "Permanent"

    var id: Self { self }
}

enum ClipboardHUDPermanentStatusLayout: Sendable {
    case none
    case replacesContent
    case precedesContent
}

enum ClipboardHUDMetrics {
    static let width: CGFloat = 360
    static let cornerRadius: CGFloat = 24
    static let defaultInset: CGFloat = 16
    static let maximumHeightFraction: CGFloat = 0.75
    static let headerHeight: CGFloat = 58
    static let rowHeight: CGFloat = 66
    static let emptyListHeight: CGFloat = 50
    static let listVerticalPadding: CGFloat = 12
    static let numberedFooterHeight: CGFloat = 24
    static let permanentStatusHeight: CGFloat = 48

    static func idealHeight(
        itemCount: Int,
        collection: ClipboardCollection,
        permanentStatusLayout: ClipboardHUDPermanentStatusLayout = .none
    ) -> CGFloat {
        let copyContentHeight =
            itemCount == 0
            ? emptyListHeight
            : CGFloat(itemCount) * rowHeight
        let listHeight: CGFloat
        switch permanentStatusLayout {
        case .none:
            listHeight = copyContentHeight
        case .replacesContent:
            listHeight = permanentStatusHeight
        case .precedesContent:
            listHeight = permanentStatusHeight + copyContentHeight
        }
        let footerHeight =
            collection == .numbered && itemCount > 0
            ? numberedFooterHeight
            : 0
        let showsStoredCopies =
            itemCount > 0
            && permanentStatusLayout != .replacesContent
        let appliedListPadding =
            showsStoredCopies
            ? listVerticalPadding / 2
            : listVerticalPadding
        return headerHeight
            + appliedListPadding
            + listHeight
            + footerHeight
    }

    static func height(
        itemCount: Int,
        collection: ClipboardCollection,
        permanentStatusLayout: ClipboardHUDPermanentStatusLayout = .none,
        visibleFrame: CGRect
    ) -> CGFloat {
        min(
            idealHeight(
                itemCount: itemCount,
                collection: collection,
                permanentStatusLayout: permanentStatusLayout
            ),
            max(0, visibleFrame.height * maximumHeightFraction)
        )
    }
}

struct ClipboardHUDNormalizedPosition: Codable, Equatable, Sendable {
    var horizontal: Double
    var verticalFromTop: Double

    init(horizontal: Double, verticalFromTop: Double) {
        self.horizontal = horizontal.clamped(to: 0...1)
        self.verticalFromTop = verticalFromTop.clamped(to: 0...1)
    }
}

enum ClipboardHUDPlacement {
    static func defaultFrame(
        height: CGFloat,
        visibleFrame: CGRect
    ) -> CGRect {
        let size = CGSize(width: ClipboardHUDMetrics.width, height: height)
        let topLeft = CGPoint(
            x: visibleFrame.maxX - ClipboardHUDMetrics.defaultInset - size.width,
            y: visibleFrame.maxY - ClipboardHUDMetrics.defaultInset
        )
        return frame(topLeft: topLeft, size: size, visibleFrame: visibleFrame)
    }

    static func frame(
        normalizedPosition: ClipboardHUDNormalizedPosition,
        size: CGSize,
        visibleFrame: CGRect
    ) -> CGRect {
        let availableX = max(0, visibleFrame.width - size.width)
        let availableY = max(0, visibleFrame.height - size.height)
        let topLeft = CGPoint(
            x: visibleFrame.minX
                + availableX * normalizedPosition.horizontal,
            y: visibleFrame.maxY
                - availableY * normalizedPosition.verticalFromTop
        )
        return frame(topLeft: topLeft, size: size, visibleFrame: visibleFrame)
    }

    static func normalizedPosition(
        for frame: CGRect,
        visibleFrame: CGRect
    ) -> ClipboardHUDNormalizedPosition {
        let clampedFrame = self.frame(
            topLeft: CGPoint(x: frame.minX, y: frame.maxY),
            size: frame.size,
            visibleFrame: visibleFrame
        )
        let availableX = max(0, visibleFrame.width - clampedFrame.width)
        let availableY = max(0, visibleFrame.height - clampedFrame.height)
        let horizontal =
            availableX == 0
            ? 0
            : (clampedFrame.minX - visibleFrame.minX) / availableX
        let vertical =
            availableY == 0
            ? 0
            : (visibleFrame.maxY - clampedFrame.maxY) / availableY
        return ClipboardHUDNormalizedPosition(
            horizontal: horizontal,
            verticalFromTop: vertical
        )
    }

    static func resizedFrame(
        from currentFrame: CGRect,
        height: CGFloat,
        visibleFrame: CGRect
    ) -> CGRect {
        frame(
            topLeft: CGPoint(x: currentFrame.minX, y: currentFrame.maxY),
            size: CGSize(width: ClipboardHUDMetrics.width, height: height),
            visibleFrame: visibleFrame
        )
    }

    static func requiresFrameUpdate(
        current: CGRect,
        target: CGRect,
        tolerance: CGFloat = 0.5
    ) -> Bool {
        abs(current.minX - target.minX) > tolerance
            || abs(current.minY - target.minY) > tolerance
            || abs(current.width - target.width) > tolerance
            || abs(current.height - target.height) > tolerance
    }

    static func frame(
        topLeft: CGPoint,
        size: CGSize,
        visibleFrame: CGRect
    ) -> CGRect {
        let width = min(max(0, size.width), visibleFrame.width)
        let height = min(max(0, size.height), visibleFrame.height)
        let minimumX = visibleFrame.minX
        let maximumX = visibleFrame.maxX - width
        let minimumTop = visibleFrame.minY + height
        let maximumTop = visibleFrame.maxY
        let x = topLeft.x.clamped(to: minimumX...maximumX)
        let top = topLeft.y.clamped(to: minimumTop...maximumTop)
        return CGRect(x: x, y: top - height, width: width, height: height)
    }
}

final class ClipboardHUDPositionStore {
    private let defaults: UserDefaults
    private let key: String

    init(
        defaults: UserDefaults = .standard,
        key: String = CtrlSayPreferenceKey.hudPositionsByDisplay
    ) {
        self.defaults = defaults
        self.key = key
    }

    func position(for displayIdentifier: String) -> ClipboardHUDNormalizedPosition? {
        positions()[displayIdentifier]
    }

    func save(
        _ position: ClipboardHUDNormalizedPosition,
        for displayIdentifier: String
    ) {
        var values = positions()
        values[displayIdentifier] = position
        guard let data = try? JSONEncoder().encode(values) else { return }
        defaults.set(data, forKey: key)
    }

    private func positions() -> [String: ClipboardHUDNormalizedPosition] {
        guard let data = defaults.data(forKey: key),
            let values = try? JSONDecoder().decode(
                [String: ClipboardHUDNormalizedPosition].self,
                from: data
            )
        else {
            return [:]
        }
        return values
    }
}

extension Comparable {
    fileprivate func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
