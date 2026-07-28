import SwiftUI

private struct NotchFeedbackContent {
    enum Tone {
        case pending
        case success
        case failure
    }

    let systemImage: String
    let text: String
    let tone: Tone

    var iconSize: CGFloat {
        tone == .failure ? 14 : 15
    }

    var textWeight: Font.Weight {
        tone == .failure ? .medium : .semibold
    }

    var minimumScaleFactor: CGFloat {
        tone == .failure ? 0.75 : 0.8
    }

    var iconColor: Color {
        switch tone {
        case .pending:
            .white.opacity(0.72)
        case .success:
            .white
        case .failure:
            .orange
        }
    }

    var textColor: Color {
        tone == .pending ? .white.opacity(0.72) : .white
    }
}

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
            value: presentationState.visualState.presentationPhase
        )
        .accessibilityIdentifier("ctrlSay.notchFeedback")
    }

    private var feedbackContent: some View {
        Group {
            if let content = currentFeedbackContent {
                HStack(spacing: 9) {
                    Image(systemName: content.systemImage)
                        .font(.system(size: content.iconSize, weight: .semibold))
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(content.iconColor)
                        .contentTransition(.identity)
                    Text(content.text)
                        .font(.callout.weight(content.textWeight))
                        .foregroundStyle(content.textColor)
                        .lineLimit(1)
                        .minimumScaleFactor(content.minimumScaleFactor)
                        .contentTransition(.identity)
                }
                .transition(feedbackTransition)
            }
        }
    }

    private var currentFeedbackContent: NotchFeedbackContent? {
        switch presentationState.visualState {
        case .hidden, .preparing, .listening:
            nil
        case .pending(let action, let label):
            NotchFeedbackContent(
                systemImage: commandSymbol(for: action),
                text: label,
                tone: .pending
            )
        case .success(let action, let label):
            NotchFeedbackContent(
                systemImage: commandSymbol(for: action),
                text: label,
                tone: .success
            )
        case .failure(let message):
            NotchFeedbackContent(
                systemImage: "exclamationmark.triangle.fill",
                text: message,
                tone: .failure
            )
        }
    }

    private func commandSymbol(for action: NotchCommandAction) -> String {
        action == .copy ? "doc.on.doc" : "arrow.down.doc"
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
        switch presentationState.visualState.presentationPhase {
        case .feedback:
            return .smooth(duration: 0.16)
        case .hidden, .listening:
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
        case .pending(let action, let label):
            action == .copy ? "Copying to \(label)" : "Pasting \(label)"
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
