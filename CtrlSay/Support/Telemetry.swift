import Foundation
import OSLog

nonisolated enum Telemetry {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.anuragmaganti.CtrlSay"

    static let commands = Logger(subsystem: subsystem, category: "Commands")
    static let clipboard = Logger(subsystem: subsystem, category: "Clipboard")
    static let speech = Logger(subsystem: subsystem, category: "Speech")
    static let interface = Logger(subsystem: subsystem, category: "Interface")
    static let performance = Logger(subsystem: subsystem, category: "Performance")
    static let persistence = Logger(subsystem: subsystem, category: "Persistence")
}
