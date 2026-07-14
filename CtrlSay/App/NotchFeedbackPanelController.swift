import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class NotchWindowContext {
    private(set) var surfaceStyle: NotchSurfaceStyle = .floating

    func update(surfaceStyle: NotchSurfaceStyle) {
        guard self.surfaceStyle != surfaceStyle else { return }
        self.surfaceStyle = surfaceStyle
    }
}

@MainActor
final class NotchFeedbackPanelController {
    private let panel: NonactivatingPanel
    private let presentationState: NotchFeedbackPresentationState
    private let windowContext = NotchWindowContext()
    private weak var activeScreen: NSScreen?
    private var delayedHideTask: Task<Void, Never>?

    init(presentationState: NotchFeedbackPresentationState) {
        self.presentationState = presentationState

        let panel = NonactivatingPanel(
            contentRect: CGRect(x: 0, y: 0, width: 152, height: 30),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        let rootView = NotchFeedbackView(
            presentationState: presentationState,
            windowContext: windowContext
        )
        let hostingController = NSHostingController(rootView: rootView)
        // The panel frame is intentionally the only source of window size.
        // NSHostingController's default sizing options feed SwiftUI's measured
        // min/max sizes back into NSWindow; changing feedback states could then
        // oscillate between the controller's frame and the hosting view's
        // preferred size until AppKit raised NSGenericException.
        hostingController.sizingOptions = []
        panel.contentViewController = hostingController
        hostingController.view.autoresizingMask = [.width, .height]

        panel.title = "Ctrl-Say Status"
        panel.setAccessibilityElement(true)
        panel.setAccessibilityRole(.window)
        panel.setAccessibilitySubrole(.floatingWindow)
        panel.setAccessibilityTitle("Ctrl-Say Status")
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .statusBar
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .ignoresCycle,
            .stationary,
        ]
        panel.animationBehavior = .none
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isMovable = false
        panel.ignoresMouseEvents = true

        hostingController.view.wantsLayer = true
        hostingController.view.layer?.backgroundColor = NSColor.clear.cgColor

        self.panel = panel
        observePresentation()
    }

    func hideImmediately() {
        delayedHideTask?.cancel()
        delayedHideTask = nil
        panel.orderOut(nil)
    }

    func screenParametersDidChange() {
        guard panel.isVisible else { return }
        activeScreen = bestScreenForCurrentFrame()
        updatePresentation(animated: false)
    }

    private func observePresentation() {
        withObservationTracking {
            _ = presentationState.visualState
            _ = presentationState.interactionMode
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.updatePresentation(animated: true)
                self.observePresentation()
            }
        }
        updatePresentation(animated: false)
    }

    private func updatePresentation(animated: Bool) {
        let visualState = presentationState.visualState
        panel.ignoresMouseEvents = !presentationState
            .interactionMode
            .acceptsPointerEvents

        if visualState.isVisible {
            delayedHideTask?.cancel()
            delayedHideTask = nil
            let wasVisible = panel.isVisible
            let screen = wasVisible
                ? (activeScreen ?? bestScreenForCurrentFrame())
                : pointerScreen()
            activeScreen = screen
            applyLayout(
                on: screen,
                visualState: visualState
            )

            guard !wasVisible else { return }
#if DEBUG
            let frontmostProcessIdentifier = NSWorkspace.shared
                .frontmostApplication?
                .processIdentifier
#endif
            let startedAt = DispatchTime.now().uptimeNanoseconds
            panel.orderFrontRegardless()
            let milliseconds = Double(
                DispatchTime.now().uptimeNanoseconds - startedAt
            ) / 1_000_000
            Telemetry.interface.debug(
                "Notch presented duration_ms=\(milliseconds, privacy: .public)"
            )
#if DEBUG
            Task { @MainActor in
                await Task.yield()
                let focusWasPreserved = NSWorkspace.shared
                    .frontmostApplication?
                    .processIdentifier == frontmostProcessIdentifier
                Telemetry.interface.info(
                    "Notch focus_preserved=\(focusWasPreserved, privacy: .public)"
                )
            }
#endif
            return
        }

        guard panel.isVisible else { return }
        let screen = activeScreen ?? bestScreenForCurrentFrame()
        activeScreen = screen
        let shouldAnimate = animated
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        applyLayout(
            on: screen,
            visualState: .hidden
        )
        delayedHideTask?.cancel()
        guard shouldAnimate else {
            panel.orderOut(nil)
            return
        }

        delayedHideTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(240))
            } catch {
                return
            }
            guard !Task.isCancelled,
                  let self,
                  !self.presentationState.visualState.isVisible else {
                return
            }
            self.panel.orderOut(nil)
            self.delayedHideTask = nil
        }
    }

    private func applyLayout(
        on screen: NSScreen,
        visualState: NotchVisualState
    ) {
        let display = NotchDisplayGeometry(
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            safeAreaTop: screen.safeAreaInsets.top,
            auxiliaryTopLeftArea: screen.auxiliaryTopLeftArea,
            auxiliaryTopRightArea: screen.auxiliaryTopRightArea
        )
        let layout = NotchPanelLayoutCalculator.layout(
            visualState: visualState,
            interactionMode: presentationState.interactionMode,
            display: display
        )
        windowContext.update(surfaceStyle: layout.surfaceStyle)
        panel.setFrame(layout.frame, display: true)
    }

    private func pointerScreen() -> NSScreen {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(location) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    private func bestScreenForCurrentFrame() -> NSScreen {
        NSScreen.screens.max { first, second in
            first.frame.intersection(panel.frame).area
                < second.frame.intersection(panel.frame).area
        } ?? pointerScreen()
    }
}

private extension CGRect {
    var area: CGFloat {
        guard !isNull, !isInfinite else { return 0 }
        return max(0, width) * max(0, height)
    }
}
