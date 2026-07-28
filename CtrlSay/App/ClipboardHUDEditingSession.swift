import Foundation
import Observation

/// Window-scoped source of truth for the HUD's one active inline editor.
///
/// SwiftUI rows render from `activeTarget`, `draft`, and `validationMessage`.
/// The AppKit panel receives only lifecycle callbacks so it can temporarily
/// accept keyboard focus without activating Ctrl-Say during ordinary use.
@MainActor
@Observable
final class ClipboardHUDEditingSession {
    enum Field: Equatable {
        case name
        case content
    }

    enum Location: Equatable {
        case numbered(Int)
        case temporaryNamed(String)
        case permanent
    }

    struct Target: Equatable {
        let payloadID: UUID
        let location: Location
        let field: Field
    }

    struct Token: Equatable {
        fileprivate let id = UUID()
    }

    @ObservationIgnored var onBeginEditing: (() -> Void)?
    @ObservationIgnored var onEndEditing: (() -> Void)?

    private(set) var activeTarget: Target?
    private(set) var draft = ""
    private(set) var validationMessage: String?

    @ObservationIgnored private var commitAction: ((String) throws -> Void)?
    @ObservationIgnored private var activeToken: Token?

    var isEditing: Bool { activeTarget != nil }
    var activeSessionToken: Token? { activeToken }

    @discardableResult
    func begin(
        target: Target,
        initialDraft: String,
        commit: @escaping (String) throws -> Void
    ) -> Token? {
        if isEditing, !commitActiveSession() {
            return nil
        }

        let token = Token()
        activeTarget = target
        draft = initialDraft
        validationMessage = nil
        commitAction = commit
        activeToken = token

        // Publish the target before the panel becomes key. The live SwiftUI
        // row can then replace its label with the editor during that handoff.
        onBeginEditing?()
        return token
    }

    func isEditing(_ target: Target) -> Bool {
        activeTarget == target
    }

    func updateDraft(_ value: String) {
        guard isEditing else { return }
        draft = value
    }

    func setValidationMessage(_ message: String) {
        guard isEditing else { return }
        validationMessage = message
    }

    func clearValidationMessage(matching message: String) {
        guard validationMessage == message else { return }
        validationMessage = nil
    }

    func markConflict(for payloadID: UUID, message: String) {
        guard activeTarget?.payloadID == payloadID else { return }
        validationMessage = message
    }

    @discardableResult
    func commit(_ target: Target) -> Bool {
        guard activeTarget == target else { return true }
        return commitActiveSession()
    }

    func cancel(_ target: Target) {
        guard activeTarget == target else { return }
        finishActiveSession()
    }

    func cancelEditing(payloadID: UUID) {
        guard activeTarget?.payloadID == payloadID else { return }
        finishActiveSession()
    }

    func prepareForDismissal() {
        guard isEditing else { return }
        if !commitActiveSession() {
            finishActiveSession()
        }
    }

    /// Ends only the editor that was active when an outside interaction began.
    /// A stale interaction must not close a replacement editor.
    func prepareForOutsideInteraction(_ token: Token) {
        guard token == activeToken else { return }
        prepareForDismissal()
    }

    @discardableResult
    private func commitActiveSession() -> Bool {
        guard let commitAction else { return true }
        do {
            try commitAction(draft)
            finishActiveSession()
            return true
        } catch {
            validationMessage = error.localizedDescription
            return false
        }
    }

    private func finishActiveSession() {
        activeTarget = nil
        activeToken = nil
        commitAction = nil
        draft = ""
        validationMessage = nil
        onEndEditing?()
    }
}
