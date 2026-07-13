import AppKit
import Foundation

@MainActor
enum PrivacySettings {
    static func openMicrophone() {
        open(anchor: "Privacy_Microphone")
    }

    static func openInputMonitoring() {
        open(anchor: "Privacy_ListenEvent")
    }

    static func openAccessibility() {
        open(anchor: "Privacy_Accessibility")
    }

    private static func open(anchor: String) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        ), NSWorkspace.shared.open(url) else {
            Telemetry.interface.error("Could not open Privacy & Security settings")
            return
        }

        Telemetry.interface.info("Opened Privacy & Security settings")
    }
}
