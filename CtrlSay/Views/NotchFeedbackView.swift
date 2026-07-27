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
                ZStack {
                    surface
                        .fill(Color.black)

                    NotchBorderLayerView(
                        visualState: presentationState.visualState,
                        interactionMode: presentationState.interactionMode,
                        surfaceStyle: windowContext.surfaceStyle,
                        reduceMotion: reduceMotion,
                        increasedContrast: contrast == .increased
                    )

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

    private func surfaceShape(in size: CGSize) -> AnyShape {
        switch windowContext.surfaceStyle {
        case .attached(_, let notchHeight):
            let surfaceHeight =
                presentationState.interactionMode == .passive
                ? notchHeight
                : size.height
            return AnyShape(
                AttachedNotchSurfaceShape(
                    horizontalCanvasOutset: NotchPanelLayoutCalculator
                        .attachedHorizontalCanvasOutset,
                    surfaceHeight: surfaceHeight,
                    bottomCornerRadius:
                        NotchPanelLayoutCalculator
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
        Path(
            AttachedNotchGeometry.surfacePath(
                in: rect,
                horizontalCanvasOutset: horizontalCanvasOutset,
                surfaceHeight: surfaceHeight,
                bottomCornerRadius: bottomCornerRadius
            )
        )
    }
}
