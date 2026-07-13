import AppKit
import Observation
import SwiftUI

@main
struct CtrlSayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem = statusItem

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.toolTip = "Ctrl-Say"
        }

        popover.behavior = .transient
        popover.animates = false
        popover.contentSize = NSSize(width: 360, height: 500)
        popover.contentViewController = NSHostingController(
            rootView: DashboardView(model: model)
        )

        updateStatusItemPresentation()
        observeListeningState()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
    }

    @objc
    private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
            Telemetry.interface.info("Dashboard closed")
            return
        }

        popover.show(
            relativeTo: sender.bounds,
            of: sender,
            preferredEdge: .minY
        )
        popover.contentViewController?.view.window?.makeKey()
        Telemetry.interface.info("Dashboard opened")
    }

    private func updateStatusItemPresentation() {
        let symbolName: String
        let title: String
        let toolTip: String

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
        case .failed:
            symbolName = "exclamationmark.triangle"
            title = " Error"
            toolTip = "Ctrl-Say — Listening failed"
        }

        guard let button = statusItem?.button else { return }
        button.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: "Ctrl-Say"
        )
        button.imagePosition = .imageLeading
        button.title = title
        button.toolTip = toolTip
    }

    private func observeListeningState() {
        withObservationTracking {
            _ = model.speech.state
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.updateStatusItemPresentation()
                self.observeListeningState()
            }
        }
    }
}
