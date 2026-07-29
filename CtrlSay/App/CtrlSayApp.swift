import AppKit
import Observation
import SwiftUI

@main
struct CtrlSayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            DashboardView(model: appDelegate.model)
        } label: {
            MenuBarStatusLabel(model: appDelegate.model)
        }
        .menuBarExtraStyle(.window)

        Window("Set Up Ctrl-Say", id: "setup") {
            CtrlSaySetupView(model: appDelegate.model)
        }
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(
            appDelegate.model.isReadyForCommands ? .suppressed : .presented
        )
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: AppModel
    private lazy var hudEditingSession = ClipboardHUDEditingSession()
    private lazy var hudPresentationState = ClipboardHUDPresentationState()
    private lazy var thumbnailProvider = ClipboardThumbnailProvider()
    private lazy var notchPresentationState = NotchFeedbackPresentationState()
    private var hudPanel: ClipboardHUDPanelController?
    private var notchPanel: NotchFeedbackPanelController?
    private var terminationTask: Task<Void, Never>?
    #if DEBUG
    private var debugPresentationHarness: DebugPresentationHarness?
    #endif

    // MARK: - Application Lifecycle

    override init() {
        #if DEBUG
        if DebugPresentationHarness.requiresEphemeralStorage(
            arguments: CommandLine.arguments
        ) {
            model = AppModel(
                permanentRepository: PermanentCopyRepository(location: .memory)
            )
        } else {
            model = AppModel()
        }
        #else
        model = AppModel()
        #endif
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.onNotchFeedback = { [weak self] event in
            self?.processNotchFeedback(event)
        }
        observeListeningState()
        observeHUDPresentation()
        model.prewarmSpeechRecognitionIfReady()

        #if DEBUG
        let debugPresentationHarness = DebugPresentationHarness(
            model: model,
            hudEditingSession: hudEditingSession,
            hudPresentationState: hudPresentationState,
            notchPresentationState: notchPresentationState,
            ensureHUDPanel: { [unowned self] in
                hudPanel ?? makeHUDPanel()
            },
            ensureNotchPanel: { [unowned self] in
                ensureNotchPanel()
            }
        )
        self.debugPresentationHarness = debugPresentationHarness
        debugPresentationHarness.run(arguments: CommandLine.arguments)
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        terminationTask?.cancel()
        model.onNotchFeedback = nil
        hudPanel?.hide()
        notchPresentationState.reset()
        notchPanel?.hideImmediately()
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        guard model.hasPendingPermanentWrites else {
            return .terminateNow
        }
        guard terminationTask == nil else {
            return .terminateLater
        }

        terminationTask = Task { @MainActor [weak self] in
            guard let self else {
                sender.reply(toApplicationShouldTerminate: false)
                return
            }
            do {
                try await flushPermanentCopiesBeforeQuit()
                terminationTask = nil
                sender.reply(toApplicationShouldTerminate: true)
            } catch {
                let shouldQuit = presentUnsavedChangesAlert()
                terminationTask = nil
                sender.reply(toApplicationShouldTerminate: shouldQuit)
            }
        }
        return .terminateLater
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Returning from Privacy & Security should make the shortcut usable
        // immediately after the user grants Input Monitoring access.
        model.refreshPermissions()
        model.refreshLaunchAtLogin()
    }

    func applicationDidChangeScreenParameters(_ notification: Notification) {
        hudPanel?.screenParametersDidChange()
        notchPanel?.screenParametersDidChange()
    }

    // MARK: - Model Observation

    private func observeListeningState() {
        withObservationTracking {
            _ = model.speech.state
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.updateNotchListeningPresentation()
                self.observeListeningState()
            }
        }
        updateNotchListeningPresentation()
    }

    // MARK: - Notch Feedback

    private func processNotchFeedback(_ event: NotchFeedbackEvent) {
        switch event {
        case .listeningRequested:
            // Listening state creates the panel outside the capture request.
            notchPresentationState.setListeningActivity(.preparing)

        case .listeningStopped:
            notchPresentationState.setListeningActivity(.inactive)

        case .commandPending(let action, let label):
            _ = ensureNotchPanel()
            notchPresentationState.present(
                .pending(
                    action: action,
                    label: NotchFeedbackText.displayLabel(label)
                )
            )

        case .commandPendingCancelled:
            notchPresentationState.clearTransientFeedback()

        case .commandSucceeded(let action, let label):
            _ = ensureNotchPanel()
            notchPresentationState.present(
                .success(
                    action: action,
                    label: NotchFeedbackText.displayLabel(label)
                )
            )

        case .commandFailed(let message):
            _ = ensureNotchPanel()
            notchPresentationState.present(
                .failure(
                    message: NotchFeedbackText.boundedMessage(message)
                )
            )
        }
    }

    private func updateNotchListeningPresentation() {
        switch model.speech.state {
        case .stopped:
            notchPresentationState.setListeningActivity(.inactive)

        case .requestingMicrophone, .preparing, .downloadingModel:
            _ = ensureNotchPanel()
            notchPresentationState.setListeningActivity(.preparing)

        case .listening:
            _ = ensureNotchPanel()
            notchPresentationState.setListeningActivity(.listening)

        case .stopping:
            notchPresentationState.setListeningActivity(.inactive)

        case .failed(let message):
            _ = ensureNotchPanel()
            notchPresentationState.setListeningActivity(.inactive)
            notchPresentationState.present(
                .failure(message: conciseListeningFailure(message))
            )
        }
    }

    private func ensureNotchPanel() -> NotchFeedbackPanelController {
        if let notchPanel {
            return notchPanel
        }
        let panel = NotchFeedbackPanelController(
            presentationState: notchPresentationState
        )
        notchPanel = panel
        return panel
    }

    private func conciseListeningFailure(_ message: String) -> String {
        if message.localizedCaseInsensitiveContains("microphone") {
            return "Microphone unavailable"
        }
        if message.localizedCaseInsensitiveContains("model")
            || message.localizedCaseInsensitiveContains("speech")
        {
            return "Speech recognition unavailable"
        }
        return "Listening unavailable"
    }

    // MARK: - Clipboard HUD

    private func observeHUDPresentation() {
        withObservationTracking {
            _ = model.isClipboardHUDPresented
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.updateHUDPresentation()
                self.observeHUDPresentation()
            }
        }
        updateHUDPresentation()
    }

    private func updateHUDPresentation() {
        if model.isClipboardHUDPresented {
            let hudPanel = hudPanel ?? makeHUDPanel()
            if !hudPanel.isShown {
                hudPanel.show()
            }
        } else if hudPanel?.isShown == true {
            hudPanel?.hide()
        }
    }

    private func makeHUDPanel() -> ClipboardHUDPanelController {
        let panel = ClipboardHUDPanelController(
            model: model,
            presentationState: hudPresentationState,
            editingSession: hudEditingSession,
            thumbnailProvider: thumbnailProvider
        )
        hudPanel = panel
        return panel
    }

    // MARK: - Termination

    private func flushPermanentCopiesBeforeQuit() async throws {
        try await withCheckedThrowingContinuation { continuation in
            let race = QuitFlushRace(continuation: continuation)
            Task { [model] in
                do {
                    try await model.flushPermanentCopies()
                    await race.resolve(.success(()))
                } catch {
                    await race.resolve(.failure(error))
                }
            }
            Task {
                do {
                    try await Task.sleep(for: .seconds(5))
                    await race.resolve(
                        .failure(PermanentCopyPersistenceError.flushTimedOut)
                    )
                } catch {
                    // The app is already terminating or this task was canceled.
                }
            }
        }
    }

    private func presentUnsavedChangesAlert() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Permanent copies couldn’t be saved"
        alert.informativeText = "Quitting now may discard recent permanent-copy changes."
        alert.addButton(withTitle: "Cancel Quit")
        let destructiveButton = alert.addButton(withTitle: "Quit Without Saving")
        destructiveButton.hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn
    }
}

private actor QuitFlushRace {
    private var continuation: CheckedContinuation<Void, any Error>?

    init(continuation: CheckedContinuation<Void, any Error>) {
        self.continuation = continuation
    }

    func resolve(_ result: Result<Void, any Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }
}
