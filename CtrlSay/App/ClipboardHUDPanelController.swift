import AppKit
import CoreGraphics
import Observation
import SwiftUI

@MainActor
final class ClipboardHUDPanelController: NSObject, NSWindowDelegate {
    private let panel: NonactivatingPanel
    private let model: AppModel
    private let presentationState: ClipboardHUDPresentationState
    private let editingSession: ClipboardHUDEditingSession
    private let positionStore: ClipboardHUDPositionStore
    private weak var activeScreen: NSScreen?
    private var isApplyingFrame = false
    private var isLayoutUpdateScheduled = false
    private var wantsToBeShown = false
    private var visibilityAnimationGeneration: UInt64 = 0
    private var editingMouseUpMonitor: Any?

    var isShown: Bool { wantsToBeShown }

    init(
        model: AppModel,
        presentationState: ClipboardHUDPresentationState,
        editingSession: ClipboardHUDEditingSession,
        thumbnailProvider: ClipboardThumbnailProvider,
        positionStore: ClipboardHUDPositionStore = ClipboardHUDPositionStore()
    ) {
        self.model = model
        self.presentationState = presentationState
        self.editingSession = editingSession
        self.positionStore = positionStore

        let initialSize = CGSize(
            width: ClipboardHUDMetrics.width,
            height: ClipboardHUDMetrics.idealHeight(
                itemCount: 0,
                collection: .numbered
            )
        )
        let panel = NonactivatingPanel(
            contentRect: CGRect(origin: .zero, size: initialSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        let rootView = ClipboardHUDView(
            model: model,
            presentationState: presentationState,
            editingSession: editingSession,
            thumbnailProvider: thumbnailProvider
        )
        let hostingController = NSHostingController(rootView: rootView)
        // This controller owns the panel's fixed width and calculated height.
        // Allowing NSHostingController to also derive window constraints from
        // the changing SwiftUI content creates a resize feedback loop during
        // rapid tab and slot changes.
        hostingController.sizingOptions = []
        panel.contentViewController = hostingController
        hostingController.view.autoresizingMask = [.width, .height]

        panel.title = "Ctrl-Say Clipboard HUD"
        panel.setAccessibilityElement(true)
        panel.setAccessibilityRole(.window)
        panel.setAccessibilitySubrole(.floatingWindow)
        panel.setAccessibilityTitle("Ctrl-Say Clipboard HUD")
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        // The HUD intentionally leaves the source app active. AppKit disables
        // help tags for inactive apps by default, including tags supplied by
        // SwiftUI's `.help`, so opt this panel in before its first display.
        panel.allowsToolTipsWhenApplicationIsInactive = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [
            // The current Stage Manager/full-screen behavior intended for
            // floating overlays that accompany every application.
            .canJoinAllApplications,
            .ignoresCycle,
        ]
        panel.animationBehavior = .none
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovable = true
        panel.isMovableByWindowBackground = false

        hostingController.view.wantsLayer = true
        hostingController.view.layer?.backgroundColor = NSColor.clear.cgColor

        self.panel = panel
        super.init()
        panel.delegate = self

        editingSession.onBeginEditing = { [weak self] in
            guard let self else { return }
            self.panel.makeKey()
            self.installEditingMouseUpMonitor()
        }
        editingSession.onEndEditing = { [weak self] in
            guard let self else { return }
            self.removeEditingMouseUpMonitor()
            self.panel.makeFirstResponder(nil)
            self.panel.resignKey()
            if self.panel.isVisible {
                self.panel.orderFrontRegardless()
            }
        }

        observeLayoutInputs()
    }

    func show() {
        guard !wantsToBeShown else { return }
        wantsToBeShown = true
        visibilityAnimationGeneration &+= 1
        let generation = visibilityAnimationGeneration
        let requestedAt =
            model.consumeHUDPresentationRequestTimestamp()
            ?? DispatchTime.now().uptimeNanoseconds
        let wasVisible = panel.isVisible

        if wasVisible {
            activeScreen = activeScreen ?? bestScreenForCurrentFrame()
        } else {
            let screen = pointerScreen()
            activeScreen = screen
            applyInitialFrame(on: screen)
            // Establish the transparent state before the window enters the
            // visible window list so it cannot flash for a compositor frame.
            panel.alphaValue = 0
        }

        #if DEBUG
        let frontmostProcessIdentifier = NSWorkspace.shared.frontmostApplication?
            .processIdentifier
        #endif
        panel.orderFrontRegardless()
        animateVisibility(
            to: 1,
            duration: ClipboardHUDAnimation.fadeInDuration,
            timingFunction: .easeOut,
            generation: generation
        )
        let elapsed =
            Double(
                DispatchTime.now().uptimeNanoseconds - requestedAt
            ) / 1_000_000
        Telemetry.interface.info(
            "HUD presented gesture_to_presentation_ms=\(elapsed, privacy: .public)"
        )
        #if DEBUG
        Task { @MainActor in
            await Task.yield()
            let focusWasPreserved =
                NSWorkspace.shared.frontmostApplication?
                .processIdentifier == frontmostProcessIdentifier
            Telemetry.interface.info(
                "HUD focus_preserved=\(focusWasPreserved, privacy: .public)"
            )
        }
        #endif
    }

    func hide() {
        guard wantsToBeShown else { return }
        wantsToBeShown = false
        visibilityAnimationGeneration &+= 1
        let generation = visibilityAnimationGeneration
        editingSession.prepareForDismissal()

        guard panel.isVisible else {
            panel.alphaValue = 0
            return
        }

        animateVisibility(
            to: 0,
            duration: ClipboardHUDAnimation.fadeOutDuration,
            timingFunction: .easeIn,
            generation: generation,
            orderOutWhenFinished: true
        )
    }

    func screenParametersDidChange() {
        guard panel.isVisible else { return }
        let screen = bestScreenForCurrentFrame()
        activeScreen = screen
        let count = visibleItemCount
        let height = ClipboardHUDMetrics.height(
            itemCount: count,
            collection: presentationState.selectedCollection,
            permanentStatusLayout: permanentStatusLayout,
            showsNumberedFooter: model.slots.hasTemporaryCopies,
            visibleFrame: screen.visibleFrame
        )
        let frame: CGRect
        if let position = positionStore.position(
            for: displayIdentifier(for: screen)
        ) {
            frame = ClipboardHUDPlacement.frame(
                normalizedPosition: position,
                size: CGSize(width: ClipboardHUDMetrics.width, height: height),
                visibleFrame: screen.visibleFrame
            )
        } else {
            frame = ClipboardHUDPlacement.resizedFrame(
                from: panel.frame,
                height: height,
                visibleFrame: screen.visibleFrame
            )
        }
        setFrame(frame)
    }

    func windowDidMove(_ notification: Notification) {
        guard panel.isVisible, !isApplyingFrame else { return }
        let screen = bestScreenForCurrentFrame()
        activeScreen = screen
        let position = ClipboardHUDPlacement.normalizedPosition(
            for: panel.frame,
            visibleFrame: screen.visibleFrame
        )
        positionStore.save(position, for: displayIdentifier(for: screen))
    }

    func windowDidResignKey(_ notification: Notification) {
        guard notification.object as? NSWindow === panel,
            let token = editingSession.activeSessionToken
        else {
            return
        }
        scheduleOutsideInteractionDismissal(for: token)
    }

    private func installEditingMouseUpMonitor() {
        guard editingMouseUpMonitor == nil else { return }
        editingMouseUpMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseUp, .rightMouseUp, .otherMouseUp]
        ) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handleEditingMouseUp(event)
            }
            return event
        }
    }

    private func removeEditingMouseUpMonitor() {
        guard let editingMouseUpMonitor else { return }
        NSEvent.removeMonitor(editingMouseUpMonitor)
        self.editingMouseUpMonitor = nil
    }

    private func handleEditingMouseUp(_ event: NSEvent) {
        guard let token = editingSession.activeSessionToken,
            !eventIsInsideActiveEditor(event)
        else {
            return
        }
        scheduleOutsideInteractionDismissal(for: token)
    }

    private func eventIsInsideActiveEditor(_ event: NSEvent) -> Bool {
        guard event.window === panel,
            let editor = panel.firstResponder as? NSView,
            editor.window === panel
        else {
            return false
        }
        let location = editor.convert(event.locationInWindow, from: nil)
        return editor.visibleRect.contains(location)
    }

    private func scheduleOutsideInteractionDismissal(
        for token: ClipboardHUDEditingSession.Token
    ) {
        Task { @MainActor [weak self] in
            // Let the destination control handle mouse-up first. Save/Cancel
            // can end the session themselves, and starting another rename can
            // replace the captured token before this runs.
            await Task.yield()
            self?.editingSession.prepareForOutsideInteraction(token)
        }
    }

    private func observeLayoutInputs() {
        withObservationTracking {
            _ = model.slots.numbered.count
            _ = model.slots.temporaryNamed.count
            _ = model.slots.named.count
            _ = model.pendingClipboardCopies
            _ = model.permanentStorageState
            _ = presentationState.selectedCollection
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observeLayoutInputs()
                self.scheduleHeightUpdate()
            }
        }
    }

    private func scheduleHeightUpdate() {
        guard !isLayoutUpdateScheduled else { return }
        isLayoutUpdateScheduled = true

        // Observation can publish several related slot and persistence-state
        // mutations in one turn. Resize once with their final values after the
        // current SwiftUI/AppKit transaction instead of re-entering layout for
        // every intermediate state.
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isLayoutUpdateScheduled = false
                self.updateHeightForCurrentContent()
            }
        }
    }

    private func updateHeightForCurrentContent() {
        guard wantsToBeShown, panel.isVisible else { return }
        let screen = activeScreen ?? bestScreenForCurrentFrame()
        activeScreen = screen
        let height = ClipboardHUDMetrics.height(
            itemCount: visibleItemCount,
            collection: presentationState.selectedCollection,
            permanentStatusLayout: permanentStatusLayout,
            showsNumberedFooter: model.slots.hasTemporaryCopies,
            visibleFrame: screen.visibleFrame
        )
        let target = ClipboardHUDPlacement.resizedFrame(
            from: panel.frame,
            height: height,
            visibleFrame: screen.visibleFrame
        )
        setFrame(target, measuresResize: true)
    }

    private func applyInitialFrame(on screen: NSScreen) {
        let height = ClipboardHUDMetrics.height(
            itemCount: visibleItemCount,
            collection: presentationState.selectedCollection,
            permanentStatusLayout: permanentStatusLayout,
            showsNumberedFooter: model.slots.hasTemporaryCopies,
            visibleFrame: screen.visibleFrame
        )
        let size = CGSize(width: ClipboardHUDMetrics.width, height: height)
        let identifier = displayIdentifier(for: screen)
        let frame: CGRect
        if let position = positionStore.position(for: identifier) {
            frame = ClipboardHUDPlacement.frame(
                normalizedPosition: position,
                size: size,
                visibleFrame: screen.visibleFrame
            )
        } else {
            frame = ClipboardHUDPlacement.defaultFrame(
                height: height,
                visibleFrame: screen.visibleFrame
            )
        }
        setFrame(frame)
    }

    private func setFrame(
        _ frame: CGRect,
        measuresResize: Bool = false
    ) {
        guard
            ClipboardHUDPlacement.requiresFrameUpdate(
                current: panel.frame,
                target: frame
            )
        else {
            return
        }

        isApplyingFrame = true
        defer { isApplyingFrame = false }
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let itemCount = visibleItemCount

        // Never animate the NSWindow frame. NSHostingView and its scroll view
        // also participate in layout; overlapping animator-proxy resizes can
        // make each side invalidate the other until AppKit aborts for a layout
        // feedback loop. Visibility still fades through the compositor.
        panel.setFrame(frame, display: false)
        if measuresResize {
            let elapsed =
                Double(
                    DispatchTime.now().uptimeNanoseconds - startedAt
                ) / 1_000_000
            Telemetry.interface.debug(
                "HUD layout item_count=\(itemCount, privacy: .public) resize_ms=\(elapsed, privacy: .public)"
            )
        }
    }

    private func animateVisibility(
        to alpha: CGFloat,
        duration: TimeInterval,
        timingFunction: CAMediaTimingFunctionName,
        generation: UInt64,
        orderOutWhenFinished: Bool = false
    ) {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        NSAnimationContext.runAnimationGroup(
            { context in
                // The animator proxy is compositor-driven and follows the
                // destination display's refresh cadence without a polling
                // timer or an assumed 60 Hz frame rate.
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(
                    name: timingFunction
                )
                panel.animator().alphaValue = alpha
            },
            completionHandler: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self,
                        self.visibilityAnimationGeneration == generation
                    else {
                        return
                    }
                    self.panel.alphaValue = alpha
                    if orderOutWhenFinished, !self.wantsToBeShown {
                        self.panel.orderOut(nil)
                    }

                    let elapsed =
                        Double(
                            DispatchTime.now().uptimeNanoseconds - startedAt
                        ) / 1_000_000
                    Telemetry.interface.debug(
                        "HUD fade target_visible=\(alpha > 0, privacy: .public) duration_ms=\(elapsed, privacy: .public)"
                    )
                }
            }
        )
    }

    private var visibleItemCount: Int {
        switch presentationState.selectedCollection {
        case .numbered:
            let storedDestinations = Set(
                model.slots.numbered.keys.map {
                    PendingClipboardCopy.Destination.numbered($0)
                }
                    + model.slots.temporaryNamed.keys.map {
                        PendingClipboardCopy.Destination.temporaryNamed($0)
                    }
            )
            return model.pendingClipboardCopies.visibleItemCount(
                in: .temporary,
                storedDestinations: storedDestinations
            )
        case .permanent:
            let storedDestinations = Set(
                model.slots.named.keys.map {
                    PendingClipboardCopy.Destination.permanentNamed($0)
                }
            )
            return model.pendingClipboardCopies.visibleItemCount(
                in: .permanent,
                storedDestinations: storedDestinations
            )
        }
    }

    private var permanentStatusLayout: ClipboardHUDPermanentStatusLayout {
        guard presentationState.selectedCollection == .permanent else {
            return .none
        }
        switch model.permanentStorageState {
        case .loading, .loadFailed:
            return .replacesContent
        case .saveFailed:
            return .precedesContent
        case .ready, .saving:
            return .none
        }
    }

    private func pointerScreen() -> NSScreen {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(location) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    private func bestScreenForCurrentFrame() -> NSScreen {
        let frame = panel.frame
        return NSScreen.screens.max { first, second in
            first.frame.intersection(frame).area
                < second.frame.intersection(frame).area
        } ?? activeScreen ?? pointerScreen()
    }

    private func displayIdentifier(for screen: NSScreen) -> String {
        let screenNumberKey = NSDeviceDescriptionKey("NSScreenNumber")
        if let number = screen.deviceDescription[screenNumberKey] as? NSNumber,
            let unmanagedUUID = CGDisplayCreateUUIDFromDisplayID(
                CGDirectDisplayID(number.uint32Value)
            )
        {
            let uuid = unmanagedUUID.takeRetainedValue()
            return CFUUIDCreateString(nil, uuid) as String
        }

        let frame = screen.frame
        return "frame:\(frame.minX):\(frame.minY):\(frame.width):\(frame.height)"
    }
}

private enum ClipboardHUDAnimation {
    static let fadeInDuration: TimeInterval = 0.20
    static let fadeOutDuration: TimeInterval = 0.16
}

extension CGRect {
    fileprivate var area: CGFloat {
        guard !isNull else { return 0 }
        return width * height
    }
}
