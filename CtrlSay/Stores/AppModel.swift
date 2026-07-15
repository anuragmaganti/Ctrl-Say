import AppKit
import CoreMedia
import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    let slots = ClipboardStore()
    let speech = SpeechRecognitionService()
    let launchAtLogin = LaunchAtLoginController()

    private(set) var lastAction = "Ready"
    private(set) var lastError: String?
    private(set) var isProcessingCommand = false
    private(set) var hasEventPostingAccess = false
    private(set) var hasKeyboardMonitoringAccess = false
    private(set) var isClipboardHUDPresented = false
    private(set) var permanentStorageState: PermanentCopyPersistenceState = .loading
    private(set) var notchFeedbackSignal: NotchFeedbackSignal?
    private(set) var hasAnsweredLaunchAtLoginOnboarding: Bool

#if DEBUG
    private(set) var debugDiagnostics = DebugPipelineSnapshot()
#endif

    @ObservationIgnored private let clipboard = ClipboardService()
    @ObservationIgnored private let permanentRepository: any PermanentCopyPersisting
    @ObservationIgnored private var rightOptionMonitor: RightOptionKeyMonitor?
    @ObservationIgnored private var speechCommandGate = SpeechCommandGate()
    @ObservationIgnored private var numberedCommandScanner = StreamingNumberedCommandScanner()
    @ObservationIgnored private var commandQueue = SerialCommandQueueState<QueuedCommand, SpeechCommandIdentity>()
    @ObservationIgnored private var capturedSpeechTargets: [SpeechCommandIdentity: TargetSnapshot] = [:]
    @ObservationIgnored private var activeNamedCopyCommands: [
        StreamingNumberedCommandID: ActiveNamedCopyCommand
    ] = [:]
    @ObservationIgnored private var desiredListening = false
    @ObservationIgnored private var listeningTransitionTask: Task<Void, Never>?
    @ObservationIgnored private var vocabularyRefreshPending = false
    @ObservationIgnored private var vocabularyRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var hudPresentationRequestedAtNanoseconds: UInt64?
    @ObservationIgnored private var pendingHUDRowAppearance: (
        payloadID: UUID,
        storedAtNanoseconds: UInt64
    )?
    @ObservationIgnored private var permanentRestoreTask: Task<Void, Never>?
    @ObservationIgnored private var permanentPersistenceTask: Task<Void, Never>?
    @ObservationIgnored private var permanentMutationQueue = PermanentMutationQueueState()
    @ObservationIgnored private var didRestorePermanentStorage = false
    @ObservationIgnored private var notchFeedbackSequence: UInt64 = 0

    var isReadyForCommands: Bool {
        speech.microphoneAuthorization == .authorized
            && hasKeyboardMonitoringAccess
            && hasEventPostingAccess
    }

    init(
        permanentRepository: any PermanentCopyPersisting = PermanentCopyRepository()
    ) {
        self.permanentRepository = permanentRepository
        hasAnsweredLaunchAtLoginOnboarding = UserDefaults.standard.bool(
            forKey: CtrlSayPreferenceKey.answeredLaunchAtLoginOnboarding
        )
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
        startPermanentStorageRestore()
    }

    func completeLaunchAtLoginOnboarding(enable: Bool) {
        let updated = enable ? launchAtLogin.setEnabled(true) : true
        hasAnsweredLaunchAtLoginOnboarding = true
        UserDefaults.standard.set(
            true,
            forKey: CtrlSayPreferenceKey.answeredLaunchAtLoginOnboarding
        )

        if enable {
            if launchAtLogin.state == .requiresApproval {
                launchAtLogin.openSystemSettings()
            }
            if updated {
                lastAction = "Launch at Login enabled"
            } else {
                lastError = launchAtLogin.errorMessage
                lastAction = "Login Item setting unavailable"
            }
        } else {
            lastAction = "Launch at Login skipped"
        }
    }

    func setLaunchAtLoginEnabled(_ isEnabled: Bool) {
        _ = launchAtLogin.setEnabled(isEnabled)
        hasAnsweredLaunchAtLoginOnboarding = true
        UserDefaults.standard.set(
            true,
            forKey: CtrlSayPreferenceKey.answeredLaunchAtLoginOnboarding
        )
    }

    func refreshLaunchAtLogin() {
        launchAtLogin.refresh()
    }

    var hasPendingPermanentWrites: Bool {
        !permanentMutationQueue.isEmpty
            || permanentMutationQueue.inFlightSequence != nil
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
            gesture: gesture
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

    func pasteNumberedCopy(_ payload: ClipboardPayload, number: Int) {
        enqueueDashboard(
            .pasteTemporary(payload: payload, label: String(number)),
            target: clipboard.currentCommandTarget()
        )
    }

    func pasteTemporaryNamedCopy(_ payload: ClipboardPayload, name: String) {
        enqueueDashboard(
            .pasteTemporary(payload: payload, label: name),
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
            .pastePermanent(payload: payload, label: name),
            target: clipboard.currentCommandTarget()
        )
    }

    func deletePermanentCopy(_ payloadID: UUID) {
        guard didRestorePermanentStorage else {
            reportPermanentStorageUnavailable()
            return
        }
        guard let name = slots.name(forPayloadID: payloadID),
              let removed = slots.removeNamed(name) else {
            return
        }
        enqueuePermanentMutation(
            .delete(name: name, expectedPayloadID: removed.id)
        )
        scheduleVocabularyRefresh()
        lastError = nil
        lastAction = "Deleted permanent copy"
    }

    @discardableResult
    func renamePermanentCopy(
        _ payloadID: UUID,
        to requestedName: String
    ) throws -> String {
        try requirePermanentStorage()
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
        if normalizedName != currentName {
            enqueuePermanentMutation(
                .rename(
                    from: currentName,
                    to: normalizedName,
                    expectedPayloadID: payloadID
                )
            )
        }
        scheduleVocabularyRefresh()
        lastError = nil
        lastAction = "Renamed permanent copy"
        return normalizedName
    }

    func updatePermanentCopyText(_ payloadID: UUID, text: String) throws {
        try requirePermanentStorage()
        guard let name = slots.name(forPayloadID: payloadID) else {
            throw ClipboardStoreError.missingPermanentCopy
        }
        try slots.replaceNamedText(
            named: name,
            text: text,
            expectedPayloadID: payloadID
        )
        guard let updatedPayload = slots.payload(named: name) else {
            throw ClipboardStoreError.missingPermanentCopy
        }
        enqueuePermanentMutation(.upsert(name: name, payload: updatedPayload))
        lastError = nil
        lastAction = "Updated permanent copy"
    }

    func retryPermanentStorage() {
        switch permanentStorageState {
        case .loadFailed:
            startPermanentStorageRestore()
        case .saveFailed:
            startPermanentPersistenceDrainIfNeeded()
        case .loading, .ready, .saving:
            break
        }
    }

    func resetPermanentStorage() async {
        didRestorePermanentStorage = false
        permanentStorageState = .loading
        permanentPersistenceTask?.cancel()
        permanentPersistenceTask = nil
        permanentMutationQueue.removeAll()

        do {
            try await permanentRepository.reset()
            slots.clearPermanentCopies()
            didRestorePermanentStorage = true
            permanentStorageState = .ready
            scheduleVocabularyRefresh()
            lastError = nil
            lastAction = "Reset permanent storage"
            Telemetry.persistence.notice("Permanent storage reset")
        } catch {
            didRestorePermanentStorage = false
            permanentStorageState = .loadFailed
            lastError = PermanentCopyPersistenceError.storageUnavailable.localizedDescription
            Telemetry.persistence.error("Permanent storage reset failed")
        }
    }

    func flushPermanentCopies() async throws {
        if let permanentRestoreTask {
            await permanentRestoreTask.value
        }
        guard didRestorePermanentStorage else {
            throw PermanentCopyPersistenceError.storageUnavailable
        }

        while true {
            if !permanentMutationQueue.isEmpty {
                startPermanentPersistenceDrainIfNeeded()
            }
            if let permanentPersistenceTask {
                await permanentPersistenceTask.value
            }
            guard permanentMutationQueue.isEmpty else {
                throw PermanentCopyPersistenceError.unsavedChanges
            }
            try await permanentRepository.flush()
            if permanentMutationQueue.isEmpty {
                return
            }
        }
    }

    func waitForPermanentStorageRestore() async {
        if let permanentRestoreTask {
            await permanentRestoreTask.value
        }
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

    @discardableResult
    private func setListeningDesired(_ shouldListen: Bool) -> Bool {
        refreshPermissions()
        let canStopActiveTransition = speech.isActive
            || listeningTransitionTask != nil
        guard !shouldListen || isReadyForCommands || canStopActiveTransition else {
            lastError = "Complete the three setup permissions before listening."
            lastAction = "Setup required"
            publishNotchFeedback(.commandFailed(message: "Setup required"))
            return false
        }

        desiredListening = shouldListen
        publishNotchFeedback(
            shouldListen ? .listeningRequested : .listeningStopped
        )
        if !shouldListen {
            listeningTransitionTask?.cancel()
        }
        startListeningTransitionIfNeeded()
        return true
    }

    private func received(_ result: RecognizedSpeechResult) {
        let exactCommand = VoiceCommandParser.parse(result.text)
        let timelineTokens: [StreamingNumberedCommandToken]
        if case .permanentCopy = exactCommand {
            // A full phrase that parses as permanent must never lose its
            // modifier because SpeechTranscriber's attributed runs exposed a
            // different lexical partition. The scanner still owns timing and
            // deduplication; this only gives it the canonical phrase tokens.
            timelineTokens = [
                StreamingNumberedCommandToken(
                    result.text,
                    range: SpeechResultRange(result.range),
                    confidence: result.minimumConfidence
                ),
            ]
        } else {
            timelineTokens = result.tokens
        }
        let numberedUpdate = numberedCommandScanner.ingest(
            StreamingNumberedCommandSegment(
                range: SpeechResultRange(result.range),
                tokens: timelineTokens,
                finalizationTime: result.finalizationTime,
                isFinal: result.isFinal,
                hasTrailingPhraseBoundary:
                    VoiceCommandParser.hasExplicitPhraseBoundary(result.text)
            ),
            knownNamedCopies: slots.allNamedKeys
        )
        for mutation in numberedUpdate.mutations {
            apply(mutation, from: result)
        }

        let gatedCommand: VoiceCommand?
        switch exactCommand {
        case .copyNumber, .pasteNumber, .copyNamed, .permanentCopy:
            // Fast copy and paste commands are owned by the timeline scanner.
            // Sending an exact match through both paths would execute final
            // echoes twice.
            gatedCommand = nil
        case .pasteNamed:
            // The timeline scanner owns all known-name pastes, including
            // multiword names, so growing volatile results cannot execute
            // through both the scanner and whole-result gate.
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
                "Streaming candidate id=\(candidate.id.rawValue, privacy: .public) command=\(candidate.command.telemetryName, privacy: .public) ready=\(candidate.isReadyForDispatch, privacy: .public) stable=\(candidate.isStableForCommit, privacy: .public) start=\(candidate.range.start.seconds, privacy: .public) end=\(candidate.range.end.seconds, privacy: .public) final=\(resultIsFinal, privacy: .public)"
            )
#endif
            let identity = SpeechCommandIdentity.numbered(candidate.id)
            if candidate.command.isRevisableNamedCopy {
                if updateActiveNamedCopyCommand(
                    with: candidate,
                    receivedAtNanoseconds: resultReceivedAtNanoseconds
                ) {
                    return
                }
            } else if activeNamedCopyCommands[candidate.id] != nil {
                cancelActiveNamedCopyCommand(candidate.id, removeStoredCopy: true)
            }
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
            cancelActiveNamedCopyCommand(candidateID, removeStoredCopy: true)
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

    /// Returns true when this is a revision of an already-started named copy.
    /// The first candidate continues into the serialized command queue so the
    /// native Copy action starts immediately. Later candidates only revise the
    /// label associated with that same capture.
    private func updateActiveNamedCopyCommand(
        with candidate: StreamingNumberedCommandCandidate,
        receivedAtNanoseconds: UInt64
    ) -> Bool {
        let storage: NamedCopyStorage
        let rawName: String
        switch candidate.command {
        case .copyNamed(let name):
            storage = .temporary
            rawName = name
        case .permanentCopy(let name):
            storage = .permanent
            rawName = name
        default:
            return false
        }
        let name = VoiceCommandParser.normalizeName(rawName)

        guard var active = activeNamedCopyCommands[candidate.id] else {
            activeNamedCopyCommands[candidate.id] = ActiveNamedCopyCommand(
                latestName: name,
                storedName: nil,
                payloadID: nil,
                storage: storage,
                // Treat the serialized capture as active immediately. Apple
                // can close the phrase before the worker gets its first Main
                // Actor turn; that must not finalize away the queued copy.
                isExecuting: true,
                isStableForCommit: candidate.isStableForCommit,
                firstObservedAtNanoseconds: receivedAtNanoseconds,
                lastObservedAtNanoseconds: receivedAtNanoseconds,
                lastCharacterCount: name.count
            )
#if DEBUG
            debugDiagnostics.namedCopyCandidateStarted(
                characterCount: name.count,
                isStable: candidate.isStableForCommit
            )
#endif
            return false
        }
        guard active.storage == storage else {
            assertionFailure("A named-copy candidate changed storage lifetime")
            cancelActiveNamedCopyCommand(
                candidate.id,
                removeStoredCopy: true
            )
            return false
        }

        let previousCharacterCount = active.lastCharacterCount
        let revisionMilliseconds = milliseconds(
            from: active.lastObservedAtNanoseconds,
            to: receivedAtNanoseconds
        )
        let totalMilliseconds = milliseconds(
            from: active.firstObservedAtNanoseconds,
            to: receivedAtNanoseconds
        )
        active.latestName = name
        active.isStableForCommit = active.isStableForCommit
            || candidate.isStableForCommit
        active.lastObservedAtNanoseconds = receivedAtNanoseconds
        active.lastCharacterCount = name.count

#if DEBUG
        Telemetry.speech.info(
            "Named copy revision id=\(candidate.id.rawValue, privacy: .public) delta_ms=\(revisionMilliseconds, privacy: .public) total_ms=\(totalMilliseconds, privacy: .public) previous_chars=\(previousCharacterCount, privacy: .public) current_chars=\(name.count, privacy: .public) stable=\(active.isStableForCommit, privacy: .public)"
        )
        debugDiagnostics.namedCopyCandidateRevised(
            previousCharacterCount: previousCharacterCount,
            currentCharacterCount: name.count,
            revisionMilliseconds: revisionMilliseconds,
            totalMilliseconds: totalMilliseconds,
            isStable: active.isStableForCommit
        )
#endif

        if let storedName = active.storedName,
           let payloadID = active.payloadID,
           storedName != name {
            do {
                let revisedName: String?
                switch active.storage {
                case .temporary:
                    revisedName = try slots.reviseTemporaryNamed(
                        from: storedName,
                        to: name,
                        expectedPayloadID: payloadID
                    )
                case .permanent:
                    guard slots.payload(named: storedName)?.id == payloadID else {
                        revisedName = nil
                        break
                    }
                    let normalizedName = try slots.renameNamed(
                        from: storedName,
                        to: name,
                        expectedPayloadID: payloadID
                    )
                    if normalizedName != storedName {
                        enqueuePermanentMutation(
                            .rename(
                                from: storedName,
                                to: normalizedName,
                                expectedPayloadID: payloadID
                            )
                        )
                    }
                    revisedName = normalizedName
                }
                if let revisedName {
                    active.storedName = revisedName
                    scheduleVocabularyRefresh()
                    lastError = nil
                    lastAction = active.storage == .temporary
                        ? "Copied to \(revisedName)"
                        : "Created permanent copy"
                    publishNotchFeedback(
                        .commandSucceeded(action: .copy, label: revisedName)
                    )
                }
            } catch {
                activeNamedCopyCommands[candidate.id] = active
                cancelActiveNamedCopyCommand(
                    candidate.id,
                    removeStoredCopy: true
                )
                numberedCommandScanner.markCommitted(candidate.id)
                lastError = error.localizedDescription
                lastAction = "Command failed"
                publishNotchFeedback(
                    .commandFailed(message: notchFailureMessage(for: error))
                )
                return true
            }
        }

        activeNamedCopyCommands[candidate.id] = active
        if active.isStableForCommit && !active.isExecuting {
            finishActiveNamedCopyCommand(candidate.id)
        }
        return true
    }

    private func finishActiveNamedCopyCommand(
        _ candidateID: StreamingNumberedCommandID
    ) {
        numberedCommandScanner.markCommitted(candidateID)
        capturedSpeechTargets.removeValue(forKey: .numbered(candidateID))
        activeNamedCopyCommands.removeValue(forKey: candidateID)
    }

    private func cancelActiveNamedCopyCommand(
        _ candidateID: StreamingNumberedCommandID,
        removeStoredCopy: Bool
    ) {
        guard let active = activeNamedCopyCommands.removeValue(
            forKey: candidateID
        ) else {
            return
        }
        guard removeStoredCopy,
              let storedName = active.storedName,
              let payloadID = active.payloadID else {
            return
        }
        switch active.storage {
        case .temporary:
            guard slots.payload(temporaryNamed: storedName)?.id == payloadID else {
                return
            }
            slots.removeTemporaryNamed(storedName)
        case .permanent:
            guard slots.payload(named: storedName)?.id == payloadID,
                  slots.removeNamed(storedName) != nil else {
                return
            }
            enqueuePermanentMutation(
                .delete(name: storedName, expectedPayloadID: payloadID)
            )
        }
        scheduleVocabularyRefresh()
    }

    private func finishActiveNamedCopyAfterFailure(
        _ identity: SpeechCommandIdentity?
    ) {
        guard case .numbered(let candidateID) = identity,
              activeNamedCopyCommands[candidateID] != nil else {
            return
        }
        cancelActiveNamedCopyCommand(candidateID, removeStoredCopy: true)
        numberedCommandScanner.markCommitted(candidateID)
        capturedSpeechTargets.removeValue(forKey: .numbered(candidateID))
    }

    private func captureNamedCopy(
        requestedName: String,
        storage: NamedCopyStorage,
        identity: SpeechCommandIdentity?,
        target: CommandTarget?
    ) async throws -> NamedCopyCaptureResult {
        if storage == .permanent {
            try requirePermanentStorage()
        }

        let candidateID: StreamingNumberedCommandID?
        if case .numbered(let id) = identity {
            guard var active = activeNamedCopyCommands[id],
                  active.storage == storage else {
                throw CancellationError()
            }
            active.isExecuting = true
            activeNamedCopyCommands[id] = active
            candidateID = id
        } else {
            candidateID = nil
        }

        let capture = try await clipboard.captureSelection(target: target)
        let currentName: String
        if let candidateID {
            guard let active = activeNamedCopyCommands[candidateID] else {
                throw CancellationError()
            }
            currentName = active.latestName
        } else {
            currentName = requestedName
        }

        let normalizedName: String
        switch storage {
        case .temporary:
            normalizedName = try slots.validateTemporaryNameAvailable(
                currentName
            )
            try slots.setTemporaryNamed(
                capture.payload,
                named: normalizedName
            )
        case .permanent:
            guard let validName = VoiceCommandParser.validNormalizedPermanentName(
                currentName
            ) else {
                throw ClipboardStoreError.invalidPermanentName
            }
            normalizedName = validName
            try slots.set(capture.payload, named: normalizedName)
            enqueuePermanentMutation(
                .upsert(name: normalizedName, payload: capture.payload)
            )
        }

        if let candidateID,
           var active = activeNamedCopyCommands[candidateID] {
            active.isExecuting = false
            active.storedName = normalizedName
            active.payloadID = capture.payload.id
            activeNamedCopyCommands[candidateID] = active
            capturedSpeechTargets.removeValue(forKey: .numbered(candidateID))
            if active.isStableForCommit {
                finishActiveNamedCopyCommand(candidateID)
            }
        }

        markHUDStoreUpdate(for: capture.payload.id)
        scheduleVocabularyRefresh()
        return NamedCopyCaptureResult(
            capture: capture,
            normalizedName: normalizedName
        )
    }

    private func milliseconds(from start: UInt64, to end: UInt64) -> Double {
        guard end >= start else { return 0 }
        return Double(end - start) / 1_000_000
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
                    // A named copy captures immediately but remains revisable
                    // until Apple closes the volatile phrase. Later text
                    // revisions rename the same stored payload.
                    if activeNamedCopyCommands[candidateID] == nil {
                        numberedCommandScanner.markCommitted(candidateID)
                    }
                }
                if case .numbered(let candidateID) = identity,
                   activeNamedCopyCommands[candidateID] != nil {
                    // Retain the original target until the one native copy
                    // capture completes.
                } else {
                    capturedSpeechTargets.removeValue(forKey: identity)
                }
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
                identity: entry.identity,
                queueWaitMilliseconds: queueWaitMilliseconds
            )
        }
        isProcessingCommand = false
    }

    private func execute(
        _ queued: QueuedCommand,
        identity: SpeechCommandIdentity?,
        queueWaitMilliseconds: Double
    ) async {
        let restoreWaitStarted = DispatchTime.now().uptimeNanoseconds
        if let permanentRestoreTask {
            await permanentRestoreTask.value
        }
        let restoreWaitMilliseconds = Double(
            DispatchTime.now().uptimeNanoseconds - restoreWaitStarted
        ) / 1_000_000
        let effectiveQueueWaitMilliseconds = queueWaitMilliseconds
            + restoreWaitMilliseconds

        if case .voice(let command) = queued.operation,
           command.requiresExternalTarget,
           let metadata = queued.speechMetadata,
           !SpeechCommandFreshnessPolicy.isFresh(
                metadata,
                command: command,
                at: DispatchTime.now().uptimeNanoseconds
           ) {
            recordPipeline(
                queued,
                queueWaitMilliseconds: effectiveQueueWaitMilliseconds,
                executionMilliseconds: 0,
                clipboardMilliseconds: nil,
                targetStatus: .notChecked,
                succeeded: false
            )
            Telemetry.commands.warning(
                "\(queued.operation.telemetryName, privacy: .public) dropped because recognition was stale"
            )
            finishActiveNamedCopyAfterFailure(identity)
            return
        }

        let started = DispatchTime.now().uptimeNanoseconds
        lastError = nil
        var clipboardMilliseconds: Double?
        var successfulNotchFeedback: NotchFeedbackEvent?
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
                    successfulNotchFeedback = .commandSucceeded(
                        action: .copy,
                        label: String(number)
                    )

                case .pasteNumber(let number):
                    guard let payload = slots.payload(at: number) else {
                        throw AppModelError.emptyNumberedSlot(number)
                    }
                    let metrics = try clipboard.paste(payload, target: queued.target)
                    clipboardMilliseconds = metrics.milliseconds
                    targetStatus = .verified
                    lastAction = "Paste sent from \(number)"
                    successfulNotchFeedback = .commandSucceeded(
                        action: .paste,
                        label: String(number)
                    )

                case .copyNamed(let name):
                    let result = try await captureNamedCopy(
                        requestedName: name,
                        storage: .temporary,
                        identity: identity,
                        target: queued.target
                    )
                    clipboardMilliseconds = result.capture.milliseconds
                    targetStatus = .verified
                    lastAction = "Copied to \(result.normalizedName)"
                    successfulNotchFeedback = .commandSucceeded(
                        action: .copy,
                        label: result.normalizedName
                    )

                case .permanentCopy(let name):
                    let result = try await captureNamedCopy(
                        requestedName: name,
                        storage: .permanent,
                        identity: identity,
                        target: queued.target
                    )
                    clipboardMilliseconds = result.capture.milliseconds
                    targetStatus = .verified
                    lastAction = "Created permanent copy"
                    successfulNotchFeedback = .commandSucceeded(
                        action: .copy,
                        label: result.normalizedName
                    )

                case .pasteNamed(let name):
                    let payload: ClipboardPayload
                    if let temporaryPayload = slots.payload(temporaryNamed: name) {
                        payload = temporaryPayload
                    } else {
                        try requirePermanentStorage()
                        guard let permanentPayload = slots.payload(named: name) else {
                            throw AppModelError.missingNamedCopy
                        }
                        payload = permanentPayload
                    }
                    let metrics = try clipboard.paste(payload, target: queued.target)
                    clipboardMilliseconds = metrics.milliseconds
                    targetStatus = .verified
                    lastAction = "Named paste sent"
                    successfulNotchFeedback = .commandSucceeded(
                        action: .paste,
                        label: name
                    )

                case .deleteNumber(let number):
                    guard slots.removeNumbered(number) != nil else {
                        throw AppModelError.emptyNumberedSlot(number)
                    }
                    lastAction = "Deleted copy \(number)"

                case .deleteNamed(let name):
                    if slots.removeTemporaryNamed(name) != nil {
                        scheduleVocabularyRefresh()
                        lastAction = "Deleted temporary copy"
                    } else {
                        try requirePermanentStorage()
                        guard removePermanentCopy(named: name) else {
                            throw AppModelError.missingNamedCopy
                        }
                        lastAction = "Deleted permanent copy"
                    }

                case .promoteTemporaryNamed(let name):
                    try requirePermanentStorage()
                    guard let normalizedName = VoiceCommandParser.validNormalizedPermanentName(name) else {
                        throw ClipboardStoreError.invalidPermanentName
                    }
                    guard let payload = slots.payload(temporaryNamed: normalizedName) else {
                        throw ClipboardStoreError.missingTemporaryCopy
                    }
                    try slots.set(payload, named: normalizedName)
                    enqueuePermanentMutation(
                        .upsert(name: normalizedName, payload: payload)
                    )
                    scheduleVocabularyRefresh()
                    lastAction = "Made \(normalizedName) permanent"

                case .renameTemporaryNamed(let currentName, let requestedName):
                    let revisedName = try slots.renameTemporaryNamed(
                        from: currentName,
                        to: requestedName
                    )
                    scheduleVocabularyRefresh()
                    lastAction = "Renamed to \(revisedName)"

                case .clearTemporary:
                    slots.clearTemporary()
                    scheduleVocabularyRefresh()
                    lastAction = "Cleared temporary copies"
                }

            case .pasteTemporary(let payload, let label):
                let metrics = try clipboard.paste(payload, target: queued.target)
                clipboardMilliseconds = metrics.milliseconds
                targetStatus = .verified
                lastAction = "Temporary paste sent"
                successfulNotchFeedback = .commandSucceeded(
                    action: .paste,
                    label: label
                )

            case .pastePermanent(let payload, let label):
                let metrics = try clipboard.paste(payload, target: queued.target)
                clipboardMilliseconds = metrics.milliseconds
                targetStatus = .verified
                lastAction = "Permanent paste sent"
                successfulNotchFeedback = .commandSucceeded(
                    action: .paste,
                    label: label
                )
            }

            hasEventPostingAccess = clipboard.hasEventPostingAccess
            let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            recordPipeline(
                queued,
                queueWaitMilliseconds: effectiveQueueWaitMilliseconds,
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
            if let successfulNotchFeedback {
                publishNotchFeedback(successfulNotchFeedback)
            }
        } catch {
            if error is CancellationError {
                finishActiveNamedCopyAfterFailure(identity)
                return
            }
            finishActiveNamedCopyAfterFailure(identity)
            if queued.operation.requiresExternalTarget {
                targetStatus = targetFailureStatus(error) ?? targetStatus
            }
            lastError = error.localizedDescription
            lastAction = "Command failed"
            NSSound.beep()
            let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            recordPipeline(
                queued,
                queueWaitMilliseconds: effectiveQueueWaitMilliseconds,
                executionMilliseconds: milliseconds,
                clipboardMilliseconds: clipboardMilliseconds,
                targetStatus: targetStatus,
                succeeded: false
            )
            Telemetry.commands.error("\(queued.operation.telemetryName, privacy: .public) failed: \(error.localizedDescription, privacy: .private)")
            publishNotchFeedback(
                .commandFailed(message: notchFailureMessage(for: error))
            )
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

    private func publishNotchFeedback(_ event: NotchFeedbackEvent) {
        notchFeedbackSequence &+= 1
        notchFeedbackSignal = NotchFeedbackSignal(
            sequence: notchFeedbackSequence,
            event: event
        )
    }

    private func notchFailureMessage(for error: Error) -> String {
        if let appError = error as? AppModelError {
            switch appError {
            case .emptyNumberedSlot(let number):
                return "Copy \(number) is empty"
            case .missingNamedCopy:
                return "Copy not found"
            }
        }

        if let clipboardError = error as? ClipboardServiceError {
            switch clipboardError {
            case .accessibilityPermissionRequired:
                return "Accessibility required"
            case .clipboardIsEmpty, .copyTimedOut:
                return "Nothing was copied"
            case .unsupportedOrOversizedContent:
                return "Copy is too large"
            case .couldNotWriteClipboard:
                return "Clipboard write failed"
            case .couldNotCreateKeyboardEvent:
                return "Command could not be sent"
            case .commandTargetUnavailable:
                return "No destination app"
            case .commandTargetChanged:
                return "App changed — try again"
            }
        }

        if let storeError = error as? ClipboardStoreError {
            switch storeError {
            case .invalidTemporaryName, .invalidPermanentName:
                return "Name not recognized"
            case .nameProtectedByPermanentCopy:
                return "Name is permanent"
            case .temporaryNameAlreadyExists, .permanentNameAlreadyExists:
                return "Name already exists"
            case .missingPermanentCopy:
                return "Copy not found"
            case .missingTemporaryCopy:
                return "Copy not found"
            case .permanentCopyChanged:
                return "Copy changed — try again"
            case .emptyContent:
                return "Nothing was copied"
            case .contentTooLarge, .payloadTooLarge:
                return "Copy is too large"
            case .noneditableContent:
                return "Copy cannot be edited"
            case .storageLimitExceeded:
                return "Clipboard storage is full"
            case .invalidRestoredPermanentCopy,
                 .duplicateRestoredPermanentCopy:
                return "Permanent storage unavailable"
            }
        }

        if error is PermanentCopyPersistenceError {
            return "Permanent storage unavailable"
        }
        return "Command failed"
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
        activeNamedCopyCommands.removeAll(keepingCapacity: true)
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
        let normalizedName = VoiceCommandParser.normalizeName(name)
        guard let removed = slots.removeNamed(normalizedName) else { return false }
        enqueuePermanentMutation(
            .delete(name: normalizedName, expectedPayloadID: removed.id)
        )
        scheduleVocabularyRefresh()
        return true
    }

    private func requirePermanentStorage() throws {
        guard didRestorePermanentStorage else {
            throw PermanentCopyPersistenceError.storageUnavailable
        }
    }

    private func reportPermanentStorageUnavailable() {
        lastError = PermanentCopyPersistenceError.storageUnavailable.localizedDescription
        lastAction = "Permanent storage unavailable"
        NSSound.beep()
    }

    private func startPermanentStorageRestore() {
        guard permanentRestoreTask == nil else { return }
        permanentStorageState = .loading
        let startedAt = DispatchTime.now().uptimeNanoseconds

        permanentRestoreTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            do {
                let restored = try await permanentRepository.load()
                try slots.restorePermanentCopies(restored)
                didRestorePermanentStorage = true
                permanentStorageState = .ready
                lastError = nil
                scheduleVocabularyRefresh()
                let byteCount = restored.reduce(0) { $0 + $1.payload.byteCount }
                let milliseconds = Double(
                    DispatchTime.now().uptimeNanoseconds - startedAt
                ) / 1_000_000
                Telemetry.persistence.info(
                    "Permanent load completed count=\(restored.count, privacy: .public) bytes=\(byteCount, privacy: .public) duration_ms=\(milliseconds, privacy: .public)"
                )
            } catch {
                didRestorePermanentStorage = false
                permanentStorageState = .loadFailed
                lastError = PermanentCopyPersistenceError.storageUnavailable.localizedDescription
                Telemetry.persistence.error("Permanent load failed")
            }
            permanentRestoreTask = nil
        }
    }

    private func enqueuePermanentMutation(_ mutation: PermanentCopyMutation) {
        permanentMutationQueue.enqueue(mutation)
        startPermanentPersistenceDrainIfNeeded()
    }

    private func startPermanentPersistenceDrainIfNeeded() {
        guard permanentPersistenceTask == nil,
              !permanentMutationQueue.isEmpty,
              didRestorePermanentStorage else {
            return
        }
        permanentStorageState = .saving(
            pendingCount: permanentMutationQueue.count
        )
        permanentPersistenceTask = Task(priority: .utility) { [weak self] in
            await self?.drainPermanentPersistenceMutations()
        }
    }

    private func drainPermanentPersistenceMutations() async {
        while let pending = permanentMutationQueue.beginNext() {
            if Task.isCancelled { break }
            let startedAt = DispatchTime.now().uptimeNanoseconds

            do {
                try await permanentRepository.apply(pending.mutation)
                if Task.isCancelled { return }
                guard permanentMutationQueue.complete(pending.sequence) else {
                    assertionFailure("Permanent-copy mutation order changed while saving")
                    break
                }
                let milliseconds = Double(
                    DispatchTime.now().uptimeNanoseconds - startedAt
                ) / 1_000_000
                Telemetry.persistence.info(
                    "Permanent mutation saved sequence=\(pending.sequence, privacy: .public) bytes=\(pending.mutation.byteCount, privacy: .public) duration_ms=\(milliseconds, privacy: .public) remaining=\(self.permanentMutationQueue.count, privacy: .public)"
                )
            } catch {
                permanentMutationQueue.fail(pending.sequence)
                permanentStorageState = .saveFailed(
                    pendingCount: permanentMutationQueue.count
                )
                lastError = PermanentCopyPersistenceError.unsavedChanges.localizedDescription
                Telemetry.persistence.error(
                    "Permanent mutation save failed sequence=\(pending.sequence, privacy: .public) pending=\(self.permanentMutationQueue.count, privacy: .public)"
                )
                permanentPersistenceTask = nil
                return
            }
        }

        permanentPersistenceTask = nil
        if permanentMutationQueue.isEmpty {
            permanentStorageState = .ready
            if lastError == PermanentCopyPersistenceError.unsavedChanges.localizedDescription {
                lastError = nil
            }
        } else if !Task.isCancelled {
            startPermanentPersistenceDrainIfNeeded()
        }
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
    case pasteTemporary(payload: ClipboardPayload, label: String)
    case pastePermanent(payload: ClipboardPayload, label: String)

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

private struct ActiveNamedCopyCommand {
    var latestName: String
    var storedName: String?
    var payloadID: UUID?
    let storage: NamedCopyStorage
    var isExecuting: Bool
    var isStableForCommit: Bool
    let firstObservedAtNanoseconds: UInt64
    var lastObservedAtNanoseconds: UInt64
    var lastCharacterCount: Int
}

private enum NamedCopyStorage {
    case temporary
    case permanent
}

private struct NamedCopyCaptureResult {
    let capture: ClipboardCaptureResult
    let normalizedName: String
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
