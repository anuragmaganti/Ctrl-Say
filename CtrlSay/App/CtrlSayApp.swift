import AppKit
import Observation
import SwiftUI

@main
struct CtrlSayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            CtrlSaySettingsView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private let dashboardEditingSession = DashboardEditingSession()
    private lazy var hudEditingSession = DashboardEditingSession()
    private lazy var hudPresentationState = ClipboardHUDPresentationState()
    private lazy var thumbnailProvider = ClipboardThumbnailProvider()
    private lazy var dashboardPanel = DashboardPanelController(
        rootView: DashboardView(
            model: model,
            editingSession: dashboardEditingSession
        ),
        editingSession: dashboardEditingSession
    )
    private var statusItem: NSStatusItem?
    private var hudPanel: ClipboardHUDPanelController?

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

#if DEBUG
        if CommandLine.arguments.contains("-CtrlSaySeedHUDForTesting") {
            seedHUDForTesting()
        }
        if CommandLine.arguments.contains("-CtrlSayShowHUDForTesting") {
            model.setClipboardHUDPresented(true)
        }
#endif

        Task { @MainActor [weak self] in
            await Task.yield()
            self?.presentSetupIfNeeded()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        dashboardPanel.hide()
        hudPanel?.hide()
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Returning from Privacy & Security should make the shortcut usable
        // immediately after the user grants Input Monitoring access.
        model.refreshPermissions()
        updateStatusItemPresentation()
    }

    func applicationDidChangeScreenParameters(_ notification: Notification) {
        guard let button = statusItem?.button else { return }
        dashboardPanel.reposition(relativeTo: button)
        hudPanel?.screenParametersDidChange()
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

        if !model.isReadyForCommands {
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
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.updateStatusItemPresentation()
                self.observeListeningState()
            }
        }
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
        try? model.slots.set(permanentPayload, named: "house")
    }
#endif

    private func presentSetupIfNeeded() {
        model.refreshPermissions()
        guard !model.isReadyForCommands,
              !dashboardPanel.isShown,
              let button = statusItem?.button else {
            return
        }

        dashboardPanel.show(relativeTo: button)
        Telemetry.interface.info("First-run setup opened")
    }
}
