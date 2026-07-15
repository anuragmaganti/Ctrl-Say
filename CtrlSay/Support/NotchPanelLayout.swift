import CoreGraphics
import Foundation

enum NotchSurfaceStyle: Equatable, Sendable {
    case attached(notchWidth: CGFloat, notchHeight: CGFloat)
    case floating
}

struct NotchDisplayGeometry: Equatable, Sendable {
    let frame: CGRect
    let visibleFrame: CGRect
    let safeAreaTop: CGFloat
    let auxiliaryTopLeftArea: CGRect?
    let auxiliaryTopRightArea: CGRect?
}

struct NotchPanelLayout: Equatable, Sendable {
    let frame: CGRect
    let surfaceStyle: NotchSurfaceStyle
}

enum NotchPanelLayoutCalculator {
    static let floatingTopInset: CGFloat = 8
    static let horizontalScreenInset: CGFloat = 12
    static let floatingListeningWidth: CGFloat = 152
    // NSScreen reports the rectangular hardware exclusion. A border drawn on
    // that rectangle is physically hidden by the camera housing. These canvas
    // margins keep the outward half of a boundary-aligned stroke and its glow
    // inside the panel while the black surface remains on the hardware bounds.
    static let attachedHorizontalCanvasOutset: CGFloat = 6
    static let attachedBottomCanvasOutset: CGFloat = 6
    static let attachedVisibleBorderOutset: CGFloat = 1
    // NSScreen exposes the hardware exclusion rectangle, but no public corner-
    // radius property. Keep the product-drawn lower corners proportional and
    // bounded; this is visual geometry, not a claim about hidden hardware data.
    static let attachedCornerRadiusRatio: CGFloat = 0.32
    static let maximumAttachedCornerRadius: CGFloat = 12

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

    static func attachedBottomCornerRadius(
        notchHeight: CGFloat
    ) -> CGFloat {
        min(
            maximumAttachedCornerRadius,
            max(0, notchHeight) * attachedCornerRadiusRatio
        )
    }

    static func layout(
        visualState: NotchVisualState,
        interactionMode: NotchInteractionMode,
        display: NotchDisplayGeometry
    ) -> NotchPanelLayout {
        let style = surfaceStyle(for: display)
        let requestedSize = panelSize(
            visualState: visualState,
            interactionMode: interactionMode,
            surfaceStyle: style
        )
        let maximumWidth = max(
            1,
            display.frame.width - horizontalScreenInset * 2
        )
        let maximumHeight: CGFloat
        let top: CGFloat

        switch style {
        case .attached:
            maximumHeight = max(
                1,
                display.frame.maxY - display.visibleFrame.minY
                    - floatingTopInset
            )
            top = display.frame.maxY
        case .floating:
            maximumHeight = max(
                1,
                display.visibleFrame.height - floatingTopInset * 2
            )
            top = display.visibleFrame.maxY - floatingTopInset
        }

        let size = CGSize(
            width: min(requestedSize.width, maximumWidth),
            height: min(requestedSize.height, maximumHeight)
        )
        let proposedX: CGFloat
        switch (style, interactionMode) {
        case (.attached(let notchWidth, _), .passive):
            // The transparent canvas starts outside the physical exclusion;
            // command feedback still grows only toward the right.
            proposedX = display.frame.midX
                - notchWidth / 2
                - attachedHorizontalCanvasOutset
        case (.floating, .passive):
            // The notchless capsule follows the same left-anchored expansion.
            proposedX = display.frame.midX - floatingListeningWidth / 2
        default:
            // Future interactive surfaces remain centered as they expand.
            proposedX = display.frame.midX - size.width / 2
        }
        let minimumX = display.frame.minX + horizontalScreenInset
        let maximumX = display.frame.maxX
            - horizontalScreenInset
            - size.width
        let x = proposedX.clamped(to: minimumX...max(minimumX, maximumX))
        let frame = CGRect(
            x: x,
            y: top - size.height,
            width: size.width,
            height: size.height
        )
        return NotchPanelLayout(frame: frame, surfaceStyle: style)
    }

    static func surfaceStyle(
        for display: NotchDisplayGeometry
    ) -> NotchSurfaceStyle {
        guard display.safeAreaTop > 0,
              let left = display.auxiliaryTopLeftArea,
              let right = display.auxiliaryTopRightArea else {
            return .floating
        }

        let notchLeft = max(display.frame.minX, left.maxX)
        let notchRight = min(display.frame.maxX, right.minX)
        let notchWidth = notchRight - notchLeft
        guard notchWidth > 0,
              notchWidth < display.frame.width,
              display.safeAreaTop < display.frame.height else {
            return .floating
        }

        return .attached(
            notchWidth: notchWidth,
            notchHeight: display.safeAreaTop
        )
    }

    private static func panelSize(
        visualState: NotchVisualState,
        interactionMode: NotchInteractionMode,
        surfaceStyle: NotchSurfaceStyle
    ) -> CGSize {
        let feedbackSize = feedbackPanelSize(
            visualState: visualState,
            surfaceStyle: surfaceStyle
        )

        switch interactionMode {
        case .passive:
            return feedbackSize
        case .compactInteractive:
            return interactiveSize(
                width: 340,
                contentHeight: 160,
                feedbackSize: feedbackSize,
                surfaceStyle: surfaceStyle
            )
        case .expandedInteractive:
            return interactiveSize(
                width: 420,
                contentHeight: 320,
                feedbackSize: feedbackSize,
                surfaceStyle: surfaceStyle
            )
        }
    }

    private static func feedbackPanelSize(
        visualState: NotchVisualState,
        surfaceStyle: NotchSurfaceStyle
    ) -> CGSize {
        switch surfaceStyle {
        case .attached(let notchWidth, let notchHeight):
            let baseSize = CGSize(
                width: notchWidth + attachedHorizontalCanvasOutset * 2,
                height: notchHeight + attachedBottomCanvasOutset
            )
            switch visualState {
            case .hidden, .preparing, .listening:
                return baseSize
            case .success(_, let label):
                return CGSize(
                    width: baseSize.width
                        + successExtensionWidth(for: label),
                    height: baseSize.height
                )
            case .failure(let message):
                return CGSize(
                    width: baseSize.width
                        + failureExtensionWidth(for: message),
                    height: baseSize.height
                )
            }

        case .floating:
            switch visualState {
            case .hidden:
                return CGSize(width: floatingListeningWidth, height: 36)
            case .preparing, .listening:
                return CGSize(width: floatingListeningWidth, height: 38)
            case .success(_, let label):
                return CGSize(
                    width: floatingListeningWidth
                        + successExtensionWidth(for: label),
                    height: 38
                )
            case .failure(let message):
                return CGSize(
                    width: floatingListeningWidth
                        + failureExtensionWidth(for: message),
                    height: 38
                )
            }
        }
    }

    private static func successExtensionWidth(for label: String) -> CGFloat {
        let estimatedLabelWidth = CGFloat(label.count) * 7.2
        return (24 + 16 + 9 + estimatedLabelWidth)
            .clamped(to: 72...260)
    }

    private static func failureExtensionWidth(for message: String) -> CGFloat {
        let estimatedMessageWidth = CGFloat(message.count) * 7
        return (24 + 15 + 9 + estimatedMessageWidth)
            .clamped(to: 120...300)
    }

    private static func interactiveSize(
        width: CGFloat,
        contentHeight: CGFloat,
        feedbackSize: CGSize,
        surfaceStyle: NotchSurfaceStyle
    ) -> CGSize {
        let height: CGFloat
        switch surfaceStyle {
        case .attached(_, let notchHeight):
            height = notchHeight
                + attachedBottomCanvasOutset
                + contentHeight
        case .floating:
            height = contentHeight
        }
        return CGSize(
            width: max(width, feedbackSize.width),
            height: max(height, feedbackSize.height)
        )
    }
}

/// One geometry source for both the SwiftUI black surface and its
/// compositor-driven Core Animation border. Keeping the shared edges here
/// prevents the two renderers from drifting apart.
enum AttachedNotchGeometry {
    nonisolated static func surfacePath(
        in rect: CGRect,
        horizontalCanvasOutset: CGFloat,
        surfaceHeight: CGFloat,
        bottomCornerRadius: CGFloat
    ) -> CGPath {
        let surfaceRect = CGRect(
            x: rect.minX + horizontalCanvasOutset,
            y: rect.minY,
            width: max(0, rect.width - horizontalCanvasOutset * 2),
            height: min(max(0, surfaceHeight), rect.height)
        )
        return openTopPath(
            left: surfaceRect.minX,
            right: surfaceRect.maxX,
            top: surfaceRect.minY,
            bottom: surfaceRect.maxY,
            bottomCornerRadius: bottomCornerRadius,
            closesPath: true
        )
    }

    nonisolated static func borderPath(
        in rect: CGRect,
        horizontalCanvasOutset: CGFloat,
        visibleBorderOutset: CGFloat,
        surfaceHeight: CGFloat,
        bottomCornerRadius: CGFloat
    ) -> CGPath {
        let left = rect.minX + horizontalCanvasOutset - visibleBorderOutset
        let right = rect.maxX - horizontalCanvasOutset + visibleBorderOutset
        let bottom = min(
            rect.maxY,
            rect.minY + max(0, surfaceHeight) + visibleBorderOutset
        )
        return openTopPath(
            left: left,
            right: right,
            top: rect.minY,
            bottom: bottom,
            bottomCornerRadius: bottomCornerRadius + visibleBorderOutset,
            closesPath: false
        )
    }

    nonisolated private static func openTopPath(
        left: CGFloat,
        right: CGFloat,
        top: CGFloat,
        bottom: CGFloat,
        bottomCornerRadius: CGFloat,
        closesPath: Bool
    ) -> CGPath {
        let radius = min(
            max(0, bottomCornerRadius),
            max(0, (right - left) / 2),
            max(0, bottom - top)
        )
        let curveControl = radius * 0.552_284_75
        let path = CGMutablePath()
        path.move(to: CGPoint(x: left, y: top))
        path.addLine(to: CGPoint(x: left, y: bottom - radius))
        path.addCurve(
            to: CGPoint(x: left + radius, y: bottom),
            control1: CGPoint(
                x: left,
                y: bottom - radius + curveControl
            ),
            control2: CGPoint(
                x: left + radius - curveControl,
                y: bottom
            )
        )
        path.addLine(to: CGPoint(x: right - radius, y: bottom))
        path.addCurve(
            to: CGPoint(x: right, y: bottom - radius),
            control1: CGPoint(
                x: right - radius + curveControl,
                y: bottom
            ),
            control2: CGPoint(
                x: right,
                y: bottom - radius + curveControl
            )
        )
        path.addLine(to: CGPoint(x: right, y: top))
        if closesPath {
            path.closeSubpath()
        }
        return path
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
