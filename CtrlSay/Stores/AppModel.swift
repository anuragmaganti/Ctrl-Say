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

#if DEBUG
    private(set) var debugDiagnostics = DebugPipelineSnapshot()
#endif

    @ObservationIgnored private let clipboard = ClipboardService()
    @ObservationIgnored private var rightOptionMonitor: RightOptionKeyMonitor?
    @ObservationIgnored private var speechCommandGate = SpeechCommandGate()
    @ObservationIgnored private var numberedCommandScanner = StreamingNumberedCommandScanner()
    @ObservationIgnored private var commandQueue = SerialCommandQueueState<QueuedCommand, SpeechCommandIdentity>()
    @ObservationIgnored private var capturedSpeechTargets: [SpeechCommandIdentity: TargetSnapshot] = [:]
    @ObservationIgnored private var desiredListening = false
    @ObservationIgnored private var listeningTransitionTask: Task<Void, Never>?
    @ObservationIgnored private var vocabularyRefreshPending = false
    @ObservationIgnored private var vocabularyRefreshTask: Task<Void, Never>?

    var isReadyForCommands: Bool {
        speech.microphoneAuthorization == .authorized
            && hasKeyboardMonitoringAccess
            && hasEventPostingAccess
    }

    init() {
        hasEventPostingAccess = clipboard.hasEventPostingAccess
        speech.onResult = { [weak self] result in
            self?.received(result)
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
        let canStopActiveTransition = speech.isActive
            || listeningTransitionTask != nil
        guard isReadyForCommands || canStopActiveTransition else {
            lastError = "Complete the three setup permissions before listening."
            lastAction = "Setup required"
            return
        }

        if listeningTransitionTask == nil {
            desiredListening = !speech.isActive
        } else {
            desiredListening.toggle()
            if !desiredListening {
                listeningTransitionTask?.cancel()
            }
        }
        startListeningTransitionIfNeeded()
    }

    func submit(_ command: VoiceCommand) {
        enqueueManual(command)
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

    private func received(_ result: RecognizedSpeechResult) {
        let numberedUpdate = numberedCommandScanner.ingest(
            StreamingNumberedCommandSegment(
                range: SpeechResultRange(result.range),
                tokens: result.tokens,
                finalizationTime: result.finalizationTime,
                isFinal: result.isFinal
            )
        )
        for mutation in numberedUpdate.mutations {
            apply(mutation, from: result)
        }

        let exactCommand = VoiceCommandParser.parse(result.text)
        let gatedCommand: VoiceCommand?
        switch exactCommand {
        case .copyNumber, .pasteNumber:
            // Numbered commands are owned by the timeline scanner. Sending an
            // exact match through both paths would execute final echoes twice.
            gatedCommand = nil
        default:
            gatedCommand = exactCommand
        }
        let acceptsVolatileResult = gatedCommand.map {
            VolatileCommandAcceptancePolicy.accepts(
                $0,
                confidence: result.minimumConfidence,
                knownNamedCopies: slots.named.keys
            )
        } ?? false

#if DEBUG
        let streamedCommand = numberedUpdate.mutations.lazy.compactMap { mutation -> VoiceCommand? in
            guard case .upsert(let candidate) = mutation else { return nil }
            return candidate.command
        }.first
        debugDiagnostics.received(
            result,
            command: streamedCommand ?? exactCommand,
            acceptsVolatileResult: streamedCommand != nil || acceptsVolatileResult
        )
#endif

        let metadata = SpeechCommandMetadata(
            resultReceivedAtNanoseconds: result.receivedAtNanoseconds,
            audioEndUptimeNanoseconds: result.audioEndUptimeNanoseconds,
            minimumConfidence: result.minimumConfidence,
            isFinal: result.isFinal
        )
        let observation = SpeechCommandObservation(
            range: SpeechResultRange(result.range),
            finalizationTime: result.finalizationTime,
            isFinal: result.isFinal,
            command: gatedCommand,
            isPotentialCommand: VoiceCommandParser.isPotentialCommand(result.text),
            acceptsVolatileResult: acceptsVolatileResult,
            metadata: metadata
        )

        let update = speechCommandGate.ingest(observation)
        if update.isNewUtterance {
            capturedSpeechTargets[.gated(update.utteranceID)] = TargetSnapshot(
                target: clipboard.currentCommandTarget()
            )
        }

        for mutation in update.mutations {
            apply(mutation)
        }
        let activeUtteranceIDs = speechCommandGate.activeUtteranceIDs
        capturedSpeechTargets = capturedSpeechTargets.filter {
            switch $0.key {
            case .gated(let utteranceID):
                activeUtteranceIDs.contains(utteranceID)
            case .numbered:
                true
            }
        }
    }

    private func apply(
        _ mutation: StreamingNumberedCommandMutation,
        from result: RecognizedSpeechResult
    ) {
        switch mutation {
        case .upsert(let candidate):
#if DEBUG
            Telemetry.speech.info(
                "Numbered candidate id=\(candidate.id.rawValue, privacy: .public) command=\(candidate.command.telemetryName, privacy: .public) start=\(candidate.range.start.seconds, privacy: .public) end=\(candidate.range.end.seconds, privacy: .public) final=\(result.isFinal, privacy: .public)"
            )
#endif
            let identity = SpeechCommandIdentity.numbered(candidate.id)
            if capturedSpeechTargets[identity] == nil {
                capturedSpeechTargets[identity] = TargetSnapshot(
                    target: clipboard.currentCommandTarget()
                )
            }
            let metadata = SpeechCommandMetadata(
                resultReceivedAtNanoseconds: result.receivedAtNanoseconds,
                audioEndUptimeNanoseconds: result.audioEndUptimeNanoseconds(
                    for: candidate.range
                ),
                minimumConfidence: candidate.minimumConfidence,
                isFinal: result.isFinal
            )
            let queued = QueuedCommand(
                command: candidate.command,
                speechMetadata: metadata,
                target: capturedSpeechTargets[identity]?.target
            )
            let replacedRevision = commandQueue.upsert(
                queued,
                identity: identity,
                enqueuedAtNanoseconds: DispatchTime.now().uptimeNanoseconds
            )
#if DEBUG
            debugDiagnostics.queued(
                depth: commandQueue.count,
                replacedRevision: replacedRevision
            )
#endif
            startCommandWorkerIfNeeded()

        case .revoke(let candidateID):
#if DEBUG
            Telemetry.speech.info(
                "Numbered candidate revoked id=\(candidateID.rawValue, privacy: .public)"
            )
#endif
            let identity = SpeechCommandIdentity.numbered(candidateID)
            capturedSpeechTargets.removeValue(forKey: identity)
            guard commandQueue.revoke(identity: identity) else { return }
#if DEBUG
            debugDiagnostics.revoked(depth: commandQueue.count)
#endif
        }
    }

    private func apply(_ mutation: SpeechCommandMutation) {
        switch mutation {
        case .upsert(let utteranceID, let command, let metadata):
            let identity = SpeechCommandIdentity.gated(utteranceID)
            let queued = QueuedCommand(
                command: command,
                speechMetadata: metadata,
                target: command.requiresExternalTarget
                    ? capturedSpeechTargets[identity]?.target
                    : nil
            )
            let replacedRevision = commandQueue.upsert(
                queued,
                identity: identity,
                enqueuedAtNanoseconds: DispatchTime.now().uptimeNanoseconds
            )
#if DEBUG
            debugDiagnostics.queued(
                depth: commandQueue.count,
                replacedRevision: replacedRevision
            )
#endif
            startCommandWorkerIfNeeded()

        case .revoke(let utteranceID):
            let identity = SpeechCommandIdentity.gated(utteranceID)
            guard commandQueue.revoke(identity: identity) else { return }
#if DEBUG
            debugDiagnostics.revoked(depth: commandQueue.count)
#endif
        }
    }

    private func enqueueManual(_ command: VoiceCommand) {
        let queued = QueuedCommand(
            command: command,
            speechMetadata: nil,
            target: command.requiresExternalTarget ? clipboard.currentCommandTarget() : nil
        )
        commandQueue.upsert(
            queued,
            identity: nil,
            enqueuedAtNanoseconds: DispatchTime.now().uptimeNanoseconds
        )
#if DEBUG
        debugDiagnostics.queued(depth: commandQueue.count, replacedRevision: false)
#endif
        startCommandWorkerIfNeeded()
    }

    private func startCommandWorkerIfNeeded() {
        guard !isProcessingCommand else { return }
        isProcessingCommand = true

        Task { [weak self] in
            await self?.drainCommandQueue()
        }
    }

    private func drainCommandQueue() async {
        while let entry = commandQueue.popFirst() {
            if let identity = entry.identity {
                switch identity {
                case .gated(let utteranceID):
                    speechCommandGate.markCommitted(utteranceID)
                case .numbered(let candidateID):
                    numberedCommandScanner.markCommitted(candidateID)
                }
                capturedSpeechTargets.removeValue(forKey: identity)
            }

            let dequeuedAt = DispatchTime.now().uptimeNanoseconds
            let queueWaitMilliseconds = Double(
                dequeuedAt - entry.enqueuedAtNanoseconds
            ) / 1_000_000
#if DEBUG
            debugDiagnostics.began(
                queueWaitMilliseconds: queueWaitMilliseconds,
                depth: commandQueue.count
            )
#endif
            await execute(
                entry.element,
                queueWaitMilliseconds: queueWaitMilliseconds
            )
        }
        isProcessingCommand = false
    }

    private func execute(
        _ queued: QueuedCommand,
        queueWaitMilliseconds: Double
    ) async {
        let started = DispatchTime.now().uptimeNanoseconds
        lastError = nil
        var clipboardMilliseconds: Double?
        var targetStatus: TargetTelemetryStatus = queued.command.requiresExternalTarget
            ? .notChecked
            : .notRequired

        do {
            switch queued.command {
            case .copyNumber(let number):
                let capture = try await clipboard.captureSelection(target: queued.target)
                slots.set(capture.payload, at: number)
                clipboardMilliseconds = capture.milliseconds
                targetStatus = .verified
                lastAction = "Copied to \(number)"

            case .pasteNumber(let number):
                guard let payload = slots.payload(at: number) else {
                    throw AppModelError.emptyNumberedSlot(number)
                }
                let metrics = try clipboard.paste(payload, target: queued.target)
                clipboardMilliseconds = metrics.milliseconds
                targetStatus = .verified
                lastAction = "Paste sent from \(number)"

            case .saveCurrentClipboard(let number):
                let payload = try clipboard.snapshotCurrentClipboard()
                slots.set(payload, at: number)
                lastAction = "Saved clipboard to \(number)"

            case .permanentCopy(let name):
                let capture = try await clipboard.captureSelection(target: queued.target)
                slots.set(capture.payload, named: name)
                clipboardMilliseconds = capture.milliseconds
                targetStatus = .verified
                scheduleVocabularyRefresh()
                lastAction = "Created permanent copy"

            case .pasteNamed(let name):
                guard let payload = slots.payload(named: name) else {
                    throw AppModelError.missingNamedCopy
                }
                let metrics = try clipboard.paste(payload, target: queued.target)
                clipboardMilliseconds = metrics.milliseconds
                targetStatus = .verified
                lastAction = "Permanent paste sent"

            case .deleteNamed(let name):
                slots.removeNamed(name)
                scheduleVocabularyRefresh()
                lastAction = "Deleted permanent copy"

            case .clearNumbered:
                slots.clearNumbered()
                lastAction = "Cleared numbered copies"
            }

            hasEventPostingAccess = clipboard.hasEventPostingAccess
            let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            recordPipeline(
                queued,
                queueWaitMilliseconds: queueWaitMilliseconds,
                executionMilliseconds: milliseconds,
                clipboardMilliseconds: clipboardMilliseconds,
                targetStatus: targetStatus,
                succeeded: true
            )
            Telemetry.commands.info("\(queued.command.telemetryName, privacy: .public) completed in \(milliseconds, privacy: .public) ms")

#if DEBUG
            if let clipboardMilliseconds {
                debugDiagnostics.recordedClipboardPath(
                    milliseconds: clipboardMilliseconds,
                    targetWasFrontmost: targetStatus == .verified
                )
            }
#endif
        } catch {
            if queued.command.requiresExternalTarget {
                targetStatus = targetFailureStatus(error) ?? targetStatus
            }
            lastError = error.localizedDescription
            lastAction = "Command failed"
            NSSound.beep()
            let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            recordPipeline(
                queued,
                queueWaitMilliseconds: queueWaitMilliseconds,
                executionMilliseconds: milliseconds,
                clipboardMilliseconds: clipboardMilliseconds,
                targetStatus: targetStatus,
                succeeded: false
            )
            Telemetry.commands.error("\(queued.command.telemetryName, privacy: .public) failed: \(error.localizedDescription, privacy: .private)")
#if DEBUG
            if queued.command.requiresExternalTarget {
                debugDiagnostics.targetStatus(targetStatus.debugLabel)
            }
#endif
        }
    }

    private func recordPipeline(
        _ queued: QueuedCommand,
        queueWaitMilliseconds: Double,
        executionMilliseconds: Double,
        clipboardMilliseconds: Double?,
        targetStatus: TargetTelemetryStatus,
        succeeded: Bool
    ) {
        let speechMilliseconds = queued.speechMetadata?.recognitionLatencyMilliseconds ?? -1
        let clipboardMilliseconds = clipboardMilliseconds ?? -1
        Telemetry.performance.info(
            "\(queued.command.telemetryName, privacy: .public) speech_ms=\(speechMilliseconds, privacy: .public) queue_ms=\(queueWaitMilliseconds, privacy: .public) execute_ms=\(executionMilliseconds, privacy: .public) clipboard_ms=\(clipboardMilliseconds, privacy: .public) target_status=\(targetStatus.rawValue, privacy: .public) success=\(succeeded, privacy: .public)"
        )
    }

    private func targetFailureStatus(_ error: Error) -> TargetTelemetryStatus? {
        guard let clipboardError = error as? ClipboardServiceError else {
            return nil
        }

        switch clipboardError {
        case .commandTargetChanged:
            return .changed
        case .commandTargetUnavailable:
            return .unavailable
        case .accessibilityPermissionRequired:
            return .notChecked
        case .clipboardIsEmpty, .copyTimedOut, .unsupportedOrOversizedContent,
             .couldNotWriteClipboard, .couldNotCreateKeyboardEvent:
            return .verified
        }
    }

    private func startListeningTransitionIfNeeded() {
        guard listeningTransitionTask == nil else { return }
        listeningTransitionTask = Task { [weak self] in
            await self?.reconcileListeningState()
        }
    }

    private func reconcileListeningState() async {
        while desiredListening != speech.isListening {
            if desiredListening {
                resetSpeechSessionTracking()
                await speech.start(vocabulary: Array(slots.named.keys))
                if Task.isCancelled {
                    if speech.isActive {
                        await speech.stop()
                    }
                    break
                }
                if !speech.isListening {
                    if desiredListening {
                        desiredListening = false
                    }
                    break
                }
            } else {
                await speech.stop()
                resetSpeechSessionTracking()
            }
        }

        listeningTransitionTask = nil
        if desiredListening != speech.isListening {
            startListeningTransitionIfNeeded()
        }
    }

    private func resetSpeechSessionTracking() {
        speechCommandGate.reset()
        numberedCommandScanner.reset()
        capturedSpeechTargets.removeAll(keepingCapacity: true)
    }

    private func scheduleVocabularyRefresh() {
        vocabularyRefreshPending = true
        guard vocabularyRefreshTask == nil else { return }

        vocabularyRefreshTask = Task { [weak self] in
            await self?.drainVocabularyRefreshes()
        }
    }

    private func drainVocabularyRefreshes() async {
        while vocabularyRefreshPending {
            vocabularyRefreshPending = false
            while let listeningTransitionTask {
                await listeningTransitionTask.value
            }

            guard speech.isListening else { continue }
            let vocabulary = Array(slots.named.keys)
            if !(await speech.updateVocabulary(vocabulary)) {
                try? await Task.sleep(for: .milliseconds(50))
                guard speech.isListening else { continue }
                _ = await speech.updateVocabulary(Array(slots.named.keys))
            }
        }
        vocabularyRefreshTask = nil

        if vocabularyRefreshPending {
            scheduleVocabularyRefresh()
        }
    }
}

private struct QueuedCommand {
    let command: VoiceCommand
    let speechMetadata: SpeechCommandMetadata?
    let target: CommandTarget?
}

private struct TargetSnapshot {
    let target: CommandTarget?
}

private enum SpeechCommandIdentity: Hashable {
    case gated(SpeechUtteranceID)
    case numbered(StreamingNumberedCommandID)
}

private enum TargetTelemetryStatus: String {
    case notRequired = "not_required"
    case notChecked = "not_checked"
    case verified
    case changed
    case unavailable

    var debugLabel: String {
        switch self {
        case .notRequired: "Not required"
        case .notChecked: "Not checked"
        case .verified: "Target verified"
        case .changed: "Target changed"
        case .unavailable: "Target unavailable"
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
