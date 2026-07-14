import AppKit
import SwiftUI

@MainActor
final class DashboardPanelController {
    private let panel: NSPanel
    private let editingSession: DashboardEditingSession
    private weak var anchorButton: NSStatusBarButton?
    private var outsideClickMonitor: Any?
    private var deferredShowTask: Task<Void, Never>?
    private var wantsToBeShown = false

    var isShown: Bool { panel.isVisible || wantsToBeShown }

    init(
        rootView: DashboardView,
        editingSession: DashboardEditingSession
    ) {
        let panel = NonactivatingPanel(
            contentRect: NSRect(
                origin: .zero,
                size: DashboardPanelMetrics.preferredSize
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        let hostingController = NSHostingController(rootView: rootView)
        let containerController = NSViewController()
        let backdropView = NSVisualEffectView()

        backdropView.material = .popover
        backdropView.blendingMode = .behindWindow
        backdropView.state = .active
        backdropView.wantsLayer = true
        backdropView.layer?.cornerRadius = DashboardPanelMetrics.cornerRadius
        backdropView.layer?.cornerCurve = .continuous
        backdropView.layer?.masksToBounds = true

        containerController.view = backdropView
        containerController.addChild(hostingController)
        backdropView.addSubview(hostingController.view)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hostingController.view.leadingAnchor.constraint(equalTo: backdropView.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: backdropView.trailingAnchor),
            hostingController.view.topAnchor.constraint(equalTo: backdropView.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: backdropView.bottomAnchor),
        ])

        panel.contentViewController = containerController
        panel.title = "Ctrl-Say"
        panel.setAccessibilityElement(true)
        panel.setAccessibilityRole(.window)
        panel.setAccessibilitySubrole(.floatingWindow)
        panel.setAccessibilityTitle("Ctrl-Say")
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .transient,
            .fullScreenAuxiliary,
            .ignoresCycle,
        ]
        panel.animationBehavior = .none
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovable = false
        panel.isMovableByWindowBackground = false

        hostingController.view.wantsLayer = true
        hostingController.view.layer?.backgroundColor = NSColor.clear.cgColor
        hostingController.view.layer?.cornerRadius = DashboardPanelMetrics.cornerRadius
        hostingController.view.layer?.cornerCurve = .continuous
        hostingController.view.layer?.masksToBounds = true

        self.panel = panel
        self.editingSession = editingSession

        editingSession.onBeginEditing = { [weak panel] in
            // A nonactivating panel may become key without moving Ctrl-Say to
            // the foreground or stealing the user's copy/paste destination.
            panel?.makeKey()
        }
        editingSession.onEndEditing = { [weak panel] in
            panel?.makeFirstResponder(nil)
            if panel?.isVisible == true {
                panel?.orderOut(nil)
                panel?.orderFrontRegardless()
            }
        }
    }

    func show(relativeTo button: NSStatusBarButton) {
        anchorButton = button
        wantsToBeShown = true
        deferredShowTask?.cancel()
        deferredShowTask = nil

        guard position(relativeTo: button) else {
            deferredShowTask = Task { @MainActor [weak self] in
                guard let self else { return }

                for _ in 0..<8 {
                    await self.waitForNextMainRunLoopTurn()
                    guard !Task.isCancelled, self.wantsToBeShown else { return }

                    if let button = self.anchorButton,
                       self.position(relativeTo: button) {
                        self.deferredShowTask = nil
                        self.present()
                        return
                    }
                }

                self.deferredShowTask = nil
                self.wantsToBeShown = false
                Telemetry.interface.error(
                    "Dashboard could not attach to the status item"
                )
            }
            return
        }

        present()
    }

    func reposition(relativeTo button: NSStatusBarButton) {
        anchorButton = button
        guard panel.isVisible else { return }
        if !position(relativeTo: button) {
            hide()
        }
    }

    private func present() {
        guard wantsToBeShown else { return }
        wantsToBeShown = false
        deferredShowTask = nil
#if DEBUG
        let frontmostProcessIdentifier = NSWorkspace.shared.frontmostApplication?
            .processIdentifier
#endif
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
        wantsToBeShown = false
        deferredShowTask?.cancel()
        deferredShowTask = nil
        editingSession.prepareForDismissal()
        panel.orderOut(nil)
        removeOutsideClickMonitor()
    }

    private func waitForNextMainRunLoopTurn() async {
        await withCheckedContinuation {
            (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    @discardableResult
    private func position(relativeTo button: NSStatusBarButton) -> Bool {
        guard let buttonWindow = button.window else { return false }

        panel.contentView?.layoutSubtreeIfNeeded()
        let buttonRectInWindow = button.convert(button.bounds, to: nil)
        let buttonRect = buttonWindow.convertToScreen(buttonRectInWindow)
        let screens = NSScreen.screens
        let screenIndex = DashboardPanelPlacement.bestScreenIndex(
            for: buttonRect,
            screenFrames: screens.map(\.frame)
        )
        let targetScreen = screenIndex.map { screens[$0] } ?? buttonWindow.screen
        guard let targetScreen,
              let frame = DashboardPanelPlacement.frame(
                below: buttonRect,
                preferredSize: DashboardPanelMetrics.preferredSize,
                visibleFrame: targetScreen.visibleFrame
              ) else {
            return false
        }

        panel.setFrame(frame, display: false)
#if DEBUG
        let belowAnchor = frame.maxY <= buttonRect.minY
        let visible = targetScreen.visibleFrame.contains(frame)
        Telemetry.interface.info(
            "Dashboard placement anchor_x=\(buttonRect.minX, privacy: .public) anchor_y=\(buttonRect.minY, privacy: .public) frame_x=\(frame.minX, privacy: .public) frame_y=\(frame.minY, privacy: .public) frame_w=\(frame.width, privacy: .public) frame_h=\(frame.height, privacy: .public) below=\(belowAnchor, privacy: .public) visible=\(visible, privacy: .public)"
        )
#endif
        return true
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
