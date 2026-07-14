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
    private let dashboardPresentationState = DashboardPresentationState()
    private lazy var hudEditingSession = DashboardEditingSession()
    private lazy var hudPresentationState = ClipboardHUDPresentationState()
    private lazy var thumbnailProvider = ClipboardThumbnailProvider()
    private lazy var notchPresentationState = NotchFeedbackPresentationState()
    private lazy var dashboardPanel = DashboardPanelController(
        rootView: DashboardView(
            model: model,
            presentationState: dashboardPresentationState
        ),
        presentationState: dashboardPresentationState
    )
    private var statusItem: NSStatusItem?
    private var hudPanel: ClipboardHUDPanelController?
    private var notchPanel: NotchFeedbackPanelController?
    private var processedNotchFeedbackSequence: UInt64 = 0
    private var terminationTask: Task<Void, Never>?

    override init() {
#if DEBUG
        if CommandLine.arguments.contains("-CtrlSaySeedHUDForTesting")
            || CommandLine.arguments.contains("-CtrlSayStressHUDLayoutForTesting")
            || CommandLine.arguments.contains("-CtrlSayStressPresentationSurfacesForTesting") {
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
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
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
        if CommandLine.arguments.contains("-CtrlSayShowHUDPermanentForTesting") {
            hudPresentationState.selectedCollection = .permanent
        }
        if CommandLine.arguments.contains("-CtrlSayShowHUDForTesting")
            || CommandLine.arguments.contains("-CtrlSayShowHUDPermanentForTesting") {
            model.setClipboardHUDPresented(true)
        }
        if CommandLine.arguments.contains("-CtrlSayShowDashboardForTesting") {
            if CommandLine.arguments.contains("-CtrlSayExpandDashboardDiagnosticsForTesting") {
                dashboardPresentationState.showsDeveloperDiagnostics = true
            }
            Task { @MainActor [weak self] in
                // The validation launcher can run before AppKit has attached
                // the status item to its window. Real user clicks occur after
                // attachment; this Debug-only pause makes the automated render
                // exercise that same state.
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, let button = statusItem.button else { return }
                dashboardPanel.show(relativeTo: button)
            }
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
        if CommandLine.arguments.contains("-CtrlSayStressHUDLayoutForTesting") {
            model.setClipboardHUDPresented(true)
            runHUDLayoutStressPreview()
        }
        if CommandLine.arguments.contains("-CtrlSayStressPresentationSurfacesForTesting") {
            runPresentationSurfaceStressPreview()
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
        let toolTip: String

        if !model.isReadyForCommands
            || !model.hasAnsweredLaunchAtLoginOnboarding {
            symbolName = "checklist"
            toolTip = "Ctrl-Say — Complete setup"
        } else {
            switch model.speech.state {
            case .stopped:
                symbolName = "waveform.circle"
                toolTip = "Ctrl-Say — Not listening"
            case .requestingMicrophone, .preparing, .downloadingModel:
                symbolName = "waveform.circle"
                toolTip = "Ctrl-Say — Starting on-device listening"
            case .listening:
                symbolName = "waveform.circle.fill"
                toolTip = "Ctrl-Say — Listening"
            case .stopping:
                symbolName = "waveform.circle"
                toolTip = "Ctrl-Say — Stopping listening"
            case .failed:
                symbolName = "exclamationmark.triangle"
                toolTip = "Ctrl-Say — Listening failed"
            }
        }

        guard let button = statusItem?.button else { return }
        button.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: "Ctrl-Say"
        )
        button.imagePosition = .imageOnly
        button.title = ""
        button.toolTip = toolTip
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
    private func runPresentationSurfaceStressPreview() {
        let notchPanel = ensureNotchPanel()
        let hudPanel = hudPanel ?? makeHUDPanel()

        Task { @MainActor [weak self] in
            guard let self else { return }
            await model.waitForPermanentStorageRestore()
            // Automated launch can reach this task before the status item has
            // a window. A physical click cannot, so wait only in this Debug
            // stress harness until it can exercise real panel attachment.
            for _ in 0..<10 where statusItem?.button?.window == nil {
                try? await Task.sleep(for: .milliseconds(25))
            }
            guard let statusButton = statusItem?.button,
                  statusButton.window != nil else {
                Telemetry.interface.error(
                    "Presentation surface stress missing status item"
                )
                return
            }
            // Let the system finish its initial status-item reflow before the
            // harness deliberately starts rapid hide/show and resize cycles.
            try? await Task.sleep(for: .milliseconds(500))

            hudPanel.show()
            dashboardPanel.show(relativeTo: statusButton)
            notchPresentationState.setListeningActivity(.listening)

            let transitionCount = 480
            for index in 0..<transitionCount {
                let payload = stressPayload(index: index)
                switch index % 12 {
                case 0:
                    try? model.slots.set(payload, at: 1)
                case 1:
                    try? model.slots.set(payload, named: "stress")
                case 2:
                    hudPresentationState.selectedCollection = index
                        .isMultiple(of: 2) ? .numbered : .permanent
                    switch (index / 12) % 3 {
                    case 0:
                        notchPresentationState.setInteractionMode(.passive)
                    case 1:
                        notchPresentationState.setInteractionMode(.compactInteractive)
                    default:
                        notchPresentationState.setInteractionMode(.expandedInteractive)
                    }
                case 3:
                    switch (index / 12) % 4 {
                    case 0:
                        notchPresentationState.setListeningActivity(.preparing)
                    case 1:
                        notchPresentationState.present(
                            .success(action: .copy, label: "Stress")
                        )
                    case 2:
                        notchPresentationState.present(
                            .failure(message: "Stress failure")
                        )
                    default:
                        notchPresentationState.setListeningActivity(.inactive)
                    }
                case 4:
                    dashboardPanel.hide()
                case 5:
                    dashboardPanel.show(relativeTo: statusButton)
                case 6:
                    hudPanel.hide()
                case 7:
                    hudPanel.show()
                case 8:
                    dashboardPresentationState.showsDeveloperDiagnostics.toggle()
                case 9:
                    if let token = hudEditingSession.begin(
                        commit: { true },
                        cancel: {}
                    ) {
                        hudEditingSession.finish(token)
                    }
                case 10:
                    _ = model.slots.removeNamed("stress")
                default:
                    _ = model.slots.removeNumbered(1)
                    notchPresentationState.setListeningActivity(.listening)
                }
                try? await Task.sleep(for: .milliseconds(4))
            }

            hudEditingSession.prepareForDismissal()
            dashboardPanel.hide()
            hudPanel.hide()
            notchPresentationState.setInteractionMode(.passive)
            notchPresentationState.setListeningActivity(.inactive)
            try? await Task.sleep(for: .milliseconds(350))
            notchPanel.hideImmediately()
            Telemetry.interface.info(
                "Presentation surface stress complete transitions=\(transitionCount, privacy: .public)"
            )
        }
    }

    private func runHUDLayoutStressPreview() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await model.waitForPermanentStorageRestore()

            let transitionCount = 240
            for index in 0..<transitionCount {
                let payload = stressPayload(index: index)

                switch index % 6 {
                case 0:
                    try? model.slots.set(payload, at: 1)
                case 1:
                    try? model.slots.setTemporaryNamed(payload, named: "stress")
                case 2:
                    _ = model.slots.removeNumbered(1)
                case 3:
                    try? model.slots.set(payload, named: "stress")
                case 4:
                    _ = model.slots.removeTemporaryNamed("stress")
                default:
                    _ = model.slots.removeNamed("stress")
                }

                hudPresentationState.selectedCollection = index.isMultiple(of: 2)
                    ? .numbered
                    : .permanent
                try? await Task.sleep(for: .milliseconds(5))
            }

            Telemetry.interface.info(
                "HUD layout stress complete transitions=\(transitionCount, privacy: .public)"
            )
        }
    }

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

    private func stressPayload(index: Int) -> ClipboardPayload {
        let text = "Presentation stress payload \(index)"
        let data = Data(text.utf8)
        return ClipboardPayload(
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
