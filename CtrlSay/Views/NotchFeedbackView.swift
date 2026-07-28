import SwiftUI

struct NotchFeedbackView: View {
    let presentationState: NotchFeedbackPresentationState
    let windowContext: NotchWindowContext

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let surfaceSize = surfaceSize(in: proxy.size)
            let surface = surfaceShape(in: surfaceSize)

            ZStack(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    surface
                        .fill(Color.black)

                    positionedFeedbackContent
                }
                .frame(
                    width: surfaceSize.width,
                    height: surfaceSize.height,
                    alignment: .topLeading
                )
                .clipShape(surface)
                .opacity(presentationState.visualState.isVisible ? 1 : 0)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityLabel)
                .accessibilityHidden(!presentationState.visualState.isVisible)
            }
            .frame(
                width: proxy.size.width,
                height: proxy.size.height,
                alignment: .topLeading
            )
        }
        .animation(
            feedbackAnimation,
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
                        .symbolRenderingMode(.monochrome)
                    Text(label)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .foregroundStyle(.white)
                .transition(feedbackTransition)

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
                .transition(feedbackTransition)
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
                    notchWidth + 12
                )
                .padding(.trailing, 12)
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

    private func surfaceSize(in availableSize: CGSize) -> CGSize {
        let requested = NotchPanelLayoutCalculator.surfaceSize(
            visualState: presentationState.visualState,
            interactionMode: presentationState.interactionMode,
            surfaceStyle: windowContext.surfaceStyle
        )
        return CGSize(
            width: min(requested.width, availableSize.width),
            height: min(requested.height, availableSize.height)
        )
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

    private var feedbackAnimation: Animation? {
        guard !reduceMotion else { return nil }
        switch presentationState.visualState {
        case .success, .failure:
            return .smooth(duration: 0.34, extraBounce: 0.04)
        case .hidden, .preparing, .listening:
            return .smooth(duration: 0.38)
        }
    }

    private var feedbackTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(x: -7)),
            removal: .opacity.combined(with: .offset(x: -3))
        )
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
    let surfaceHeight: CGFloat
    let bottomCornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        Path(
            AttachedNotchGeometry.surfacePath(
                in: rect,
                surfaceHeight: surfaceHeight,
                bottomCornerRadius: bottomCornerRadius
            )
        )
    }
}
