import Foundation

enum NotchCommandAction: String, Equatable, Sendable {
    case copy
    case paste
}

enum NotchFeedbackEvent: Equatable, Sendable {
    case listeningRequested
    case listeningStopped
    case commandSucceeded(action: NotchCommandAction, label: String)
    case commandFailed(message: String)
}

struct NotchFeedbackSignal: Equatable, Sendable {
    let sequence: UInt64
    let event: NotchFeedbackEvent
}

enum NotchListeningActivity: Equatable, Sendable {
    case inactive
    case preparing
    case listening
}

/// V1 remains passive. These size classes are part of the state model now so
/// later controls can accept pointer input without replacing the presentation
/// architecture or introducing a second notch window.
enum NotchInteractionMode: Equatable, Sendable {
    case passive
    case compactInteractive
    case expandedInteractive

    var acceptsPointerEvents: Bool {
        self != .passive
    }
}

enum NotchVisualState: Equatable, Sendable {
    case hidden
    case preparing
    case listening
    case success(action: NotchCommandAction, label: String)
    case failure(message: String)

    var isVisible: Bool {
        self != .hidden
    }
}

enum NotchTransientFeedback: Equatable, Sendable {
    case success(action: NotchCommandAction, label: String)
    case failure(message: String)

    var visualState: NotchVisualState {
        switch self {
        case .success(let action, let label):
            .success(action: action, label: label)
        case .failure(let message):
            .failure(message: message)
        }
    }

    var duration: Duration {
        switch self {
        case .success:
            .seconds(1)
        case .failure:
            .milliseconds(1_300)
        }
    }
}

struct NotchFeedbackReducerState: Equatable, Sendable {
    var listeningActivity: NotchListeningActivity = .inactive
    var transientFeedback: NotchTransientFeedback?
    var transientGeneration: UInt64 = 0
    var interactionMode: NotchInteractionMode = .passive

    var visualState: NotchVisualState {
        if let transientFeedback {
            return transientFeedback.visualState
        }
        switch listeningActivity {
        case .inactive:
            return .hidden
        case .preparing:
            return .preparing
        case .listening:
            return .listening
        }
    }
}

enum NotchFeedbackReductionEvent: Equatable, Sendable {
    case listeningActivityChanged(NotchListeningActivity)
    case present(NotchTransientFeedback)
    case transientExpired(generation: UInt64)
    case interactionModeChanged(NotchInteractionMode)
}

struct NotchFeedbackReduction: Equatable, Sendable {
    let state: NotchFeedbackReducerState
    let expiration: (generation: UInt64, duration: Duration)?

    static func == (
        lhs: NotchFeedbackReduction,
        rhs: NotchFeedbackReduction
    ) -> Bool {
        lhs.state == rhs.state
            && lhs.expiration?.generation == rhs.expiration?.generation
            && lhs.expiration?.duration == rhs.expiration?.duration
    }
}

enum NotchFeedbackReducer {
    static func reduce(
        _ state: NotchFeedbackReducerState,
        event: NotchFeedbackReductionEvent
    ) -> NotchFeedbackReduction {
        var next = state
        var expiration: (generation: UInt64, duration: Duration)?

        switch event {
        case .listeningActivityChanged(let activity):
            next.listeningActivity = activity
            if activity == .inactive {
                next.transientFeedback = nil
                next.transientGeneration &+= 1
            }

        case .present(let feedback):
            next.transientGeneration &+= 1
            next.transientFeedback = feedback
            expiration = (
                generation: next.transientGeneration,
                duration: feedback.duration
            )

        case .transientExpired(let generation):
            guard generation == state.transientGeneration else {
                return NotchFeedbackReduction(state: state, expiration: nil)
            }
            next.transientFeedback = nil

        case .interactionModeChanged(let interactionMode):
            next.interactionMode = interactionMode
        }

        return NotchFeedbackReduction(state: next, expiration: expiration)
    }
}

enum NotchFeedbackText {
    static func displayLabel(_ value: String) -> String {
        let normalized =
            value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let bounded = String(normalized.prefix(40))
        return bounded.isEmpty ? "Copy" : bounded.capitalized
    }

    static func boundedMessage(_ value: String) -> String {
        let normalized =
            value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let bounded = String(normalized.prefix(52))
        return bounded.isEmpty ? "Command failed" : bounded
    }
}
