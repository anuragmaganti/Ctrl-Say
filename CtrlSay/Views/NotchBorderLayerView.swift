import AppKit
import QuartzCore
import SwiftUI

/// A compositor-driven border for the notch panel. SwiftUI owns state and
/// layout; Core Animation owns the continuous color cycle so Listening mode
/// does not wake and redraw the SwiftUI hierarchy every frame.
struct NotchBorderLayerView: NSViewRepresentable {
    let visualState: NotchVisualState
    let interactionMode: NotchInteractionMode
    let surfaceStyle: NotchSurfaceStyle
    let reduceMotion: Bool
    let increasedContrast: Bool

    func makeNSView(context: Context) -> NotchBorderHostView {
        NotchBorderHostView()
    }

    func updateNSView(_ view: NotchBorderHostView, context: Context) {
        view.update(
            configuration: NotchBorderConfiguration(
                visualState: visualState,
                interactionMode: interactionMode,
                surfaceStyle: surfaceStyle,
                reduceMotion: reduceMotion,
                increasedContrast: increasedContrast
            )
        )
    }
}

private struct NotchBorderConfiguration: Equatable {
    let visualState: NotchVisualState
    let interactionMode: NotchInteractionMode
    let surfaceStyle: NotchSurfaceStyle
    let reduceMotion: Bool
    let increasedContrast: Bool
}

final class NotchBorderHostView: NSView {
    private static let colorCycleKey = "ctrlsay.listening-color-cycle"
    private static let colorCycleDuration: CFTimeInterval = 12

    private let glowContainer = CALayer()
    private let glowGradient = CAGradientLayer()
    private let glowMask = CAShapeLayer()
    private let coreContainer = CALayer()
    private let coreGradient = CAGradientLayer()
    private let coreMask = CAShapeLayer()

    private var configuration: NotchBorderConfiguration?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.isGeometryFlipped = true
        configureBand(
            container: glowContainer,
            gradient: glowGradient,
            mask: glowMask
        )
        configureBand(
            container: coreContainer,
            gradient: coreGradient,
            mask: coreMask
        )
        layer?.addSublayer(glowContainer)
        layer?.addSublayer(coreContainer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        updateLayerGeometry()
    }

    fileprivate func update(configuration: NotchBorderConfiguration) {
        guard self.configuration != configuration else { return }
        self.configuration = configuration
        updateLayerAppearance()
        needsLayout = true
    }

    private func configureBand(
        container: CALayer,
        gradient: CAGradientLayer,
        mask: CAShapeLayer
    ) {
        container.masksToBounds = false
        container.isGeometryFlipped = true
        mask.fillColor = NSColor.clear.cgColor
        mask.strokeColor = NSColor.white.cgColor
        mask.lineCap = .round
        mask.lineJoin = .round
        mask.isGeometryFlipped = true
        container.mask = mask
        container.addSublayer(gradient)
    }

    private func updateLayerGeometry() {
        guard let configuration, !bounds.isEmpty else { return }
        let path = borderPath(
            in: bounds,
            configuration: configuration
        )
        let gradientSide = max(1, hypot(bounds.width, bounds.height) * 1.1)
        let gradientFrame = CGRect(
            x: bounds.midX - gradientSide / 2,
            y: bounds.midY - gradientSide / 2,
            width: gradientSide,
            height: gradientSide
        )

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for container in [glowContainer, coreContainer] {
            container.frame = bounds
        }
        for mask in [glowMask, coreMask] {
            mask.frame = bounds
            mask.path = path
        }
        for gradient in [glowGradient, coreGradient] {
            gradient.frame = gradientFrame
        }
        CATransaction.commit()
    }

    private func updateLayerAppearance() {
        guard let configuration else { return }
        let colors: [CGColor]
        let gradientType: CAGradientLayerType
        let startPoint: CGPoint
        let endPoint: CGPoint

        switch configuration.visualState {
        case .hidden, .preparing, .listening:
            colors = [
                NSColor.systemBlue.cgColor,
                NSColor.systemIndigo.cgColor,
                NSColor.systemPurple.cgColor,
                NSColor.systemPink.cgColor,
                NSColor.systemRed.cgColor,
                NSColor.systemOrange.cgColor,
                NSColor.systemPurple.cgColor,
                NSColor.systemBlue.cgColor,
            ]
            gradientType = .conic
            startPoint = CGPoint(x: 0.5, y: 0.5)
            endPoint = CGPoint(x: 0.5, y: 0)

        case .success(let action, _):
            colors =
                action == .copy
                ? [
                    NSColor.systemBlue.cgColor,
                    NSColor.systemCyan.cgColor,
                    NSColor.systemPurple.cgColor,
                ]
                : [
                    NSColor.systemPurple.cgColor,
                    NSColor.systemPink.cgColor,
                    NSColor.systemOrange.cgColor,
                ]
            gradientType = .axial
            startPoint = CGPoint(x: 0, y: 0.5)
            endPoint = CGPoint(x: 1, y: 0.5)

        case .failure:
            colors = [
                NSColor.systemOrange.cgColor,
                NSColor.systemRed.cgColor,
                NSColor.systemPink.cgColor,
            ]
            gradientType = .axial
            startPoint = CGPoint(x: 0, y: 1)
            endPoint = CGPoint(x: 1, y: 0)
        }

        let glowOpacity = Float(configuration.visualState.glowOpacity)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glowMask.lineWidth = configuration.increasedContrast ? 6 : 5
        coreMask.lineWidth = configuration.increasedContrast ? 1.8 : 1.4
        glowContainer.opacity = glowOpacity * 0.34
        coreContainer.opacity = configuration.visualState == .hidden ? 0 : 0.95
        for gradient in [glowGradient, coreGradient] {
            gradient.colors = colors
            gradient.type = gradientType
            gradient.startPoint = startPoint
            gradient.endPoint = endPoint
        }
        CATransaction.commit()

        let shouldCycle =
            configuration.visualState.isListeningIndicator
            && !configuration.reduceMotion
        setColorCycleActive(shouldCycle)
    }

    private func setColorCycleActive(_ active: Bool) {
        for gradient in [glowGradient, coreGradient] {
            if active {
                guard gradient.animation(forKey: Self.colorCycleKey) == nil else {
                    continue
                }
                let animation = CABasicAnimation(keyPath: "transform.rotation.z")
                animation.fromValue = 0
                animation.toValue = Double.pi * 2
                animation.duration = Self.colorCycleDuration
                animation.repeatCount = .infinity
                animation.timingFunction = CAMediaTimingFunction(name: .linear)
                animation.isRemovedOnCompletion = false
                gradient.add(animation, forKey: Self.colorCycleKey)
            } else {
                gradient.removeAnimation(forKey: Self.colorCycleKey)
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                gradient.transform = CATransform3DIdentity
                CATransaction.commit()
            }
        }
    }

    private func borderPath(
        in rect: CGRect,
        configuration: NotchBorderConfiguration
    ) -> CGPath {
        switch configuration.surfaceStyle {
        case .attached(_, let notchHeight):
            let surfaceHeight =
                configuration.interactionMode == .passive
                ? notchHeight
                : rect.height
            return AttachedNotchGeometry.borderPath(
                in: rect,
                horizontalCanvasOutset: NotchPanelLayoutCalculator
                    .attachedHorizontalCanvasOutset,
                visibleBorderOutset: NotchPanelLayoutCalculator
                    .attachedVisibleBorderOutset,
                surfaceHeight: surfaceHeight,
                bottomCornerRadius:
                    NotchPanelLayoutCalculator
                    .attachedBottomCornerRadius(notchHeight: notchHeight)
            )

        case .floating:
            let inset = (configuration.increasedContrast ? 6.0 : 5.0) / 2
            let borderRect = rect.insetBy(dx: inset, dy: inset)
            let radius = max(0, min(20, borderRect.height / 2))
            return CGPath(
                roundedRect: borderRect,
                cornerWidth: radius,
                cornerHeight: radius,
                transform: nil
            )
        }
    }
}

extension NotchVisualState {
    fileprivate var isListeningIndicator: Bool {
        switch self {
        case .preparing, .listening:
            true
        case .hidden, .success, .failure:
            false
        }
    }

    fileprivate var glowOpacity: Double {
        switch self {
        case .hidden:
            0
        case .preparing:
            0.72
        case .listening:
            1
        case .success:
            0.82
        case .failure:
            0.9
        }
    }
}
