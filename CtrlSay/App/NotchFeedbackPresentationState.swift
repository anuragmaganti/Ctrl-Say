import Observation

@MainActor
@Observable
final class NotchFeedbackPresentationState {
    private(set) var reducerState = NotchFeedbackReducerState()

    @ObservationIgnored private var expirationTask: Task<Void, Never>?

    var visualState: NotchVisualState {
        reducerState.visualState
    }

    var interactionMode: NotchInteractionMode {
        reducerState.interactionMode
    }

    func setListeningActivity(_ activity: NotchListeningActivity) {
        apply(.listeningActivityChanged(activity))
    }

    func present(_ feedback: NotchTransientFeedback) {
        apply(.present(feedback))
    }

    func setInteractionMode(_ interactionMode: NotchInteractionMode) {
        apply(.interactionModeChanged(interactionMode))
    }

    func reset() {
        expirationTask?.cancel()
        expirationTask = nil
        reducerState = NotchFeedbackReducerState()
    }

    #if DEBUG
    func presentPersistentPreview(_ feedback: NotchTransientFeedback) {
        expirationTask?.cancel()
        expirationTask = nil
        let reduction = NotchFeedbackReducer.reduce(
            reducerState,
            event: .present(feedback)
        )
        reducerState = reduction.state
    }
    #endif

    private func apply(_ event: NotchFeedbackReductionEvent) {
        let reduction = NotchFeedbackReducer.reduce(
            reducerState,
            event: event
        )
        // The panel controller owns window geometry. Propagating a SwiftUI
        // animation transaction through this observable state also animated
        // NSHostingController's size negotiation, which could create an
        // unbounded AppKit constraint-update cycle after command feedback.
        reducerState = reduction.state

        if reduction.state.transientFeedback == nil {
            expirationTask?.cancel()
            expirationTask = nil
        }
        guard let expiration = reduction.expiration else { return }

        expirationTask?.cancel()
        expirationTask = Task { [weak self] in
            do {
                try await Task.sleep(for: expiration.duration)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.apply(
                .transientExpired(generation: expiration.generation)
            )
        }
    }
}
