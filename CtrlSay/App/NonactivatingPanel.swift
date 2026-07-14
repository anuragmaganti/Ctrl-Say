import AppKit

/// AppKit's narrow window-level bridge for SwiftUI surfaces that must remain
/// nonactivating during ordinary use but temporarily accept inline editing.
final class NonactivatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
