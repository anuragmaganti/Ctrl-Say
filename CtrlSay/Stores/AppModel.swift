import AppKit
import CoreMedia
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
    private(set) var isClipboardHUDPresented = false

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
    @ObservationIgnored private var hudPresentationRequestedAtNanoseconds: UInt64?
    @ObservationIgnored private var pendingHUDRowAppearance: (
        payloadID: UUID,
        storedAtNanoseconds: UInt64
    )?

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
        speech.onFinalizationTimeChanged = { [weak self] finalizationTime in
            self?.receivedFinalizationTime(finalizationTime)
        }

        let monitor = RightOptionKeyMonitor { [weak self] gesture in
            self?.handleRightOptionGesture(gesture)
        }
        rightOptionMonitor = monitor
        hasKeyboardMonitoringAccess = monitor.hasGlobalMonitoringAccess
        monitor.start()
    }

    func toggleListening() {
        _ = setListeningDesired(!currentListeningIntent)
    }

    func setClipboardHUDPresented(_ isPresented: Bool) {
        if isPresented, !isClipboardHUDPresented {
            hudPresentationRequestedAtNanoseconds = DispatchTime.now().uptimeNanoseconds
        }
        isClipboardHUDPresented = isPresented
    }

    func handleRightOptionGesture(_ gesture: RightOptionGesture) {
        let current = RightOptionInteractionState(
            wantsListening: currentListeningIntent,
            isHUDPresented: isClipboardHUDPresented
        )
        let next = RightOptionInteractionReducer.reduce(
            current,
            gesture: gesture,
            showsHUDWhenListeningStarts: showsHUDWhenRightOptionStartsListening
        )

        if next.isHUDPresented, !current.isHUDPresented {
            hudPresentationRequestedAtNanoseconds = DispatchTime.now().uptimeNanoseconds
        }
        isClipboardHUDPresented = next.isHUDPresented
        if next.wantsListening != current.wantsListening {
            _ = setListeningDesired(next.wantsListening)
        }

        Telemetry.commands.info(
            "Right Option gesture=\(gesture == .tap ? "tap" : "hold", privacy: .public) listening_requested=\(next.wantsListening, privacy: .public) hud=\(next.isHUDPresented, privacy: .public)"
        )
    }

    func submit(_ command: VoiceCommand) {
        enqueueManual(command)
    }

    func pasteNumberedCopy(_ payload: ClipboardPayload) {
        enqueueDashboard(
            .pasteTemporary(payload: payload),
            target: clipboard.currentCommandTarget()
        )
    }

    func pasteTemporaryNamedCopy(_ payload: ClipboardPayload) {
        enqueueDashboard(
            .pasteTemporary(payload: payload),
            target: clipboard.currentCommandTarget()
        )
    }

    func deleteNumberedCopy(_ number: Int) {
        guard slots.removeNumbered(number) != nil else { return }
        lastError = nil
        lastAction = "Deleted copy \(number)"
    }

    func deleteTemporaryNamedCopy(_ name: String) {
        guard slots.removeTemporaryNamed(name) != nil else { return }
        scheduleVocabularyRefresh()
        lastError = nil
        lastAction = "Deleted temporary copy"
    }

    func clearTemporaryCopies() {
        guard slots.hasTemporaryCopies else { return }
        slots.clearTemporary()
        scheduleVocabularyRefresh()
        lastError = nil
        lastAction = "Cleared temporary copies"
    }

    func consumeHUDPresentationRequestTimestamp() -> UInt64? {
        defer { hudPresentationRequestedAtNanoseconds = nil }
        return hudPresentationRequestedAtNanoseconds
    }

    func recordHUDRowAppearance(for payloadID: UUID) {
        guard let pendingHUDRowAppearance,
              pendingHUDRowAppearance.payloadID == payloadID else {
            return
        }
        self.pendingHUDRowAppearance = nil
        let milliseconds = Double(
            DispatchTime.now().uptimeNanoseconds
                - pendingHUDRowAppearance.storedAtNanoseconds
        ) / 1_000_000
        Telemetry.interface.debug(
            "HUD row appeared store_to_row_ms=\(milliseconds, privacy: .public)"
        )
    }

    func pastePermanentCopy(_ payloadID: UUID) {
        guard let name = slots.name(forPayloadID: payloadID),
              let payload = slots.payload(named: name) else {
            return
        }
        enqueueDashboard(
            .pastePermanent(payload: payload),
            target: clipboard.currentCommandTarget()
        )
    }

    func deletePermanentCopy(_ payloadID: UUID) {
        guard let name = slots.name(forPayloadID: payloadID),
              slots.removeNamed(name) != nil else {
            return
        }
        scheduleVocabularyRefresh()
        lastError = nil
        lastAction = "Deleted permanent copy"
    }

    @discardableResult
    func renamePermanentCopy(
        _ payloadID: UUID,
        to requestedName: String
    ) throws -> String {
        guard let currentName = slots.name(forPayloadID: payloadID) else {
            throw ClipboardStoreError.missingPermanentCopy
        }
        let validation = try slots.validateRenameNamed(
            from: currentName,
            to: requestedName
        )
        guard validation.payloadID == payloadID else {
            throw ClipboardStoreError.permanentCopyChanged
        }
        let normalizedName = try slots.renameNamed(
            from: currentName,
            to: validation.normalizedName,
            expectedPayloadID: payloadID
        )
        scheduleVocabularyRefresh()
        lastError = nil
        lastAction = "Renamed permanent copy"
        return normalizedName
    }

    func updatePermanentCopyText(_ payloadID: UUID, text: String) throws {
        guard let name = slots.name(forPayloadID: payloadID) else {
            throw ClipboardStoreError.missingPermanentCopy
        }
        try slots.replaceNamedText(
            named: name,
            text: text,
            expectedPayloadID: payloadID
        )
        lastError = nil
        lastAction = "Updated permanent copy"
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

    private var currentListeningIntent: Bool {
        if listeningTransitionTask != nil {
            return desiredListening
        }
        return speech.isActive
    }

    private var showsHUDWhenRightOptionStartsListening: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(
            forKey: CtrlSayPreferenceKey.showHUDWhenRightOptionStartsListening
        ) != nil else {
            return true
        }
        return defaults.bool(
            forKey: CtrlSayPreferenceKey.showHUDWhenRightOptionStartsListening
        )
    }

    @discardableResult
    private func setListeningDesired(_ shouldListen: Bool) -> Bool {
        refreshPermissions()
        let canStopActiveTransition = speech.isActive
            || listeningTransitionTask != nil
        guard !shouldListen || isReadyForCommands || canStopActiveTransition else {
            lastError = "Complete the three setup permissions before listening."
            lastAction = "Setup required"
            return false
        }

        desiredListening = shouldListen
        if !shouldListen {
            listeningTransitionTask?.cancel()
        }
        startListeningTransitionIfNeeded()
        return true
    }

    private func received(_ result: RecognizedSpeechResult) {
        let numberedUpdate = numberedCommandScanner.ingest(
            StreamingNumberedCommandSegment(
                range: SpeechResultRange(result.range),
                tokens: result.tokens,
                finalizationTime: result.finalizationTime,
                isFinal: result.isFinal
            ),
            knownNamedCopies: slots.allNamedKeys
        )
        for mutation in numberedUpdate.mutations {
            apply(mutation, from: result)
        }

        let exactCommand = VoiceCommandParser.parse(result.text)
        let gatedCommand: VoiceCommand?
        switch exactCommand {
        case .copyNumber, .pasteNumber, .copyNamed:
            // Fast two-token commands are owned by the timeline scanner.
            // Sending an exact match through both paths would execute final
            // echoes twice.
            gatedCommand = nil
        case .pasteNamed(let name) where !name.contains(" "):
            gatedCommand = nil
        default:
            gatedCommand = exactCommand
        }
        let acceptsVolatileResult = gatedCommand.map {
            VolatileCommandAcceptancePolicy.accepts(
                $0,
                confidence: result.minimumConfidence,
                knownNamedCopies: slots.allNamedKeys
            )
        } ?? false

#if DEBUG
        let streamedCandidate = numberedUpdate.mutations.lazy.compactMap {
            mutation -> StreamingNumberedCommandCandidate? in
            guard case .upsert(let candidate) = mutation else { return nil }
            return candidate
        }.first
        debugDiagnostics.received(
            result,
            command: streamedCandidate?.command ?? exactCommand,
            acceptsVolatileResult: streamedCandidate?.isReadyForDispatch == true
                || acceptsVolatileResult
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

    private func receivedFinalizationTime(_ finalizationTime: CMTime) {
        let update = numberedCommandScanner.advanceFinalization(
            to: finalizationTime,
            knownNamedCopies: slots.allNamedKeys
        )
        let receivedAtNanoseconds = DispatchTime.now().uptimeNanoseconds
        for mutation in update.mutations {
            apply(
                mutation,
                resultReceivedAtNanoseconds: receivedAtNanoseconds,
                audioEndUptimeNanoseconds: { [speech] range in
                    speech.audioEndUptimeNanoseconds(for: range)
                },
                resultIsFinal: true
            )
        }
    }

    private func apply(
        _ mutation: StreamingNumberedCommandMutation,
        from result: RecognizedSpeechResult
    ) {
        apply(
            mutation,
            resultReceivedAtNanoseconds: result.receivedAtNanoseconds,
            audioEndUptimeNanoseconds: { range in
                result.audioEndUptimeNanoseconds(for: range)
            },
            resultIsFinal: result.isFinal
        )
    }

    private func apply(
        _ mutation: StreamingNumberedCommandMutation,
        resultReceivedAtNanoseconds: UInt64,
        audioEndUptimeNanoseconds: ((SpeechResultRange) -> UInt64?)?,
        resultIsFinal: Bool
    ) {
        switch mutation {
        case .upsert(let candidate):
#if DEBUG
            Telemetry.speech.info(
                "Streaming candidate id=\(candidate.id.rawValue, privacy: .public) command=\(candidate.command.telemetryName, privacy: .public) ready=\(candidate.isReadyForDispatch, privacy: .public) start=\(candidate.range.start.seconds, privacy: .public) end=\(candidate.range.end.seconds, privacy: .public) final=\(resultIsFinal, privacy: .public)"
            )
#endif
            let identity = SpeechCommandIdentity.numbered(candidate.id)
            if capturedSpeechTargets[identity] == nil {
                capturedSpeechTargets[identity] = TargetSnapshot(
                    target: clipboard.currentCommandTarget()
                )
            }
            guard candidate.isReadyForDispatch else {
                // Keep the target snapshot while Apple's volatile named token
                // remains revisable, but do not expose it to the side-effecting
                // command worker yet.
                if commandQueue.revoke(identity: identity) {
#if DEBUG
                    debugDiagnostics.revoked(depth: commandQueue.count)
#endif
                }
                return
            }
            let metadata = SpeechCommandMetadata(
                resultReceivedAtNanoseconds: resultReceivedAtNanoseconds,
                audioEndUptimeNanoseconds: audioEndUptimeNanoseconds?(
                    candidate.range
                ),
                minimumConfidence: candidate.minimumConfidence,
                isFinal: resultIsFinal
            )
            let queued = QueuedCommand(
                operation: .voice(candidate.command),
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
                "Streaming candidate revoked id=\(candidateID.rawValue, privacy: .public)"
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
                operation: .voice(command),
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
            operation: .voice(command),
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

    private func enqueueDashboard(
        _ operation: QueuedOperation,
        target: CommandTarget? = nil
    ) {
        commandQueue.upsert(
            QueuedCommand(
                operation: operation,
                speechMetadata: nil,
                target: target
            ),
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
        var targetStatus: TargetTelemetryStatus = queued.operation.requiresExternalTarget
            ? .notChecked
            : .notRequired

        do {
            switch queued.operation {
            case .voice(let command):
                switch command {
                case .copyNumber(let number):
                    let capture = try await clipboard.captureSelection(target: queued.target)
                    try slots.set(capture.payload, at: number)
                    markHUDStoreUpdate(for: capture.payload.id)
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

                case .copyNamed(let name):
                    let normalizedName = try slots.validateTemporaryNameAvailable(
                        name
                    )
                    let capture = try await clipboard.captureSelection(
                        target: queued.target
                    )
                    try slots.setTemporaryNamed(
                        capture.payload,
                        named: normalizedName
                    )
                    markHUDStoreUpdate(for: capture.payload.id)
                    clipboardMilliseconds = capture.milliseconds
                    targetStatus = .verified
                    scheduleVocabularyRefresh()
                    lastAction = "Copied to \(normalizedName)"

                case .saveCurrentClipboard(let number):
                    let payload = try clipboard.snapshotCurrentClipboard()
                    try slots.set(payload, at: number)
                    markHUDStoreUpdate(for: payload.id)
                    lastAction = "Saved clipboard to \(number)"

                case .permanentCopy(let name):
                    let capture = try await clipboard.captureSelection(target: queued.target)
                    try slots.set(capture.payload, named: name)
                    markHUDStoreUpdate(for: capture.payload.id)
                    clipboardMilliseconds = capture.milliseconds
                    targetStatus = .verified
                    scheduleVocabularyRefresh()
                    lastAction = "Created permanent copy"

                case .pasteNamed(let name):
                    guard let payload = slots.payload(resolvingNamed: name) else {
                        throw AppModelError.missingNamedCopy
                    }
                    let metrics = try clipboard.paste(payload, target: queued.target)
                    clipboardMilliseconds = metrics.milliseconds
                    targetStatus = .verified
                    lastAction = "Named paste sent"

                case .deleteNamed(let name):
                    _ = removePermanentCopy(named: name)
                    lastAction = "Deleted permanent copy"

                case .clearNumbered:
                    slots.clearTemporary()
                    scheduleVocabularyRefresh()
                    lastAction = "Cleared temporary copies"
                }

            case .pasteTemporary(let payload):
                let metrics = try clipboard.paste(payload, target: queued.target)
                clipboardMilliseconds = metrics.milliseconds
                targetStatus = .verified
                lastAction = "Temporary paste sent"

            case .pastePermanent(let payload):
                let metrics = try clipboard.paste(payload, target: queued.target)
                clipboardMilliseconds = metrics.milliseconds
                targetStatus = .verified
                lastAction = "Permanent paste sent"
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
            Telemetry.commands.info("\(queued.operation.telemetryName, privacy: .public) completed in \(milliseconds, privacy: .public) ms")

#if DEBUG
            if let clipboardMilliseconds {
                debugDiagnostics.recordedClipboardPath(
                    milliseconds: clipboardMilliseconds,
                    targetWasFrontmost: targetStatus == .verified
                )
            }
#endif
        } catch {
            if queued.operation.requiresExternalTarget {
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
            Telemetry.commands.error("\(queued.operation.telemetryName, privacy: .public) failed: \(error.localizedDescription, privacy: .private)")
#if DEBUG
            if queued.operation.requiresExternalTarget {
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
            "\(queued.operation.telemetryName, privacy: .public) speech_ms=\(speechMilliseconds, privacy: .public) queue_ms=\(queueWaitMilliseconds, privacy: .public) execute_ms=\(executionMilliseconds, privacy: .public) clipboard_ms=\(clipboardMilliseconds, privacy: .public) target_status=\(targetStatus.rawValue, privacy: .public) success=\(succeeded, privacy: .public)"
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
                await speech.start(vocabulary: Array(slots.allNamedKeys))
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

    private func markHUDStoreUpdate(for payloadID: UUID) {
        guard isClipboardHUDPresented else { return }
        pendingHUDRowAppearance = (
            payloadID,
            DispatchTime.now().uptimeNanoseconds
        )
    }

    @discardableResult
    private func removePermanentCopy(named name: String) -> Bool {
        guard slots.removeNamed(name) != nil else { return false }
        scheduleVocabularyRefresh()
        return true
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
            let vocabulary = Array(slots.allNamedKeys)
            if !(await speech.updateVocabulary(vocabulary)) {
                try? await Task.sleep(for: .milliseconds(50))
                guard speech.isListening else { continue }
                _ = await speech.updateVocabulary(Array(slots.allNamedKeys))
            }
        }
        vocabularyRefreshTask = nil

        if vocabularyRefreshPending {
            scheduleVocabularyRefresh()
        }
    }
}

private struct QueuedCommand {
    let operation: QueuedOperation
    let speechMetadata: SpeechCommandMetadata?
    let target: CommandTarget?
}

private enum QueuedOperation {
    case voice(VoiceCommand)
    case pasteTemporary(payload: ClipboardPayload)
    case pastePermanent(payload: ClipboardPayload)

    var telemetryName: String {
        switch self {
        case .voice(let command): command.telemetryName
        case .pasteTemporary: "dashboard-paste-temporary"
        case .pastePermanent: "dashboard-paste-named"
        }
    }

    var requiresExternalTarget: Bool {
        switch self {
        case .voice(let command): command.requiresExternalTarget
        case .pasteTemporary, .pastePermanent: true
        }
    }
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
            "That named copy does not exist."
        }
    }
}
