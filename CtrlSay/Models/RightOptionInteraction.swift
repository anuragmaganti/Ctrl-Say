import Foundation

enum RightOptionGesture: Equatable, Sendable {
    case tap
    case hold
}

struct RightOptionInteractionState: Equatable, Sendable {
    var wantsListening: Bool
    var isHUDPresented: Bool
}

enum RightOptionInteractionReducer {
    static func reduce(
        _ state: RightOptionInteractionState,
        gesture: RightOptionGesture
    ) -> RightOptionInteractionState {
        var next = state

        switch gesture {
        case .tap:
            if state.wantsListening {
                next.wantsListening = false
                next.isHUDPresented = false
            } else {
                next.wantsListening = true
                next.isHUDPresented = true
            }

        case .hold:
            next.isHUDPresented.toggle()
        }

        return next
    }
}

enum CtrlSayPreferenceKey {
    static let hudPositionsByDisplay = "clipboardHUDPositionsByDisplay"
}

enum RightOptionEventFilter {
    static let rightOptionKeyCode: UInt16 = 61

    static func recognizes(keyCode: UInt16) -> Bool {
        keyCode == rightOptionKeyCode
    }
}

@MainActor
final class RightOptionPressClassifier {
    private let holdDuration: Duration
    private let onGesture: (RightOptionGesture) -> Void
    private var holdTask: Task<Void, Never>?
    private var isDown = false
    private var didEmitHold = false

    init(
        holdDuration: Duration = .milliseconds(500),
        onGesture: @escaping (RightOptionGesture) -> Void
    ) {
        self.holdDuration = holdDuration
        self.onGesture = onGesture
    }

    func process(isDown: Bool) {
        guard isDown != self.isDown else { return }
        self.isDown = isDown

        if isDown {
            beginPress()
        } else {
            finishPress()
        }
    }

    func reset() {
        holdTask?.cancel()
        holdTask = nil
        isDown = false
        didEmitHold = false
    }

    private func beginPress() {
        holdTask?.cancel()
        didEmitHold = false
        let duration = holdDuration

        holdTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled,
                let self,
                self.isDown,
                !self.didEmitHold
            else {
                return
            }
            self.didEmitHold = true
            self.holdTask = nil
            self.onGesture(.hold)
        }
    }

    private func finishPress() {
        holdTask?.cancel()
        holdTask = nil
        if !didEmitHold {
            onGesture(.tap)
        }
        didEmitHold = false
    }
}
