import SwiftUI

struct NotchFeedbackView: View {
    let presentationState: NotchFeedbackPresentationState
    let windowContext: NotchWindowContext

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        GeometryReader { proxy in
            if presentationState.visualState.isVisible {
                let surface = surfaceShape(in: proxy.size)
                let border = borderShape(in: proxy.size)
                ZStack {
                    surface
                        .fill(
                            Color.black.opacity(
                                reduceTransparency ? 1 : 0.96
                            )
                        )

                    border
                        .stroke(
                            edgeStyle,
                            lineWidth: contrast == .increased ? 2.8 : 2.2
                        )
                        .blur(radius: contrast == .increased ? 2 : 4)
                        .opacity(glowOpacity)

                    border
                        .stroke(
                            edgeStyle,
                            lineWidth: contrast == .increased ? 1.8 : 1.4
                        )
                        .opacity(0.95)

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

    private var edgeStyle: AnyShapeStyle {
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
            return AnyShapeStyle(listeningEdgeGradient)
        }
    }

    private var listeningEdgeGradient: AngularGradient {
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
            startAngle: .degrees(-90),
            endAngle: .degrees(270)
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
                    bottomCornerRadius: min(12, notchHeight * 0.32)
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
                    bottomCornerRadius: min(12, notchHeight * 0.32)
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
        path.addQuadCurve(
            to: CGPoint(
                x: surfaceRect.minX + radius,
                y: surfaceRect.maxY
            ),
            control: CGPoint(
                x: surfaceRect.minX,
                y: surfaceRect.maxY
            )
        )
        path.addLine(
            to: CGPoint(
                x: surfaceRect.maxX - radius,
                y: surfaceRect.maxY
            )
        )
        path.addQuadCurve(
            to: CGPoint(
                x: surfaceRect.maxX,
                y: surfaceRect.maxY - radius
            ),
            control: CGPoint(
                x: surfaceRect.maxX,
                y: surfaceRect.maxY
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

        var path = Path()
        path.move(to: CGPoint(x: left, y: rect.minY))
        path.addLine(to: CGPoint(x: left, y: bottom - radius))
        path.addQuadCurve(
            to: CGPoint(x: left + radius, y: bottom),
            control: CGPoint(x: left, y: bottom)
        )
        path.addLine(to: CGPoint(x: right - radius, y: bottom))
        path.addQuadCurve(
            to: CGPoint(x: right, y: bottom - radius),
            control: CGPoint(x: right, y: bottom)
        )
        path.addLine(to: CGPoint(x: right, y: rect.minY))
        return path
    }
}
