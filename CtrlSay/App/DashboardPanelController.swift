import AppKit
import SwiftUI

@MainActor
final class DashboardPanelController {
    private let panel: NSPanel
    private var outsideClickMonitor: Any?

    var isShown: Bool { panel.isVisible }

    init(rootView: DashboardView) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 500),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        let hostingController = NSHostingController(rootView: rootView)

        panel.contentViewController = hostingController
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .statusBar
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .transient,
            .fullScreenAuxiliary,
            .ignoresCycle,
        ]
        panel.animationBehavior = .none
        panel.backgroundColor = .windowBackgroundColor
        panel.isOpaque = true
        panel.hasShadow = true

        hostingController.view.wantsLayer = true
        hostingController.view.layer?.cornerRadius = 12
        hostingController.view.layer?.cornerCurve = .continuous
        hostingController.view.layer?.masksToBounds = true

        self.panel = panel
    }

    func toggle(relativeTo button: NSStatusBarButton) {
        if isShown {
            hide()
        } else {
            show(relativeTo: button)
        }
    }

    func show(relativeTo button: NSStatusBarButton) {
#if DEBUG
        let frontmostProcessIdentifier = NSWorkspace.shared.frontmostApplication?
            .processIdentifier
#endif
        position(relativeTo: button)
        panel.orderFrontRegardless()
        installOutsideClickMonitor()
#if DEBUG
        Task { @MainActor in
            await Task.yield()
            let focusWasPreserved = NSWorkspace.shared.frontmostApplication?
                .processIdentifier == frontmostProcessIdentifier
            Telemetry.interface.info(
                "Dashboard focus_preserved=\(focusWasPreserved, privacy: .public)"
            )
        }
#endif
    }

    func hide() {
        panel.orderOut(nil)
        removeOutsideClickMonitor()
    }

    private func position(relativeTo button: NSStatusBarButton) {
        guard let buttonWindow = button.window else { return }

        let buttonRectInWindow = button.convert(button.bounds, to: nil)
        let buttonRect = buttonWindow.convertToScreen(buttonRectInWindow)
        let screenFrame = buttonWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let panelSize = panel.frame.size

        var origin = NSPoint(
            x: buttonRect.midX - panelSize.width / 2,
            y: buttonRect.minY - panelSize.height - 6
        )
        origin.x = min(
            max(origin.x, screenFrame.minX + 8),
            screenFrame.maxX - panelSize.width - 8
        )
        if origin.y < screenFrame.minY + 8 {
            origin.y = min(
                buttonRect.maxY + 6,
                screenFrame.maxY - panelSize.height - 8
            )
        }
        panel.setFrameOrigin(origin)
    }

    private func installOutsideClickMonitor() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in
                self?.hide()
            }
        }
    }

    private func removeOutsideClickMonitor() {
        guard let outsideClickMonitor else { return }
        NSEvent.removeMonitor(outsideClickMonitor)
        self.outsideClickMonitor = nil
    }
}
