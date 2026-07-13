import AppKit
import CoreGraphics
import Foundation

@MainActor
final class RightOptionKeyMonitor {
    private static let rightOptionKeyCode = CGKeyCode(61)

    private let onToggle: () -> Void
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isRightOptionDown = false
    private var previouslyHadGlobalMonitoringAccess = false

    init(onToggle: @escaping () -> Void) {
        self.onToggle = onToggle
    }

    var hasGlobalMonitoringAccess: Bool {
        CGPreflightListenEventAccess()
    }

    @discardableResult
    func requestGlobalMonitoringAccess() -> Bool {
        _ = CGRequestListenEventAccess()
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

        previouslyHadGlobalMonitoringAccess = hasGlobalMonitoringAccess
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
        isRightOptionDown = false
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
        guard event.keyCode == Self.rightOptionKeyCode else { return }

        let isDown = CGEventSource.keyState(
            .combinedSessionState,
            key: Self.rightOptionKeyCode
        )

        if isDown, !isRightOptionDown {
            isRightOptionDown = true
            Telemetry.commands.info("Right Option toggled Listening mode")
            onToggle()
        } else if !isDown {
            isRightOptionDown = false
        }
    }

}
