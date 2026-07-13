import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    let slots = ClipboardStore()
    let speech = SpeechRecognitionService()

    private(set) var lastAction = "Ready"
    private(set) var lastError: String?
    private(set) var isProcessingCommand = false
    private(set) var hasEventPostingAccess = false
    private(set) var hasKeyboardMonitoringAccess = false

    @ObservationIgnored private let clipboard = ClipboardService()
    @ObservationIgnored private var rightOptionMonitor: RightOptionKeyMonitor?
    @ObservationIgnored private var pendingCommands: [VoiceCommand] = []
    @ObservationIgnored private var lastCommand: VoiceCommand?
    @ObservationIgnored private var lastCommandTime = ContinuousClock().now

    var isReadyForCommands: Bool {
        speech.microphoneAuthorization == .authorized
            && hasKeyboardMonitoringAccess
            && hasEventPostingAccess
    }

    init() {
        hasEventPostingAccess = clipboard.hasEventPostingAccess
        speech.onTranscript = { [weak self] transcript, isFinal in
            self?.received(transcript: transcript, isFinal: isFinal)
        }

        let monitor = RightOptionKeyMonitor { [weak self] in
            self?.toggleListening()
        }
        rightOptionMonitor = monitor
        hasKeyboardMonitoringAccess = monitor.hasGlobalMonitoringAccess
        monitor.start()
    }

    func toggleListening() {
        refreshPermissions()
        guard isReadyForCommands else {
            lastError = "Complete the three setup permissions before listening."
            lastAction = "Setup required"
            return
        }

        Task {
            if speech.isListening {
                await speech.stop()
            } else {
                await speech.start(vocabulary: Array(slots.named.keys))
            }
        }
    }

    func submit(_ command: VoiceCommand) {
        enqueue(command)
    }

    func requestEventPostingAccess() {
        hasEventPostingAccess = clipboard.requestEventPostingAccess()
    }

    func requestMicrophoneAccess() {
        Task {
            let granted = await speech.requestMicrophoneAccess()
            if !granted {
                PrivacySettings.openMicrophone()
            }
        }
    }

    func requestKeyboardMonitoringAccess() {
        hasKeyboardMonitoringAccess = rightOptionMonitor?.requestGlobalMonitoringAccess() == true
    }

    func refreshPermissions() {
        speech.refreshMicrophoneAuthorization()
        hasEventPostingAccess = clipboard.hasEventPostingAccess
        hasKeyboardMonitoringAccess = rightOptionMonitor?.refreshGlobalMonitoringAccess() == true
    }

    private func received(transcript: String, isFinal: Bool) {
        guard let command = VoiceCommandParser.parse(transcript) else { return }
        guard shouldExecute(command, fromFinalResult: isFinal) else { return }

        let clock = ContinuousClock()
        if command == lastCommand, lastCommandTime.duration(to: clock.now) < .seconds(1) {
            return
        }

        // Exact grammar matches can execute from Apple's fast volatile results.
        // Final results are deduplicated by the short command window above.
        lastCommand = command
        lastCommandTime = clock.now
        enqueue(command)
    }

    private func shouldExecute(_ command: VoiceCommand, fromFinalResult isFinal: Bool) -> Bool {
        switch command {
        case .permanentCopy, .deleteNamed:
            // A new arbitrary name has no known word boundary, so wait until
            // SpeechTranscriber finalizes it instead of creating a prefix name.
            return isFinal
        case .pasteNamed(let name):
            let normalizedName = VoiceCommandParser.normalizeName(name)
            guard slots.named[normalizedName] != nil else {
                return isFinal
            }

            // Known unambiguous names are safe to execute from fast volatile
            // results. If another name extends this one, wait for finalization.
            let hasLongerPrefixMatch = slots.named.keys.contains {
                $0.hasPrefix(normalizedName + " ")
            }
            return isFinal || !hasLongerPrefixMatch
        case .copyNumber, .pasteNumber, .saveCurrentClipboard, .clearNumbered:
            return true
        }
    }

    private func enqueue(_ command: VoiceCommand) {
        pendingCommands.append(command)
        guard !isProcessingCommand else { return }
        isProcessingCommand = true

        Task {
            while !pendingCommands.isEmpty {
                let next = pendingCommands.removeFirst()
                await execute(next)
            }
            isProcessingCommand = false
        }
    }

    private func execute(_ command: VoiceCommand) async {
        let started = DispatchTime.now().uptimeNanoseconds
        lastError = nil

        do {
            switch command {
            case .copyNumber(let number):
                let payload = try await clipboard.captureSelection()
                slots.set(payload, at: number)
                lastAction = "Copied to \(number)"

            case .pasteNumber(let number):
                guard let payload = slots.payload(at: number) else {
                    throw AppModelError.emptyNumberedSlot(number)
                }
                try clipboard.paste(payload)
                lastAction = "Pasted \(number)"

            case .saveCurrentClipboard(let number):
                let payload = try clipboard.snapshotCurrentClipboard()
                slots.set(payload, at: number)
                lastAction = "Saved clipboard to \(number)"

            case .permanentCopy(let name):
                let payload = try await clipboard.captureSelection()
                slots.set(payload, named: name)
                await speech.updateVocabulary(Array(slots.named.keys))
                lastAction = "Created permanent copy"

            case .pasteNamed(let name):
                guard let payload = slots.payload(named: name) else {
                    throw AppModelError.missingNamedCopy
                }
                try clipboard.paste(payload)
                lastAction = "Pasted permanent copy"

            case .deleteNamed(let name):
                slots.removeNamed(name)
                await speech.updateVocabulary(Array(slots.named.keys))
                lastAction = "Deleted permanent copy"

            case .clearNumbered:
                slots.clearNumbered()
                lastAction = "Cleared numbered copies"
            }

            hasEventPostingAccess = clipboard.hasEventPostingAccess
            let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            Telemetry.commands.info("\(command.telemetryName, privacy: .public) completed in \(milliseconds, privacy: .public) ms")
        } catch {
            lastError = error.localizedDescription
            lastAction = "Command failed"
            NSSound.beep()
            Telemetry.commands.error("\(command.telemetryName, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

enum AppModelError: LocalizedError {
    case emptyNumberedSlot(Int)
    case missingNamedCopy

    var errorDescription: String? {
        switch self {
        case .emptyNumberedSlot(let number):
            "Nothing has been copied to slot \(number)."
        case .missingNamedCopy:
            "That permanent copy does not exist."
        }
    }
}
