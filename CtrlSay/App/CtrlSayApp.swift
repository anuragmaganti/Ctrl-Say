import AppKit
import Observation
import SwiftUI

@main
struct CtrlSayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            CtrlSaySettingsView(model: appDelegate.model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: AppModel
    private let dashboardEditingSession = DashboardEditingSession()
    private lazy var hudEditingSession = DashboardEditingSession()
    private lazy var hudPresentationState = ClipboardHUDPresentationState()
    private lazy var thumbnailProvider = ClipboardThumbnailProvider()
    private lazy var notchPresentationState = NotchFeedbackPresentationState()
    private lazy var dashboardPanel = DashboardPanelController(
        rootView: DashboardView(
            model: model,
            editingSession: dashboardEditingSession
        ),
        editingSession: dashboardEditingSession
    )
    private var statusItem: NSStatusItem?
    private var hudPanel: ClipboardHUDPanelController?
    private var notchPanel: NotchFeedbackPanelController?
    private var processedNotchFeedbackSequence: UInt64 = 0
    private var terminationTask: Task<Void, Never>?

    override init() {
#if DEBUG
        if CommandLine.arguments.contains("-CtrlSaySeedHUDForTesting") {
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
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem = statusItem

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.toolTip = "Ctrl-Say"
        }

        updateStatusItemPresentation()
        observeListeningState()
        observeHUDPresentation()
        observeNotchFeedback()

#if DEBUG
        if CommandLine.arguments.contains("-CtrlSaySeedHUDForTesting") {
            Task { @MainActor [weak self] in
                guard let self else { return }
                await model.waitForPermanentStorageRestore()
                seedHUDForTesting()
            }
        }
        if CommandLine.arguments.contains("-CtrlSayShowHUDForTesting") {
            model.setClipboardHUDPresented(true)
        }
        if CommandLine.arguments.contains("-CtrlSayShowNotchListeningForTesting") {
            _ = ensureNotchPanel()
            notchPresentationState.setListeningActivity(.listening)
        }
        if CommandLine.arguments.contains("-CtrlSayShowNotchCopyForTesting") {
            _ = ensureNotchPanel()
            notchPresentationState.setListeningActivity(.listening)
            notchPresentationState.presentPersistentPreview(
                .success(action: .copy, label: "House")
            )
        }
        if CommandLine.arguments.contains("-CtrlSayStressNotchForTesting") {
            runNotchStressPreview()
        }
#endif

        Task { @MainActor [weak self] in
            await Task.yield()
            self?.presentSetupIfNeeded()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        terminationTask?.cancel()
        dashboardPanel.hide()
        hudPanel?.hide()
        notchPresentationState.reset()
        notchPanel?.hideImmediately()
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
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
        updateStatusItemPresentation()
    }

    func applicationDidChangeScreenParameters(_ notification: Notification) {
        if let button = statusItem?.button {
            dashboardPanel.reposition(relativeTo: button)
        }
        hudPanel?.screenParametersDidChange()
        notchPanel?.screenParametersDidChange()
    }

    @objc
    private func togglePopover(_ sender: NSStatusBarButton) {
        if dashboardPanel.isShown {
            dashboardPanel.hide()
            Telemetry.interface.info("Dashboard closed")
            return
        }

        dashboardPanel.show(relativeTo: sender)
        Telemetry.interface.info("Dashboard opened")
    }

    private func updateStatusItemPresentation() {
        let symbolName: String
        let title: String
        let toolTip: String

        if !model.isReadyForCommands
            || !model.hasAnsweredLaunchAtLoginOnboarding {
            symbolName = "checklist"
            title = " Setup"
            toolTip = "Ctrl-Say — Complete setup"
        } else {
            switch model.speech.state {
            case .stopped:
                symbolName = "waveform.circle"
                title = ""
                toolTip = "Ctrl-Say — Not listening"
            case .requestingMicrophone, .preparing, .downloadingModel:
                symbolName = "waveform.circle"
                title = " Starting…"
                toolTip = "Ctrl-Say — Starting on-device listening"
            case .listening:
                symbolName = "waveform.circle.fill"
                title = " Listening"
                toolTip = "Ctrl-Say — Listening"
            case .stopping:
                symbolName = "waveform.circle"
                title = " Stopping…"
                toolTip = "Ctrl-Say — Stopping listening"
            case .failed:
                symbolName = "exclamationmark.triangle"
                title = " Error"
                toolTip = "Ctrl-Say — Listening failed"
            }
        }

        guard let button = statusItem?.button else { return }
        button.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: "Ctrl-Say"
        )
        button.imagePosition = .imageLeading
        button.title = title
        button.toolTip = toolTip
        dashboardPanel.reposition(relativeTo: button)
    }

    private func observeListeningState() {
        withObservationTracking {
            _ = model.speech.state
            _ = model.speech.microphoneAuthorization
            _ = model.hasKeyboardMonitoringAccess
            _ = model.hasEventPostingAccess
            _ = model.hasAnsweredLaunchAtLoginOnboarding
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.updateStatusItemPresentation()
                self.updateNotchListeningPresentation()
                self.observeListeningState()
            }
        }
        updateNotchListeningPresentation()
    }

    private func observeNotchFeedback() {
        withObservationTracking {
            _ = model.notchFeedbackSignal
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.processLatestNotchFeedback()
                self.observeNotchFeedback()
            }
        }
        processLatestNotchFeedback()
    }

    private func processLatestNotchFeedback() {
        guard let signal = model.notchFeedbackSignal,
              signal.sequence > processedNotchFeedbackSequence else {
            return
        }
        processedNotchFeedbackSequence = signal.sequence

        switch signal.event {
        case .listeningRequested:
            _ = ensureNotchPanel()
            notchPresentationState.setListeningActivity(.preparing)

        case .listeningStopped:
            notchPresentationState.setListeningActivity(.inactive)

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
            || message.localizedCaseInsensitiveContains("speech") {
            return "Speech recognition unavailable"
        }
        return "Listening unavailable"
    }

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

#if DEBUG
    private func runNotchStressPreview() {
        _ = ensureNotchPanel()
        Task { @MainActor [weak self] in
            guard let self else { return }
            let transitionCount = 360
            for index in 0..<transitionCount {
                switch index % 8 {
                case 0:
                    notchPresentationState.setListeningActivity(.preparing)
                case 1, 7:
                    notchPresentationState.setListeningActivity(.listening)
                case 2:
                    notchPresentationState.present(
                        .success(action: .copy, label: "House")
                    )
                case 3:
                    notchPresentationState.setListeningActivity(.inactive)
                case 4:
                    notchPresentationState.setListeningActivity(.preparing)
                case 5:
                    notchPresentationState.present(
                        .success(action: .paste, label: "2")
                    )
                default:
                    notchPresentationState.setListeningActivity(.inactive)
                }
                try? await Task.sleep(for: .milliseconds(12))
            }
            notchPresentationState.setListeningActivity(.listening)
            Telemetry.interface.info(
                "Notch stress complete transitions=\(transitionCount, privacy: .public)"
            )
        }
    }

    private func seedHUDForTesting() {
        for number in 1...10 {
            let text = "Example clipboard content for slot \(number) with a bounded two-line preview."
            let data = Data(text.utf8)
            let payload = ClipboardPayload(
                items: [
                    PasteboardItemPayload(
                        representations: [
                            PasteboardRepresentation(
                                typeIdentifier: "public.utf8-plain-text",
                                data: data
                            ),
                        ]
                    ),
                ],
                kind: .text,
                preview: ClipboardPayload.preview(forText: text),
                byteCount: data.count
            )
            try? model.slots.set(payload, at: number)
        }

        let temporaryText = "Session-only content stored under a memorable spoken name."
        let temporaryData = Data(temporaryText.utf8)
        let temporaryPayload = ClipboardPayload(
            items: [
                PasteboardItemPayload(
                    representations: [
                        PasteboardRepresentation(
                            typeIdentifier: "public.utf8-plain-text",
                            data: temporaryData
                        ),
                    ]
                ),
            ],
            kind: .text,
            preview: ClipboardPayload.preview(forText: temporaryText),
            byteCount: temporaryData.count
        )
        try? model.slots.setTemporaryNamed(temporaryPayload, named: "house")

        let permanentText = "123 Example Street, Example City"
        let permanentData = Data(permanentText.utf8)
        let permanentPayload = ClipboardPayload(
            items: [
                PasteboardItemPayload(
                    representations: [
                        PasteboardRepresentation(
                            typeIdentifier: "public.utf8-plain-text",
                            data: permanentData
                        ),
                    ]
                ),
            ],
            kind: .text,
            preview: ClipboardPayload.preview(forText: permanentText),
            byteCount: permanentData.count
        )
        try? model.slots.set(permanentPayload, named: "address")
    }
#endif

    private func presentSetupIfNeeded() {
        model.refreshPermissions()
        model.refreshLaunchAtLogin()
        guard (!model.isReadyForCommands
                || !model.hasAnsweredLaunchAtLoginOnboarding),
              !dashboardPanel.isShown,
              let button = statusItem?.button else {
            return
        }

        dashboardPanel.show(relativeTo: button)
        Telemetry.interface.info("First-run setup opened")
    }

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
