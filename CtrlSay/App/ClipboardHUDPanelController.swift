import AppKit
import CoreGraphics
import Observation
import SwiftUI

@MainActor
final class ClipboardHUDPanelController: NSObject, NSWindowDelegate {
    private let panel: NonactivatingPanel
    private let model: AppModel
    private let presentationState: ClipboardHUDPresentationState
    private let editingSession: DashboardEditingSession
    private let positionStore: ClipboardHUDPositionStore
    private weak var activeScreen: NSScreen?
    private var isApplyingFrame = false
    private var wantsToBeShown = false
    private var visibilityAnimationGeneration: UInt64 = 0

    var isShown: Bool { wantsToBeShown }

    init(
        model: AppModel,
        presentationState: ClipboardHUDPresentationState,
        editingSession: DashboardEditingSession,
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
        panel.contentViewController = hostingController

        panel.title = "Ctrl-Say Clipboard HUD"
        panel.setAccessibilityElement(true)
        panel.setAccessibilityRole(.window)
        panel.setAccessibilitySubrole(.floatingWindow)
        panel.setAccessibilityTitle("Ctrl-Say Clipboard HUD")
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
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

        editingSession.onBeginEditing = { [weak panel] in
            panel?.makeKey()
        }
        editingSession.onEndEditing = { [weak panel] in
            panel?.makeFirstResponder(nil)
            if panel?.isVisible == true {
                panel?.orderFrontRegardless()
            }
        }

        observeLayoutInputs()
    }

    func show() {
        guard !wantsToBeShown else { return }
        wantsToBeShown = true
        visibilityAnimationGeneration &+= 1
        let generation = visibilityAnimationGeneration
        let requestedAt = model.consumeHUDPresentationRequestTimestamp()
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
        let elapsed = Double(
            DispatchTime.now().uptimeNanoseconds - requestedAt
        ) / 1_000_000
        Telemetry.interface.info(
            "HUD presented gesture_to_presentation_ms=\(elapsed, privacy: .public)"
        )
#if DEBUG
        Task { @MainActor in
            await Task.yield()
            let focusWasPreserved = NSWorkspace.shared.frontmostApplication?
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
        setFrame(frame, animated: false)
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

    private func observeLayoutInputs() {
        withObservationTracking {
            _ = model.slots.numbered.count
            _ = model.slots.temporaryNamed.count
            _ = model.slots.named.count
            _ = model.permanentStorageState
            _ = presentationState.selectedCollection
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.updateHeightForCurrentContent()
                self.observeLayoutInputs()
            }
        }
    }

    private func updateHeightForCurrentContent() {
        guard panel.isVisible else { return }
        let screen = activeScreen ?? bestScreenForCurrentFrame()
        activeScreen = screen
        let height = ClipboardHUDMetrics.height(
            itemCount: visibleItemCount,
            collection: presentationState.selectedCollection,
            permanentStatusLayout: permanentStatusLayout,
            visibleFrame: screen.visibleFrame
        )
        let target = ClipboardHUDPlacement.resizedFrame(
            from: panel.frame,
            height: height,
            visibleFrame: screen.visibleFrame
        )
        setFrame(target, animated: true, measuresResize: true)
    }

    private func applyInitialFrame(on screen: NSScreen) {
        let height = ClipboardHUDMetrics.height(
            itemCount: visibleItemCount,
            collection: presentationState.selectedCollection,
            permanentStatusLayout: permanentStatusLayout,
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
        setFrame(frame, animated: false)
    }

    private func setFrame(
        _ frame: CGRect,
        animated: Bool,
        measuresResize: Bool = false
    ) {
        isApplyingFrame = true
        defer { isApplyingFrame = false }
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let itemCount = visibleItemCount
        let shouldAnimate = animated
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if shouldAnimate {
            NSAnimationContext.runAnimationGroup(
                { context in
                    context.duration = 0.18
                    context.timingFunction = CAMediaTimingFunction(
                        name: .easeInEaseOut
                    )
                    panel.animator().setFrame(frame, display: true)
                },
                completionHandler: {
                    guard measuresResize else { return }
                    let elapsed = Double(
                        DispatchTime.now().uptimeNanoseconds - startedAt
                    ) / 1_000_000
                    Telemetry.interface.debug(
                        "HUD layout item_count=\(itemCount, privacy: .public) resize_ms=\(elapsed, privacy: .public)"
                    )
                }
            )
        } else {
            panel.setFrame(frame, display: true)
            if measuresResize {
                let elapsed = Double(
                    DispatchTime.now().uptimeNanoseconds - startedAt
                ) / 1_000_000
                Telemetry.interface.debug(
                    "HUD layout item_count=\(itemCount, privacy: .public) resize_ms=\(elapsed, privacy: .public)"
                )
            }
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
                          self.visibilityAnimationGeneration == generation else {
                        return
                    }
                    self.panel.alphaValue = alpha
                    if orderOutWhenFinished, !self.wantsToBeShown {
                        self.panel.orderOut(nil)
                    }

                    let elapsed = Double(
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
            model.slots.temporaryCopyCount
        case .permanent:
            model.slots.named.count
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
           ) {
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

private extension CGRect {
    var area: CGFloat {
        guard !isNull else { return 0 }
        return width * height
    }
}
