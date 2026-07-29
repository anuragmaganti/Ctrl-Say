import AppKit
import CoreGraphics
import Observation
import SwiftUI

@MainActor
@Observable
final class NotchWindowContext {
    private(set) var surfaceGeometry = NotchSurfaceGeometry(
        notchWidth: 152,
        notchHeight: 30
    )

    func update(surfaceGeometry: NotchSurfaceGeometry) {
        guard self.surfaceGeometry != surfaceGeometry else { return }
        self.surfaceGeometry = surfaceGeometry
    }
}

@MainActor
final class NotchFeedbackPanelController {
    private let panel: NonactivatingPanel
    private let presentationState: NotchFeedbackPresentationState
    private let windowContext = NotchWindowContext()
    private var delayedHideTask: Task<Void, Never>?
    private var isPresentationUpdateScheduled = false

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
            // The current Stage Manager/full-screen behavior intended for
            // floating overlays that accompany every application.
            .canJoinAllApplications,
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
        // Reevaluate even while hidden. Listening may remain active while the
        // built-in display becomes or stops being the eligible primary screen.
        updatePresentation(animated: false)
    }

    private func observePresentation() {
        withObservationTracking {
            _ = presentationState.visualState
            _ = presentationState.interactionMode
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observePresentation()
                self.schedulePresentationUpdate()
            }
        }
        updatePresentation(animated: false)
    }

    private func schedulePresentationUpdate() {
        guard !isPresentationUpdateScheduled else { return }
        isPresentationUpdateScheduled = true

        // One reducer event can change both the visual and interaction state.
        // Apply their final values after the current SwiftUI/AppKit transaction
        // instead of resizing the panel once for every intermediate publish.
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isPresentationUpdateScheduled = false
                self.updatePresentation(animated: true)
            }
        }
    }

    private func updatePresentation(animated: Bool) {
        let visualState = presentationState.visualState
        panel.ignoresMouseEvents = !presentationState
            .interactionMode
            .acceptsPointerEvents

        guard let display = eligiblePrimaryNotchedDisplay() else {
            delayedHideTask?.cancel()
            delayedHideTask = nil
            panel.orderOut(nil)
            return
        }

        if visualState.isVisible {
            delayedHideTask?.cancel()
            delayedHideTask = nil
            let wasVisible = panel.isVisible
            applyLayout(
                display: display,
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
            let milliseconds =
                Double(
                    DispatchTime.now().uptimeNanoseconds - startedAt
                ) / 1_000_000
            Telemetry.interface.debug(
                "Notch presented duration_ms=\(milliseconds, privacy: .public)"
            )
            #if DEBUG
            Task { @MainActor in
                await Task.yield()
                let focusWasPreserved =
                    NSWorkspace.shared
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
        let shouldAnimate =
            animated
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        applyLayout(
            display: display,
            visualState: .hidden
        )
        delayedHideTask?.cancel()
        guard shouldAnimate else {
            panel.orderOut(nil)
            return
        }

        delayedHideTask = Task { [weak self] in
            do {
                // Keep the transparent panel alive through the view's
                // 380-millisecond collapse. The panel itself stays fixed;
                // only the compositor-backed SwiftUI surface animates.
                try await Task.sleep(for: .milliseconds(400))
            } catch {
                return
            }
            guard !Task.isCancelled,
                let self,
                !self.presentationState.visualState.isVisible
            else {
                return
            }
            self.panel.orderOut(nil)
            self.delayedHideTask = nil
        }
    }

    private func applyLayout(
        display: NotchDisplayGeometry,
        visualState: NotchVisualState
    ) {
        guard
            let layout = NotchPanelLayoutCalculator.layout(
                visualState: visualState,
                interactionMode: presentationState.interactionMode,
                display: display
            )
        else {
            panel.orderOut(nil)
            return
        }
        windowContext.update(surfaceGeometry: layout.surfaceGeometry)
        guard
            NotchPanelLayoutCalculator.requiresFrameUpdate(
                current: panel.frame,
                target: layout.frame
            )
        else {
            return
        }
        // SwiftUI owns the visual transition inside a stable transparent
        // canvas. This frame changes only for display or interaction-mode
        // changes, not for ordinary copy/paste feedback.
        panel.setFrame(layout.frame, display: false)
    }

    private func eligiblePrimaryNotchedDisplay() -> NotchDisplayGeometry? {
        // Apple defines screens[0] as the system's primary display. NSScreen.main
        // instead follows keyboard focus and may therefore be an external screen.
        guard let screen = NSScreen.screens.first,
            let displayID = directDisplayID(for: screen)
        else {
            return nil
        }
        let isEligibleHardware = NotchDisplayEligibility.allowsPresentation(
            isPrimary: displayID == CGMainDisplayID(),
            isBuiltIn: CGDisplayIsBuiltin(displayID) != 0,
            // Suppress the panel while mirroring or casting so the physical
            // notch feedback is never duplicated onto another display.
            isMirrored: CGDisplayIsInMirrorSet(displayID) != 0
        )
        guard isEligibleHardware else { return nil }

        let display = NotchDisplayGeometry(
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            safeAreaTop: screen.safeAreaInsets.top,
            auxiliaryTopLeftArea: screen.auxiliaryTopLeftArea,
            auxiliaryTopRightArea: screen.auxiliaryTopRightArea
        )
        guard NotchPanelLayoutCalculator.surfaceGeometry(for: display) != nil else {
            return nil
        }
        return display
    }

    private func directDisplayID(for screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let number = screen.deviceDescription[key] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(number.uint32Value)
    }
}
