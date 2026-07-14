import SwiftUI

struct NotchFeedbackView: View {
    let presentationState: NotchFeedbackPresentationState
    let windowContext: NotchWindowContext

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        GeometryReader { proxy in
            if presentationState.visualState.isVisible {
                let surface = surfaceShape(in: proxy.size)
                let border = borderShape(in: proxy.size)
                ZStack {
                    surface
                        .fill(Color.black)

                    cyclingBorder(border)

                    positionedFeedbackContent
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .transition(.opacity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityLabel)
            }
        }
        .animation(
            reduceMotion ? nil : .snappy(duration: 0.24, extraBounce: 0.08),
            value: presentationState.visualState
        )
        .accessibilityIdentifier("ctrlSay.notchFeedback")
    }

    private var feedbackContent: some View {
        Group {
            switch presentationState.visualState {
            case .hidden, .preparing, .listening:
                EmptyView()

            case .success(let action, let label):
                HStack(spacing: 9) {
                    Image(systemName: action == .copy ? "doc.on.doc" : "arrow.down.doc")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(action == .copy ? .cyan : .purple)
                    Text(label)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }

            case .failure(let message):
                HStack(spacing: 9) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.orange)
                    Text(message)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
        }
    }

    @ViewBuilder
    private var positionedFeedbackContent: some View {
        switch windowContext.surfaceStyle {
        case .attached(let notchWidth, let notchHeight):
            feedbackContent
                .padding(
                    .leading,
                    NotchPanelLayoutCalculator
                        .attachedHorizontalCanvasOutset
                        + notchWidth
                        + 12
                )
                .padding(
                    .trailing,
                    NotchPanelLayoutCalculator
                        .attachedHorizontalCanvasOutset
                        + 12
                )
                .frame(height: notchHeight, alignment: .leading)
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .topLeading
                )
        case .floating:
            feedbackContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 14)
        }
    }

    private func cyclingBorder(_ border: AnyShape) -> some View {
        TimelineView(
            .animation(
                minimumInterval: 1.0 / 30.0,
                paused: !shouldCycleListeningColors || reduceMotion
            )
        ) { context in
            let rotation = listeningColorRotation(at: context.date)
            let style = edgeStyle(rotation: rotation)

            ZStack {
                border
                    .stroke(
                        style,
                        style: StrokeStyle(
                            lineWidth: contrast == .increased ? 2.8 : 2.2,
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
                    .blur(radius: contrast == .increased ? 2 : 4)
                    .opacity(glowOpacity)

                border
                    .stroke(
                        style,
                        style: StrokeStyle(
                            lineWidth: contrast == .increased ? 1.8 : 1.4,
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
                    .opacity(0.95)
            }
        }
    }

    private var shouldCycleListeningColors: Bool {
        switch presentationState.visualState {
        case .preparing, .listening:
            true
        case .hidden, .success, .failure:
            false
        }
    }

    private func listeningColorRotation(at date: Date) -> Angle {
        guard shouldCycleListeningColors, !reduceMotion else { return .zero }
        let cycleDuration = 12.0
        let progress = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: cycleDuration)
            / cycleDuration
        return .degrees(progress * 360)
    }

    private func edgeStyle(rotation: Angle) -> AnyShapeStyle {
        switch presentationState.visualState {
        case .failure:
            return AnyShapeStyle(
                LinearGradient(
                    colors: [.orange, .red, .pink],
                    startPoint: .bottomLeading,
                    endPoint: .topTrailing
                )
            )
        case .success(let action, _):
            return AnyShapeStyle(
                LinearGradient(
                    colors: action == .copy
                        ? [.blue, .cyan, .purple]
                        : [.purple, .pink, .orange],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
        case .hidden, .preparing, .listening:
            return AnyShapeStyle(
                listeningEdgeGradient(rotation: rotation)
            )
        }
    }

    private func listeningEdgeGradient(rotation: Angle) -> AngularGradient {
        AngularGradient(
            colors: [
                .blue,
                .indigo,
                .purple,
                .pink,
                .red,
                .orange,
                .purple,
                .blue,
            ],
            center: .center,
            startAngle: .degrees(-90 + rotation.degrees),
            endAngle: .degrees(270 + rotation.degrees)
        )
    }

    private var glowOpacity: Double {
        switch presentationState.visualState {
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

    private func surfaceShape(in size: CGSize) -> AnyShape {
        switch windowContext.surfaceStyle {
        case .attached(_, let notchHeight):
            let surfaceHeight = presentationState.interactionMode == .passive
                ? notchHeight
                : size.height
            return AnyShape(
                AttachedNotchSurfaceShape(
                    horizontalCanvasOutset: NotchPanelLayoutCalculator
                        .attachedHorizontalCanvasOutset,
                    surfaceHeight: surfaceHeight,
                    bottomCornerRadius: NotchPanelLayoutCalculator
                        .attachedBottomCornerRadius(notchHeight: notchHeight)
                )
            )
        case .floating:
            return AnyShape(
                RoundedRectangle(
                    cornerRadius: min(20, size.height / 2),
                    style: .continuous
                )
            )
        }
    }

    private func borderShape(in size: CGSize) -> AnyShape {
        switch windowContext.surfaceStyle {
        case .attached(_, let notchHeight):
            let surfaceHeight = presentationState.interactionMode == .passive
                ? notchHeight
                : size.height
            // This is intentionally an open path. The physical display edge is
            // the notch's top edge, so drawing there creates a false rainbow
            // seam across the top of the screen.
            return AnyShape(
                AttachedNotchBorderShape(
                    horizontalCanvasOutset: NotchPanelLayoutCalculator
                        .attachedHorizontalCanvasOutset,
                    visibleBorderOutset: NotchPanelLayoutCalculator
                        .attachedVisibleBorderOutset,
                    surfaceHeight: surfaceHeight,
                    bottomCornerRadius: NotchPanelLayoutCalculator
                        .attachedBottomCornerRadius(notchHeight: notchHeight)
                )
            )
        case .floating:
            return AnyShape(
                RoundedRectangle(
                    cornerRadius: min(20, size.height / 2),
                    style: .continuous
                )
            )
        }
    }

    private var accessibilityLabel: String {
        switch presentationState.visualState {
        case .hidden:
            "Ctrl-Say status hidden"
        case .preparing:
            "Ctrl-Say is preparing to listen"
        case .listening:
            "Ctrl-Say is listening"
        case .success(let action, let label):
            action == .copy ? "Copied to \(label)" : "Pasted \(label)"
        case .failure(let message):
            "Ctrl-Say command failed. \(message)"
        }
    }
}

private struct AttachedNotchSurfaceShape: Shape {
    let horizontalCanvasOutset: CGFloat
    let surfaceHeight: CGFloat
    let bottomCornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let surfaceRect = CGRect(
            x: rect.minX + horizontalCanvasOutset,
            y: rect.minY,
            width: max(0, rect.width - horizontalCanvasOutset * 2),
            height: min(surfaceHeight, rect.height)
        )
        let radius = min(
            bottomCornerRadius,
            max(0, surfaceRect.width / 2),
            max(0, surfaceRect.height)
        )
        var path = Path()
        path.move(to: CGPoint(x: surfaceRect.minX, y: surfaceRect.minY))
        path.addLine(
            to: CGPoint(
                x: surfaceRect.minX,
                y: surfaceRect.maxY - radius
            )
        )
        let curveControl = radius * 0.552_284_75
        path.addCurve(
            to: CGPoint(
                x: surfaceRect.minX + radius,
                y: surfaceRect.maxY
            ),
            control1: CGPoint(
                x: surfaceRect.minX,
                y: surfaceRect.maxY - radius + curveControl
            ),
            control2: CGPoint(
                x: surfaceRect.minX + radius - curveControl,
                y: surfaceRect.maxY
            )
        )
        path.addLine(
            to: CGPoint(
                x: surfaceRect.maxX - radius,
                y: surfaceRect.maxY
            )
        )
        path.addCurve(
            to: CGPoint(
                x: surfaceRect.maxX,
                y: surfaceRect.maxY - radius
            ),
            control1: CGPoint(
                x: surfaceRect.maxX - radius + curveControl,
                y: surfaceRect.maxY
            ),
            control2: CGPoint(
                x: surfaceRect.maxX,
                y: surfaceRect.maxY - radius + curveControl
            )
        )
        path.addLine(
            to: CGPoint(x: surfaceRect.maxX, y: surfaceRect.minY)
        )
        path.closeSubpath()
        return path
    }
}

private struct AttachedNotchBorderShape: Shape {
    let horizontalCanvasOutset: CGFloat
    let visibleBorderOutset: CGFloat
    let surfaceHeight: CGFloat
    let bottomCornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let left = rect.minX
            + horizontalCanvasOutset
            - visibleBorderOutset
        let right = rect.maxX
            - horizontalCanvasOutset
            + visibleBorderOutset
        let bottom = min(
            rect.maxY,
            rect.minY + surfaceHeight + visibleBorderOutset
        )
        let radius = min(
            bottomCornerRadius + visibleBorderOutset,
            max(0, (right - left) / 2)
        )
        let curveControl = radius * 0.552_284_75

        var path = Path()
        path.move(to: CGPoint(x: left, y: rect.minY))
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
        path.addLine(to: CGPoint(x: right, y: rect.minY))
        return path
    }
}
