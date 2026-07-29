import AVFoundation
import CoreMedia
import Foundation
import Observation
import Speech

@MainActor
@Observable
final class SpeechRecognitionService {
    private static let commandLocale = Locale(identifier: "en-US")

    private struct PendingPreparation {
        let generation: UInt64
        let task: Task<Void, Error>
    }

    enum State: Equatable {
        case stopped
        case requestingMicrophone
        case preparing
        case downloadingModel
        case listening
        case stopping
        case failed(String)

        var label: String {
            switch self {
            case .stopped: "Not listening"
            case .requestingMicrophone: "Requesting microphone access…"
            case .preparing: "Preparing on-device recognition…"
            case .downloadingModel: "Downloading Apple’s language model…"
            case .listening: "Listening"
            case .stopping: "Stopping…"
            case .failed(let message): message
            }
        }
    }

    private(set) var state: State = .stopped
    private(set) var microphoneAuthorization = AVCaptureDevice.authorizationStatus(for: .audio)

    var isListening: Bool { state == .listening }
    var isActive: Bool {
        switch state {
        case .requestingMicrophone, .preparing, .downloadingModel, .listening,
            .stopping:
            true
        case .stopped, .failed:
            false
        }
    }

    @ObservationIgnored var onResult: ((RecognizedSpeechResult) -> Void)?
    @ObservationIgnored var onFinalizationTimeChanged: ((CMTime) -> Void)?

    @ObservationIgnored private let audioEngine = AVAudioEngine()
    @ObservationIgnored private let converter = AudioBufferConverter()
    @ObservationIgnored private var analyzer: SpeechAnalyzer?
    @ObservationIgnored private var analyzerFormat: AVAudioFormat?
    @ObservationIgnored private var analyzerInputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    @ObservationIgnored private var audioContinuation: AsyncStream<AudioBufferTransfer>.Continuation?
    @ObservationIgnored private var audioTask: Task<Void, Never>?
    @ObservationIgnored private var resultsTask: Task<Void, Never>?
    @ObservationIgnored private var isInputTapInstalled = false
    @ObservationIgnored private var analysisStartedAtNanoseconds: UInt64?
    @ObservationIgnored private var pendingPreparation: PendingPreparation?
    @ObservationIgnored private var nextPreparationGeneration: UInt64 = 0
    @ObservationIgnored private var currentVocabulary = Set<String>()
    @ObservationIgnored private var resultGate = SpeechSessionResultGate()
    @ObservationIgnored private var audioTimeline = SpeechAudioTimeline()
    @ObservationIgnored private var latestAnalyzerInputEndTime: CMTime?
    @ObservationIgnored private var memoryPressureSource: DispatchSourceMemoryPressure?
    @ObservationIgnored private var releasePreparedResourcesAfterStop = false
    @ObservationIgnored private var preparedResourceReleaseTask: Task<Void, Never>?
    @ObservationIgnored private var backgroundPrewarmingAllowed = true

    init() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleMemoryPressure()
            }
        }
        source.activate()
        memoryPressureSource = source
    }

    deinit {
        memoryPressureSource?.cancel()
    }

    // MARK: - Session Control

    /// Prepares Apple's recognizer without opening the microphone. A later
    /// Listening start can then create only a fresh input stream and audio tap.
    func prewarm(vocabulary: [String]) async {
        guard state == .stopped,
            microphoneAuthorization == .authorized,
            analyzer == nil,
            preparedResourceReleaseTask == nil,
            backgroundPrewarmingAllowed
        else {
            return
        }

        let startedAt = DispatchTime.now().uptimeNanoseconds
        do {
            _ = try await ensurePrepared(
                vocabulary: vocabulary,
                reportsProgress: false
            )
            let milliseconds = elapsedMilliseconds(since: startedAt)
            Telemetry.speech.info(
                "Speech analyzer prewarmed duration_ms=\(milliseconds, privacy: .public)"
            )
        } catch is CancellationError {
            Telemetry.speech.info("Speech analyzer prewarm cancelled")
        } catch {
            // Prewarming is an optimization. Surface errors only if the user
            // explicitly starts Listening and the same preparation still fails.
            Telemetry.speech.error(
                "Speech analyzer prewarm failed: \(error.localizedDescription, privacy: .private)"
            )
        }
    }

    func start(vocabulary: [String]) async {
        guard state == .stopped || isFailure else { return }
        let startedAt = DispatchTime.now().uptimeNanoseconds
        releasePreparedResourcesAfterStop = false
        guard !Task.isCancelled else { return }
        if let preparedResourceReleaseTask {
            await preparedResourceReleaseTask.value
        }
        if isFailure {
            await releasePreparedResources(reason: "recover-from-failure")
        }
        guard !Task.isCancelled else {
            state = .stopped
            return
        }
        state = .requestingMicrophone

        let microphoneAccessGranted = await requestMicrophoneAccess()
        guard !Task.isCancelled else {
            state = .stopped
            return
        }
        guard microphoneAccessGranted else {
            state = .failed("Microphone access is required.")
            return
        }

        do {
            try Task.checkCancellation()
            state = .preparing
            let reusedPreparedAnalyzer = try await ensurePrepared(
                vocabulary: vocabulary,
                reportsProgress: true
            )
            try Task.checkCancellation()
            try await startAnalyzerInputSequence()
            try Task.checkCancellation()
            try startAudioCapture()
            state = .listening
            let milliseconds = elapsedMilliseconds(since: startedAt)
            Telemetry.speech.info(
                "On-device listening started warm=\(reusedPreparedAnalyzer, privacy: .public) activation_ms=\(milliseconds, privacy: .public)"
            )
        } catch is CancellationError {
            await stopCurrentInputSequence()
            if releasePreparedResourcesAfterStop {
                await releasePreparedResources(reason: "cancelled-after-memory-pressure")
            }
            state = .stopped
            Telemetry.speech.info("Listening startup cancelled")
        } catch {
            await stopCurrentInputSequence()
            await releasePreparedResources(reason: "startup-failure")
            state = .failed(error.localizedDescription)
            Telemetry.speech.error("Listening failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    func stop() async {
        guard state != .stopped, state != .stopping else { return }
        let startedAt = DispatchTime.now().uptimeNanoseconds
        state = .stopping
        await stopCurrentInputSequence()
        if releasePreparedResourcesAfterStop {
            await releasePreparedResources(reason: "deferred-memory-pressure")
        }
        state = .stopped
        let milliseconds = elapsedMilliseconds(since: startedAt)
        Telemetry.speech.info(
            "Listening stopped duration_ms=\(milliseconds, privacy: .public) analyzer_retained=\(self.analyzer != nil, privacy: .public) audio_engine_running=\(self.audioEngine.isRunning, privacy: .public)"
        )
    }

    // MARK: - Live Vocabulary

    @discardableResult
    func updateVocabulary(_ vocabulary: [String]) async -> Bool {
        guard let analyzer else { return false }
        let commandVocabulary = commandVocabulary(namedCopies: vocabulary)
        let vocabularySet = Set(commandVocabulary)
        guard vocabularySet != currentVocabulary else { return true }

        let context = AnalysisContext()
        context.contextualStrings[.general] = commandVocabulary
        do {
            try await analyzer.setContext(context)
            currentVocabulary = vocabularySet
            return true
        } catch {
            Telemetry.speech.error(
                "Could not update command vocabulary: \(error.localizedDescription, privacy: .private)")
            return false
        }
    }

    // MARK: - Permissions and Timing

    @discardableResult
    func requestMicrophoneAccess() async -> Bool {
        let granted: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            granted = true
        case .notDetermined:
            granted = await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            granted = false
        @unknown default:
            granted = false
        }

        refreshMicrophoneAuthorization()
        return granted
    }

    func refreshMicrophoneAuthorization() {
        microphoneAuthorization = AVCaptureDevice.authorizationStatus(for: .audio)
    }

    func audioEndUptimeNanoseconds(for range: SpeechResultRange) -> UInt64? {
        RecognizedSpeechResult.audioEndUptimeNanoseconds(
            for: range.end,
            analysisStartedAtNanoseconds: analysisStartedAtNanoseconds
        )
    }

    private var isFailure: Bool {
        if case .failed = state { return true }
        return false
    }

    // MARK: - Analyzer Configuration

    /// Returns `true` when the analyzer was already prepared before this call.
    private func ensurePrepared(
        vocabulary: [String],
        reportsProgress: Bool
    ) async throws -> Bool {
        if analyzer != nil {
            try Task.checkCancellation()
            guard await updateVocabulary(vocabulary) else {
                throw SpeechServiceError.transcriberUnavailable
            }
            return true
        }

        let preparation: PendingPreparation
        if let pendingPreparation {
            preparation = pendingPreparation
        } else {
            nextPreparationGeneration &+= 1
            let generation = nextPreparationGeneration
            let newTask = Task { @MainActor [weak self] in
                guard let self else { throw CancellationError() }
                try await self.prepareResources(
                    vocabulary: vocabulary,
                    reportsProgress: reportsProgress
                )
            }
            let newPreparation = PendingPreparation(
                generation: generation,
                task: newTask
            )
            pendingPreparation = newPreparation
            preparation = newPreparation
        }

        do {
            try await withTaskCancellationHandler {
                try await preparation.task.value
            } onCancel: {
                preparation.task.cancel()
            }
            clearPreparation(ifGenerationMatches: preparation.generation)
            try Task.checkCancellation()
        } catch {
            clearPreparation(ifGenerationMatches: preparation.generation)
            throw error
        }

        guard analyzer != nil else {
            throw SpeechServiceError.transcriberUnavailable
        }
        guard await updateVocabulary(vocabulary) else {
            throw SpeechServiceError.transcriberUnavailable
        }
        return false
    }

    private func clearPreparation(ifGenerationMatches generation: UInt64) {
        guard pendingPreparation?.generation == generation else { return }
        pendingPreparation = nil
    }

    private func prepareResources(
        vocabulary: [String],
        reportsProgress: Bool
    ) async throws {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        guard SpeechTranscriber.isAvailable else {
            throw SpeechServiceError.transcriberUnavailable
        }
        // Ctrl-Say's v1 command grammar is English. Using the Mac's current
        // locale would make identical commands fail on non-English systems.
        guard
            let locale = await SpeechTranscriber.supportedLocale(
                equivalentTo: Self.commandLocale
            )
        else {
            throw SpeechServiceError.localeUnsupported
        }
        try Task.checkCancellation()

        var reportingOptions: Set<SpeechTranscriber.ReportingOption> = [
            .volatileResults,
            .fastResults,
        ]
        #if DEBUG
        // Alternatives and raw text are used only by the in-memory developer
        // panel. Release recognition keeps the lower-overhead production path.
        reportingOptions.insert(.alternativeTranscriptions)
        #endif

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: reportingOptions,
            attributeOptions: [.transcriptionConfidence, .audioTimeRange]
        )

        if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try Task.checkCancellation()
            if reportsProgress {
                state = .downloadingModel
            }
            try await installation.downloadAndInstall()
            try Task.checkCancellation()
            if reportsProgress {
                state = .preparing
            }
        }

        let microphoneFormat = audioEngine.inputNode.outputFormat(forBus: 0)
        let naturalFormat =
            microphoneFormat.channelCount > 0
                && microphoneFormat.sampleRate > 0
            ? microphoneFormat
            : nil
        guard
            let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
                compatibleWith: [transcriber],
                considering: naturalFormat
            )
        else {
            throw SpeechServiceError.noCompatibleAudioFormat
        }
        try Task.checkCancellation()

        let commandVocabulary = commandVocabulary(namedCopies: vocabulary)
        let context = AnalysisContext()
        context.contextualStrings[.general] = commandVocabulary

        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: .init(priority: .userInitiated, modelRetention: .processLifetime)
        )
        do {
            try await analyzer.setContext(context)
            await analyzer.setVolatileRangeChangedHandler {
                [weak self] range, changedStart, _ in
                guard changedStart else { return }
                Task { @MainActor [weak self] in
                    guard let self,
                        self.resultGate.acceptsFinalizationTime(range.start)
                    else {
                        return
                    }
                    self.onFinalizationTimeChanged?(range.start)
                }
            }
            try await analyzer.prepareToAnalyze(in: analyzerFormat)
            try Task.checkCancellation()
        } catch {
            await analyzer.cancelAndFinishNow()
            throw error
        }

        self.analyzer = analyzer
        self.analyzerFormat = analyzerFormat
        currentVocabulary = Set(commandVocabulary)
        analysisStartedAtNanoseconds = nil
        audioTimeline = SpeechAudioTimeline()
        startResultsTask(for: transcriber)

        let milliseconds = elapsedMilliseconds(since: startedAt)
        Telemetry.speech.info(
            "Speech analyzer prepared duration_ms=\(milliseconds, privacy: .public)"
        )
    }

    private func startResultsTask(for transcriber: SpeechTranscriber) {
        resultsTask?.cancel()
        resultsTask = Task { @MainActor [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { return }
                    guard self.resultGate.accepts(result.range) else {
                        continue
                    }
                    let recognizedResult = RecognizedSpeechResult(
                        result,
                        analysisStartedAtNanoseconds: self.analysisStartedAtNanoseconds
                    )
                    #if DEBUG
                    if recognizedResult.inWordAttributeRunMergeCount > 0 {
                        Telemetry.speech.info(
                            "Reassembled speech words in same result attribute_runs=\(recognizedResult.attributeRunCount, privacy: .public) lexical_tokens=\(recognizedResult.tokens.count, privacy: .public) in_word_joins=\(recognizedResult.inWordAttributeRunMergeCount, privacy: .public)"
                        )
                    }
                    #endif
                    self.onResult?(recognizedResult)
                }
            } catch is CancellationError {
                // Expected when prepared recognition resources are released.
            } catch {
                guard let self else { return }
                self.handleRuntimeFailure(error, stage: "result-stream")
            }
        }
    }

    private func startAnalyzerInputSequence() async throws {
        guard let analyzer else {
            throw SpeechServiceError.transcriberUnavailable
        }

        let (inputSequence, continuation) = AsyncStream<AnalyzerInput>.makeStream(
            // Preserve up to 400 ms of opening audio while Apple's worker starts.
            bufferingPolicy: .bufferingOldest(4)
        )
        analyzerInputContinuation = continuation
        latestAnalyzerInputEndTime = nil
        resultGate.beginSession()

        do {
            try await analyzer.start(inputSequence: inputSequence)
        } catch {
            continuation.finish()
            analyzerInputContinuation = nil
            resultGate.endSession()
            throw error
        }
    }

    // MARK: - Audio Capture

    private func startAudioCapture() throws {
        guard let analyzerFormat else {
            throw SpeechServiceError.noCompatibleAudioFormat
        }

        let inputNode = audioEngine.inputNode
        let microphoneFormat = inputNode.outputFormat(forBus: 0)
        guard microphoneFormat.channelCount > 0, microphoneFormat.sampleRate > 0 else {
            throw SpeechServiceError.microphoneUnavailable
        }

        let (audioStream, continuation) = AsyncStream<AudioBufferTransfer>.makeStream(
            // At Apple's documented 100 ms minimum tap duration, this bounds
            // capture-side backlog to about 200 ms instead of 1.6 seconds.
            bufferingPolicy: .bufferingNewest(2)
        )
        audioContinuation = continuation
        audioTimeline.beginCaptureSession()

        let tapBlock = makeAudioTapBlock(
            continuation: continuation,
            timeline: audioTimeline
        )
        let requestedTapFrames = ceil(microphoneFormat.sampleRate * 0.100)
        guard requestedTapFrames <= Double(UInt32.max) else {
            throw SpeechServiceError.microphoneUnavailable
        }
        inputNode.installTap(
            onBus: 0,
            // AVAudioNode documents 100–400 ms as the supported range. Ask
            // for the minimum to get the fastest supported callback cadence.
            bufferSize: AVAudioFrameCount(requestedTapFrames),
            format: microphoneFormat,
            block: tapBlock
        )
        isInputTapInstalled = true

        let analyzerFormatTransfer = AudioFormatTransfer(format: analyzerFormat)
        let converter = self.converter
        guard let analyzerInputContinuation else {
            throw SpeechServiceError.transcriberUnavailable
        }
        let maximumAudioAgeNanoseconds: UInt64 = 250_000_000
        audioTask = Task.detached(priority: .userInitiated) { [weak self] in
            await converter.beginCaptureSession()
            var didPublishAnalyzerTimelineStart = false
            var didPublishSessionStart = false
            var didLogTapShape = false
            var observedMicrophoneDrops = 0
            var droppedAnalyzerInputs = 0
            var staleCaptureDrops = 0
            var stalePostConversionDrops = 0
            var converterNeedsReset = false
            var latestAnalyzerInputEndTime: CMTime?
            do {
                for await transfer in audioStream {
                    try Task.checkCancellation()
                    if !didLogTapShape {
                        didLogTapShape = true
                        let durationMilliseconds = transfer.durationMilliseconds ?? -1
                        Telemetry.speech.info(
                            "Audio tap frames=\(transfer.buffer.frameLength, privacy: .public) rate=\(transfer.buffer.format.sampleRate, privacy: .public) duration_ms=\(durationMilliseconds, privacy: .public)"
                        )
                    }
                    if transfer.precedingDroppedBufferCount > observedMicrophoneDrops {
                        observedMicrophoneDrops = transfer.precedingDroppedBufferCount
                        if observedMicrophoneDrops == 1
                            || observedMicrophoneDrops.isMultiple(of: 32)
                        {
                            Telemetry.speech.warning(
                                "Microphone buffer drops=\(observedMicrophoneDrops, privacy: .public)"
                            )
                        }
                    }
                    if let age = transfer.ageNanoseconds(
                        at: DispatchTime.now().uptimeNanoseconds
                    ), age > maximumAudioAgeNanoseconds {
                        staleCaptureDrops += 1
                        converterNeedsReset = true
                        if staleCaptureDrops == 1
                            || staleCaptureDrops.isMultiple(of: 32)
                        {
                            Telemetry.speech.warning(
                                "Stale capture drops=\(staleCaptureDrops, privacy: .public) age_ms=\(Double(age) / 1_000_000, privacy: .public)"
                            )
                        }
                        continue
                    }
                    if converterNeedsReset {
                        await converter.resetAfterInputDiscontinuity()
                        converterNeedsReset = false
                    }
                    let convertedAnalyzerInputs = try await converter.convert(
                        transfer,
                        to: analyzerFormatTransfer
                    )
                    if let age = transfer.ageNanoseconds(
                        at: DispatchTime.now().uptimeNanoseconds
                    ), age > maximumAudioAgeNanoseconds {
                        stalePostConversionDrops += 1
                        converterNeedsReset = true
                        if stalePostConversionDrops == 1
                            || stalePostConversionDrops.isMultiple(of: 32)
                        {
                            Telemetry.speech.warning(
                                "Stale post-conversion drops=\(stalePostConversionDrops, privacy: .public) age_ms=\(Double(age) / 1_000_000, privacy: .public)"
                            )
                        }
                        continue
                    }
                    if !didPublishAnalyzerTimelineStart,
                        let analyzerStart =
                            convertedAnalyzerInputs.first?.startTime,
                        let timelineOrigin =
                            transfer.analyzerTimelineOriginUptimeNanoseconds(
                                for: analyzerStart
                            )
                    {
                        await self?.setAnalysisTimelineStart(timelineOrigin)
                        didPublishAnalyzerTimelineStart = true
                    }
                    if !didPublishSessionStart,
                        let sessionStartTime =
                            convertedAnalyzerInputs.first?.startTime
                    {
                        await self?.recordSessionAudioStart(sessionStartTime)
                        didPublishSessionStart = true
                    }
                    for convertedAnalyzerInput in convertedAnalyzerInputs {
                        let yieldResult = analyzerInputContinuation.yield(
                            convertedAnalyzerInput.input
                        )
                        if case .dropped = yieldResult {
                            droppedAnalyzerInputs += 1
                            if droppedAnalyzerInputs == 1
                                || droppedAnalyzerInputs.isMultiple(of: 32)
                            {
                                Telemetry.speech.warning(
                                    "Analyzer input drops=\(droppedAnalyzerInputs, privacy: .public)"
                                )
                            }
                        }
                        if case .terminated = yieldResult {
                            continue
                        }
                        if let endTime = convertedAnalyzerInput.endTime {
                            latestAnalyzerInputEndTime = endTime
                        }
                    }
                }

            } catch is CancellationError {
                // Expected when Listening mode is stopped.
            } catch {
                await self?.recordAnalyzerInputEnd(latestAnalyzerInputEndTime)
                await self?.handleAudioStreamFailure(error)
                return
            }
            await self?.recordAnalyzerInputEnd(latestAnalyzerInputEndTime)
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    private func setAnalysisTimelineStart(_ nanoseconds: UInt64) {
        // Each microphone session has a new wall-clock origin mapped onto the
        // analyzer's continuous audio-only timeline.
        analysisStartedAtNanoseconds = nanoseconds
    }

    private func recordSessionAudioStart(_ time: CMTime) {
        resultGate.recordSessionStart(time)
    }

    private func recordAnalyzerInputEnd(_ time: CMTime?) {
        guard let time, time.isNumeric else { return }
        if let latestAnalyzerInputEndTime,
            CMTimeCompare(time, latestAnalyzerInputEndTime) <= 0
        {
            return
        }
        latestAnalyzerInputEndTime = time
    }

    // MARK: - Teardown and Failure Handling

    /// Stops all microphone and input-stream work while leaving the prepared
    /// analyzer available for the next Listening session.
    private func stopCurrentInputSequence() async {
        resultGate.endSession()

        if audioEngine.isRunning {
            audioEngine.pause()
        }
        if isInputTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            isInputTapInstalled = false
        }
        audioContinuation?.finish()
        audioContinuation = nil

        audioTask?.cancel()
        await audioTask?.value
        audioTask = nil
        await converter.endCaptureSession()
        analyzerInputContinuation?.finish()
        analyzerInputContinuation = nil

        if let analyzer,
            let latestAnalyzerInputEndTime,
            latestAnalyzerInputEndTime.isNumeric
        {
            // Commands are dispatched from fast partial results. When the user
            // stops Listening, discard any unfinished older analysis instead
            // of draining it into a later session.
            await analyzer.cancelAnalysis(before: latestAnalyzerInputEndTime)
        }
        latestAnalyzerInputEndTime = nil
    }

    private func releasePreparedResources(reason: StaticString) async {
        if let preparedResourceReleaseTask {
            await preparedResourceReleaseTask.value
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performPreparedResourceRelease(reason: reason)
        }
        preparedResourceReleaseTask = task
        await task.value
        preparedResourceReleaseTask = nil
    }

    private func performPreparedResourceRelease(reason: StaticString) async {
        let preparation = pendingPreparation
        preparation?.task.cancel()
        if let preparation {
            _ = try? await preparation.task.value
            clearPreparation(ifGenerationMatches: preparation.generation)
        }

        await stopCurrentInputSequence()
        audioEngine.stop()
        await converter.reset()

        let activeResultsTask = resultsTask
        activeResultsTask?.cancel()
        if let analyzer {
            await analyzer.cancelAndFinishNow()
        }
        await activeResultsTask?.value
        resultsTask = nil
        analyzer = nil
        analyzerFormat = nil
        analysisStartedAtNanoseconds = nil
        currentVocabulary.removeAll(keepingCapacity: false)
        resultGate.endSession()
        audioTimeline = SpeechAudioTimeline()
        releasePreparedResourcesAfterStop = false

        Telemetry.speech.info(
            "Speech analyzer resources released reason=\(reason, privacy: .public)"
        )
    }

    private func handleMemoryPressure() {
        backgroundPrewarmingAllowed = false
        guard analyzer != nil || pendingPreparation != nil else { return }
        releasePreparedResourcesAfterStop = true
        Telemetry.speech.info(
            "Speech analyzer memory-pressure release requested active=\(self.isActive, privacy: .public)"
        )

        guard !isActive else { return }
        guard preparedResourceReleaseTask == nil else { return }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performPreparedResourceRelease(reason: "memory-pressure")
            self.preparedResourceReleaseTask = nil
        }
        preparedResourceReleaseTask = task
    }

    private func handleRuntimeFailure(_ error: Error, stage: StaticString) {
        guard state != .stopped, state != .stopping else { return }
        state = .failed(error.localizedDescription)
        Telemetry.speech.error(
            "\(stage, privacy: .public) failed: \(error.localizedDescription, privacy: .private)"
        )

        // The stream task must return before teardown awaits it. Yielding in a
        // sibling task avoids self-await while still removing the tap promptly.
        Task { [weak self] in
            await Task.yield()
            guard let self, self.isFailure else { return }
            await self.releasePreparedResources(reason: "runtime-failure")
        }
    }

    private func handleAudioStreamFailure(_ error: Error) {
        if state == .stopping {
            Telemetry.speech.error(
                "Audio teardown failed: \(error.localizedDescription, privacy: .private)"
            )
            return
        }
        handleRuntimeFailure(error, stage: "audio-stream")
    }

    private func elapsedMilliseconds(since startedAt: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
    }

    // MARK: - Command Vocabulary

    private func commandVocabulary(namedCopies: [String]) -> [String] {
        var vocabulary = VoiceCommandParser.canonicalSpokenSlotNumbers.flatMap {
            ["copy \($0)", "paste \($0)", "delete \($0)"]
        }
        vocabulary += [
            "permanent copy",
            "clear copies",
            "clear temporary copies",
            "make permanent",
            "rename to",
        ]
        vocabulary += namedCopies.flatMap {
            [
                "copy \($0)",
                "paste \($0)",
                "permanent copy \($0)",
                "delete \($0)",
                "make \($0) permanent",
                "rename \($0) to",
            ]
        }
        return vocabulary
    }
}

// MARK: - Recognized Results

struct RecognizedSpeechResult: Sendable {
    let text: String
    let tokens: [StreamingVoiceCommandToken]
    let range: CMTimeRange
    let finalizationTime: CMTime
    let isFinal: Bool
    let minimumConfidence: Double?
    let receivedAtNanoseconds: UInt64
    let audioEndUptimeNanoseconds: UInt64?
    let attributeRunCount: Int
    let inWordAttributeRunMergeCount: Int
    private let analysisStartedAtNanoseconds: UInt64?

    #if DEBUG
    let alternatives: [String]
    #endif

    init(
        _ result: SpeechTranscriber.Result,
        analysisStartedAtNanoseconds: UInt64?
    ) {
        // Capture delivery before attributed-text assembly so `speech_ms`
        // measures Apple's result latency, while preparation timing below
        // accounts for Ctrl-Say's own result transformation separately.
        receivedAtNanoseconds = DispatchTime.now().uptimeNanoseconds
        let attributedText = result.text
        text = String(attributedText.characters)
        let fragments = attributedText.runs.map { run in
            SpeechAttributedTextFragment(
                String(attributedText[run.range].characters),
                range: run.audioTimeRange.map(SpeechResultRange.init),
                confidence: run.transcriptionConfidence
            )
        }
        let tokenAssembly = SpeechTokenAssembler.assemble(fragments)
        tokens = tokenAssembly.tokens
        attributeRunCount = tokenAssembly.sourceFragmentCount
        inWordAttributeRunMergeCount = tokenAssembly.inWordBoundaryMergeCount
        range = result.range
        finalizationTime = result.resultsFinalizationTime
        isFinal = result.isFinal
        minimumConfidence = attributedText.runs
            .compactMap(\.transcriptionConfidence)
            .min()
        self.analysisStartedAtNanoseconds = analysisStartedAtNanoseconds
        audioEndUptimeNanoseconds = Self.audioEndUptimeNanoseconds(
            for: result.range.end,
            analysisStartedAtNanoseconds: analysisStartedAtNanoseconds
        )

        #if DEBUG
        alternatives = result.alternatives.map { String($0.characters) }
        #endif
    }

    func audioEndUptimeNanoseconds(
        for range: SpeechResultRange
    ) -> UInt64? {
        Self.audioEndUptimeNanoseconds(
            for: range.end,
            analysisStartedAtNanoseconds: analysisStartedAtNanoseconds
        )
    }

    static func audioEndUptimeNanoseconds(
        for audioEnd: CMTime,
        analysisStartedAtNanoseconds: UInt64?
    ) -> UInt64? {
        guard let analysisStartedAtNanoseconds else { return nil }
        let seconds = audioEnd.seconds
        guard seconds.isFinite, seconds >= 0 else { return nil }

        let offset = seconds * 1_000_000_000
        guard offset <= Double(UInt64.max - analysisStartedAtNanoseconds) else {
            return nil
        }
        return analysisStartedAtNanoseconds + UInt64(offset)
    }
}

// MARK: - Errors

enum SpeechServiceError: LocalizedError {
    case transcriberUnavailable
    case localeUnsupported
    case noCompatibleAudioFormat
    case microphoneUnavailable
    case audioConversionUnavailable
    case audioConversionFailed

    var errorDescription: String? {
        switch self {
        case .transcriberUnavailable:
            "Apple’s current on-device transcriber is unavailable on this Mac."
        case .localeUnsupported:
            "The current language is not supported by the on-device transcriber."
        case .noCompatibleAudioFormat:
            "No compatible microphone format is available for transcription."
        case .microphoneUnavailable:
            "No usable microphone input is available."
        case .audioConversionUnavailable, .audioConversionFailed:
            "Microphone audio could not be prepared for on-device transcription."
        }
    }
}
