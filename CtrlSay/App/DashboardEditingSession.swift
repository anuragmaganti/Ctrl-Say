import Foundation

/// Coordinates one inline dashboard editor with the nonactivating panel.
///
/// SwiftUI owns the draft and validation state. AppKit only receives lifecycle
/// callbacks so the panel can temporarily accept keyboard focus and commit a
/// valid draft before it is dismissed.
@MainActor
final class DashboardEditingSession {
    struct Token: Equatable {
        fileprivate let id = UUID()
    }

    var onBeginEditing: (() -> Void)?
    var onEndEditing: (() -> Void)?

    private var commitAction: (() -> Bool)?
    private var cancelAction: (() -> Void)?
    private var activeToken: Token?

    var isEditing: Bool { commitAction != nil }
    var activeSessionToken: Token? { activeToken }

    @discardableResult
    func begin(
        commit: @escaping () -> Bool,
        cancel: @escaping () -> Void
    ) -> Token? {
        if let currentCommit = commitAction {
            guard currentCommit() else { return nil }
        }
        if isEditing {
            finishActiveSession()
        }

        let token = Token()
        activeToken = token
        commitAction = commit
        cancelAction = cancel
        onBeginEditing?()
        return token
    }

    func finish(_ token: Token) {
        guard token == activeToken else { return }
        finishActiveSession()
    }

    private func finishActiveSession() {
        activeToken = nil
        commitAction = nil
        cancelAction = nil
        onEndEditing?()
    }

    func prepareForDismissal() {
        guard let commitAction else { return }
        let cancelAction = self.cancelAction
        if !commitAction() {
            cancelAction?()
        }
        if isEditing {
            finishActiveSession()
        }
    }

    /// Ends the editor that was active when an outside interaction began.
    /// A stale interaction must not close an editor opened by that same click.
    func prepareForOutsideInteraction(_ token: Token) {
        guard token == activeToken else { return }
        prepareForDismissal()
    }
}
