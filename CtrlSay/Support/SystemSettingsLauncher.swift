import AppKit

@MainActor
enum SystemSettingsLauncher {
    private static let bundleIdentifier = "com.apple.systempreferences"

    static func open() {
        let workspace = NSWorkspace.shared
        guard
            let applicationURL = workspace.urlForApplication(
                withBundleIdentifier: bundleIdentifier
            )
        else {
            Telemetry.interface.error("Could not locate System Settings")
            return
        }

        workspace.openApplication(
            at: applicationURL,
            configuration: NSWorkspace.OpenConfiguration()
        ) { _, error in
            if error == nil {
                Telemetry.interface.info("Opened System Settings")
            } else {
                Telemetry.interface.error("Could not open System Settings")
            }
        }
    }
}
