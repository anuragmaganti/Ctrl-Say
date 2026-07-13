import AppKit
import CoreGraphics
import Foundation

@MainActor
final class RightOptionKeyMonitor {
    private let pressClassifier: RightOptionPressClassifier
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var previouslyHadGlobalMonitoringAccess = false

    init(onGesture: @escaping (RightOptionGesture) -> Void) {
        pressClassifier = RightOptionPressClassifier(onGesture: onGesture)
    }

    var hasGlobalMonitoringAccess: Bool {
        CGPreflightListenEventAccess()
    }

    @discardableResult
    func requestGlobalMonitoringAccess() -> Bool {
        let granted = CGRequestListenEventAccess()
        if !granted {
            PrivacySettings.openInputMonitoring()
        }
        return refreshGlobalMonitoringAccess()
    }

    @discardableResult
    func refreshGlobalMonitoringAccess() -> Bool {
        let hasAccess = hasGlobalMonitoringAccess
        if hasAccess, !previouslyHadGlobalMonitoringAccess {
            reinstallGlobalMonitor()
        }
        previouslyHadGlobalMonitoringAccess = hasAccess
        return hasAccess
    }

    func start() {
        if globalMonitor == nil {
            installGlobalMonitor()
        }

        if localMonitor == nil {
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                self?.handle(event)
                return event
            }
        }

        let hasAccess = hasGlobalMonitoringAccess
        previouslyHadGlobalMonitoringAccess = hasAccess
        Telemetry.commands.info(
            "Right Option monitor started; Input Monitoring access: \(hasAccess, privacy: .public)"
        )
    }

    func stop() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        pressClassifier.reset()
    }

    private func installGlobalMonitor() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(event)
        }
    }

    private func reinstallGlobalMonitor() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        installGlobalMonitor()
    }

    private func handle(_ event: NSEvent) {
        guard RightOptionEventFilter.recognizes(keyCode: event.keyCode) else {
            return
        }

        // flagsChanged already contains the modifier transition. A separate
        // global key-state query can lag the event on some keyboards.
        let isDown = event.modifierFlags.contains(.option)

        pressClassifier.process(isDown: isDown)
    }

}
