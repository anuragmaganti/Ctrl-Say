import CoreGraphics
import Foundation

enum DashboardPanelMetrics {
    static let width: CGFloat = 388
    static let compactHeight: CGFloat = 64
    static let setupRecoveryAdditionalHeight: CGFloat = 156
#if DEBUG
    static let diagnosticsCollapsedHeight: CGFloat = 112
    static let diagnosticsExpandedHeight: CGFloat = 350
#endif
    static let cornerRadius: CGFloat = 22
    static let screenInset: CGFloat = 8
    static let anchorGap: CGFloat = 6

    static var preferredSize: CGSize {
        preferredSize(showsDeveloperDiagnostics: false)
    }

    static func preferredSize(
        showsDeveloperDiagnostics: Bool,
        showsSetupRecovery: Bool = false
    ) -> CGSize {
#if DEBUG
        let baseHeight = showsDeveloperDiagnostics
            ? diagnosticsExpandedHeight
            : diagnosticsCollapsedHeight
#else
        let baseHeight = compactHeight
#endif
        let height = baseHeight
            + (showsSetupRecovery ? setupRecoveryAdditionalHeight : 0)
        return CGSize(width: width, height: height)
    }
}

/// Pure geometry for a menu-bar panel that must remain below its status item.
///
/// AppKit popovers are allowed to flip to another edge. Ctrl-Say intentionally
/// keeps its nonactivating panel, so this calculation makes the placement rule
/// explicit and testable across displays with different coordinate origins.
enum DashboardPanelPlacement {
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
        below anchor: CGRect,
        preferredSize: CGSize,
        visibleFrame: CGRect,
        screenInset: CGFloat = DashboardPanelMetrics.screenInset,
        anchorGap: CGFloat = DashboardPanelMetrics.anchorGap
    ) -> CGRect? {
        guard isFinite(anchor),
              isFinite(visibleFrame),
              preferredSize.width.isFinite,
              preferredSize.height.isFinite,
              preferredSize.width > 0,
              preferredSize.height > 0,
              screenInset.isFinite,
              screenInset >= 0,
              anchorGap.isFinite,
              anchorGap >= 0 else {
            return nil
        }

        let usableFrame = visibleFrame.insetBy(dx: screenInset, dy: screenInset)
        guard usableFrame.width > 0, usableFrame.height > 0 else { return nil }

        let width = min(preferredSize.width, usableFrame.width)
        let top = min(anchor.minY - anchorGap, usableFrame.maxY)
        let availableHeight = top - usableFrame.minY
        guard availableHeight > 0 else { return nil }

        let height = min(preferredSize.height, availableHeight)
        let centeredX = anchor.midX - width / 2
        let originX = min(
            max(centeredX, usableFrame.minX),
            usableFrame.maxX - width
        )

        return CGRect(
            x: originX,
            y: top - height,
            width: width,
            height: height
        )
    }

    static func bestScreenIndex(
        for anchor: CGRect,
        screenFrames: [CGRect]
    ) -> Int? {
        guard isFinite(anchor), !screenFrames.isEmpty else { return nil }

        let validFrames = screenFrames.enumerated().filter { isFinite($0.element) }
        guard !validFrames.isEmpty else { return nil }

        let intersecting = validFrames.map { entry in
            let intersection = entry.element.intersection(anchor)
            let area = intersection.isNull
                ? 0
                : max(0, intersection.width) * max(0, intersection.height)
            return (index: entry.offset, area: area)
        }
        if let bestIntersection = intersecting.max(by: { $0.area < $1.area }),
           bestIntersection.area > 0 {
            return bestIntersection.index
        }

        let anchorPoint = CGPoint(x: anchor.midX, y: anchor.midY)
        return validFrames.min { lhs, rhs in
            squaredDistance(from: anchorPoint, to: lhs.element)
                < squaredDistance(from: anchorPoint, to: rhs.element)
        }?.offset
    }

    private static func squaredDistance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let nearestX = min(max(point.x, rect.minX), rect.maxX)
        let nearestY = min(max(point.y, rect.minY), rect.maxY)
        let deltaX = point.x - nearestX
        let deltaY = point.y - nearestY
        return deltaX * deltaX + deltaY * deltaY
    }

    private static func isFinite(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite
            && rect.origin.y.isFinite
            && rect.size.width.isFinite
            && rect.size.height.isFinite
            && rect.size.width >= 0
            && rect.size.height >= 0
    }
}
