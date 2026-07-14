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
    // margins let the visible stroke sit just outside the reported exclusion
    // while the black surface itself remains aligned to the hardware bounds.
    static let attachedHorizontalCanvasOutset: CGFloat = 6
    static let attachedBottomCanvasOutset: CGFloat = 6
    static let attachedVisibleBorderOutset: CGFloat = 2

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

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
