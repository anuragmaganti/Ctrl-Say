import CoreGraphics
import Foundation

struct NotchSurfaceGeometry: Equatable, Sendable {
    let notchWidth: CGFloat
    let notchHeight: CGFloat
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
    let surfaceSize: CGSize
    let surfaceGeometry: NotchSurfaceGeometry
}

enum NotchDisplayEligibility {
    static func allowsPresentation(
        isPrimary: Bool,
        isBuiltIn: Bool,
        isMirrored: Bool
    ) -> Bool {
        isPrimary && isBuiltIn && !isMirrored
    }
}

enum NotchPanelLayoutCalculator {
    static let verticalScreenInset: CGFloat = 8
    static let horizontalScreenInset: CGFloat = 12
    private static let maximumPassiveExtensionWidth: CGFloat = 300
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
    ) -> NotchPanelLayout? {
        guard let surfaceGeometry = surfaceGeometry(for: display) else {
            return nil
        }
        let requestedSurfaceSize = surfaceSize(
            visualState: visualState,
            interactionMode: interactionMode,
            surfaceGeometry: surfaceGeometry
        )
        let requestedCanvasSize = canvasSize(
            interactionMode: interactionMode,
            surfaceGeometry: surfaceGeometry
        )
        let maximumWidth = max(
            1,
            display.frame.width - horizontalScreenInset * 2
        )
        let maximumHeight = max(
            1,
            display.frame.maxY - display.visibleFrame.minY
                - verticalScreenInset
        )

        let size = CGSize(
            width: min(requestedCanvasSize.width, maximumWidth),
            height: min(requestedCanvasSize.height, maximumHeight)
        )
        let clampedSurfaceSize = CGSize(
            width: min(requestedSurfaceSize.width, size.width),
            height: min(requestedSurfaceSize.height, size.height)
        )
        let proposedX: CGFloat
        switch interactionMode {
        case .passive:
            // Keep the canvas anchored to the hardware exclusion's left edge.
            // Only the black SwiftUI surface changes width, so command
            // feedback grows toward the right without resizing the window.
            proposedX = display.frame.midX - surfaceGeometry.notchWidth / 2
        case .compactInteractive, .expandedInteractive:
            // Future interactive surfaces remain centered as they expand.
            proposedX = display.frame.midX - size.width / 2
        }
        let minimumX = display.frame.minX + horizontalScreenInset
        let maximumX =
            display.frame.maxX
            - horizontalScreenInset
            - size.width
        let x = proposedX.clamped(to: minimumX...max(minimumX, maximumX))
        let frame = CGRect(
            x: x,
            y: display.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
        return NotchPanelLayout(
            frame: frame,
            surfaceSize: clampedSurfaceSize,
            surfaceGeometry: surfaceGeometry
        )
    }

    static func surfaceGeometry(
        for display: NotchDisplayGeometry
    ) -> NotchSurfaceGeometry? {
        guard display.safeAreaTop > 0,
            let left = display.auxiliaryTopLeftArea,
            let right = display.auxiliaryTopRightArea
        else {
            return nil
        }

        let notchLeft = max(display.frame.minX, left.maxX)
        let notchRight = min(display.frame.maxX, right.minX)
        let notchWidth = notchRight - notchLeft
        guard notchWidth > 0,
            notchWidth < display.frame.width,
            display.safeAreaTop < display.frame.height
        else {
            return nil
        }

        return NotchSurfaceGeometry(
            notchWidth: notchWidth,
            notchHeight: display.safeAreaTop
        )
    }

    static func surfaceSize(
        visualState: NotchVisualState,
        interactionMode: NotchInteractionMode,
        surfaceGeometry: NotchSurfaceGeometry
    ) -> CGSize {
        switch interactionMode {
        case .passive:
            return passiveSurfaceSize(
                visualState: visualState,
                surfaceGeometry: surfaceGeometry
            )
        case .compactInteractive, .expandedInteractive:
            return interactiveSurfaceSize(
                interactionMode: interactionMode,
                surfaceGeometry: surfaceGeometry
            )
        }
    }

    private static func canvasSize(
        interactionMode: NotchInteractionMode,
        surfaceGeometry: NotchSurfaceGeometry
    ) -> CGSize {
        let passiveMaximum = maximumPassiveSurfaceSize(
            surfaceGeometry: surfaceGeometry
        )
        switch interactionMode {
        case .passive:
            return passiveMaximum
        case .compactInteractive, .expandedInteractive:
            return interactiveSurfaceSize(
                interactionMode: interactionMode,
                surfaceGeometry: surfaceGeometry
            )
        }
    }

    private static func interactiveSurfaceSize(
        interactionMode: NotchInteractionMode,
        surfaceGeometry: NotchSurfaceGeometry
    ) -> CGSize {
        let requested: CGSize
        switch interactionMode {
        case .passive:
            return maximumPassiveSurfaceSize(surfaceGeometry: surfaceGeometry)
        case .compactInteractive:
            requested = interactiveSize(
                width: 340,
                contentHeight: 160,
                surfaceGeometry: surfaceGeometry
            )
        case .expandedInteractive:
            requested = interactiveSize(
                width: 420,
                contentHeight: 320,
                surfaceGeometry: surfaceGeometry
            )
        }
        let passiveMaximum = maximumPassiveSurfaceSize(
            surfaceGeometry: surfaceGeometry
        )
        return CGSize(
            width: max(passiveMaximum.width, requested.width),
            height: max(passiveMaximum.height, requested.height)
        )
    }

    private static func passiveSurfaceSize(
        visualState: NotchVisualState,
        surfaceGeometry: NotchSurfaceGeometry
    ) -> CGSize {
        let baseSize = CGSize(
            width: surfaceGeometry.notchWidth,
            height: surfaceGeometry.notchHeight
        )
        switch visualState {
        case .hidden, .preparing, .listening:
            return baseSize
        case .pending(_, let label), .success(_, let label):
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
    }

    private static func maximumPassiveSurfaceSize(
        surfaceGeometry: NotchSurfaceGeometry
    ) -> CGSize {
        let baseSize = CGSize(
            width: surfaceGeometry.notchWidth,
            height: surfaceGeometry.notchHeight
        )
        return CGSize(
            width: baseSize.width + maximumPassiveExtensionWidth,
            height: baseSize.height
        )
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
        surfaceGeometry: NotchSurfaceGeometry
    ) -> CGSize {
        CGSize(
            width: width,
            height: surfaceGeometry.notchHeight + contentHeight
        )
    }
}

/// Geometry for the pure-black surface that visually extends the hardware
/// notch. The top edge is closed only for filling; it remains hidden beneath
/// the top of the display.
enum AttachedNotchGeometry {
    nonisolated static func surfacePath(
        in rect: CGRect,
        surfaceHeight: CGFloat,
        bottomCornerRadius: CGFloat
    ) -> CGPath {
        let surfaceRect = CGRect(
            x: rect.minX,
            y: rect.minY,
            width: max(0, rect.width),
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

extension Comparable {
    fileprivate func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
