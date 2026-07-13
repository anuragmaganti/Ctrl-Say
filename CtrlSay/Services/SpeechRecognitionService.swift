import AVFoundation
import CoreMedia
import Foundation
import Observation
import Speech

@MainActor
@Observable
final class SpeechRecognitionService {
    private static let commandLocale = Locale(identifier: "en-US")

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

    @ObservationIgnored private let audioEngine = AVAudioEngine()
    @ObservationIgnored private let converter = AudioBufferConverter()
    @ObservationIgnored private var analyzer: SpeechAnalyzer?
    @ObservationIgnored private var transcriber: SpeechTranscriber?
    @ObservationIgnored private var analyzerFormat: AVAudioFormat?
    @ObservationIgnored private var analyzerInputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    @ObservationIgnored private var audioContinuation: AsyncStream<AudioBufferTransfer>.Continuation?
    @ObservationIgnored private var audioTask: Task<Void, Never>?
    @ObservationIgnored private var resultsTask: Task<Void, Never>?
    @ObservationIgnored private var isInputTapInstalled = false
    @ObservationIgnored private var analysisStartedAtNanoseconds: UInt64?
    @ObservationIgnored private var teardownTask: Task<Void, Never>?

    func start(vocabulary: [String]) async {
        guard state == .stopped || isFailure else { return }
        guard !Task.isCancelled else { return }
        if isFailure {
            await tearDown(finalize: false)
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
            try await configure(vocabulary: vocabulary)
            try Task.checkCancellation()
            try startAudioCapture()
            state = .listening
            Telemetry.speech.info("On-device listening started")
        } catch is CancellationError {
            await tearDown(finalize: false)
            state = .stopped
            Telemetry.speech.info("Listening startup cancelled")
        } catch {
            await tearDown(finalize: false)
            state = .failed(error.localizedDescription)
            Telemetry.speech.error("Listening failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    func stop() async {
        guard state != .stopped, state != .stopping else { return }
        state = .stopping
        await tearDown(finalize: true)
        state = .stopped
        Telemetry.speech.info("Listening stopped")
    }

    @discardableResult
    func updateVocabulary(_ vocabulary: [String]) async -> Bool {
        guard state == .listening, let analyzer else { return false }
        let context = AnalysisContext()
        context.contextualStrings[.general] = commandVocabulary(namedCopies: vocabulary)
        do {
            try await analyzer.setContext(context)
            return true
        } catch {
            Telemetry.speech.error("Could not update command vocabulary: \(error.localizedDescription, privacy: .private)")
            return false
        }
    }

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

    private var isFailure: Bool {
        if case .failed = state { return true }
        return false
    }

    private func configure(vocabulary: [String]) async throws {
        guard SpeechTranscriber.isAvailable else {
            throw SpeechServiceError.transcriberUnavailable
        }
        // Ctrl-Say's v1 command grammar is English. Using the Mac's current
        // locale would make identical commands fail on non-English systems.
        guard let locale = await SpeechTranscriber.supportedLocale(
            equivalentTo: Self.commandLocale
        ) else {
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
        self.transcriber = transcriber

        if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try Task.checkCancellation()
            state = .downloadingModel
            try await installation.downloadAndInstall()
            try Task.checkCancellation()
            state = .preparing
        }

        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw SpeechServiceError.noCompatibleAudioFormat
        }
        try Task.checkCancellation()
        self.analyzerFormat = analyzerFormat

        let context = AnalysisContext()
        context.contextualStrings[.general] = commandVocabulary(namedCopies: vocabulary)

        let (inputSequence, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream(
            // Keep only the current analyzer input. Explicit audio timestamps
            // let SpeechAnalyzer handle an omitted older buffer as a gap.
            bufferingPolicy: .bufferingNewest(1)
        )
        analyzerInputContinuation = inputContinuation

        let analyzer = SpeechAnalyzer(
            inputSequence: inputSequence,
            modules: [transcriber],
            options: .init(priority: .userInitiated, modelRetention: .whileInUse),
            analysisContext: context
        )
        self.analyzer = analyzer
        try await analyzer.prepareToAnalyze(in: analyzerFormat)
        try Task.checkCancellation()

        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { return }
                    self.onResult?(
                        RecognizedSpeechResult(
                            result,
                            analysisStartedAtNanoseconds: self.analysisStartedAtNanoseconds
                        )
                    )
                }
            } catch is CancellationError {
                // Expected when Listening mode is stopped.
            } catch {
                guard let self else { return }
                self.handleRuntimeFailure(error, stage: "result-stream")
            }
        }
    }

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

        let tapBlock = makeAudioTapBlock(continuation: continuation)
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
            var didPublishTimelineStart = false
            var didLogTapShape = false
            var observedMicrophoneDrops = 0
            var droppedAnalyzerInputs = 0
            var staleCaptureDrops = 0
            var stalePostConversionDrops = 0
            var converterNeedsReset = false
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
                    if !didPublishTimelineStart,
                       let timelineStart = transfer.timelineStartUptimeNanoseconds {
                        await self?.setAnalysisTimelineStartIfNeeded(timelineStart)
                        didPublishTimelineStart = true
                    }
                    if transfer.precedingDroppedBufferCount > observedMicrophoneDrops {
                        observedMicrophoneDrops = transfer.precedingDroppedBufferCount
                        if observedMicrophoneDrops == 1
                            || observedMicrophoneDrops.isMultiple(of: 32) {
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
                            || staleCaptureDrops.isMultiple(of: 32) {
                            Telemetry.speech.warning(
                                "Stale capture drops=\(staleCaptureDrops, privacy: .public) age_ms=\(Double(age) / 1_000_000, privacy: .public)"
                            )
                        }
                        continue
                    }
                    if converterNeedsReset {
                        await converter.reset()
                        converterNeedsReset = false
                    }
                    let analyzerInputs = try await converter.convert(
                        transfer,
                        to: analyzerFormatTransfer
                    )
                    if let age = transfer.ageNanoseconds(
                        at: DispatchTime.now().uptimeNanoseconds
                    ), age > maximumAudioAgeNanoseconds {
                        stalePostConversionDrops += 1
                        converterNeedsReset = true
                        if stalePostConversionDrops == 1
                            || stalePostConversionDrops.isMultiple(of: 32) {
                            Telemetry.speech.warning(
                                "Stale post-conversion drops=\(stalePostConversionDrops, privacy: .public) age_ms=\(Double(age) / 1_000_000, privacy: .public)"
                            )
                        }
                        continue
                    }
                    for analyzerInput in analyzerInputs {
                        let yieldResult = analyzerInputContinuation.yield(analyzerInput)
                        if case .dropped = yieldResult {
                            droppedAnalyzerInputs += 1
                            if droppedAnalyzerInputs == 1
                                || droppedAnalyzerInputs.isMultiple(of: 32) {
                                Telemetry.speech.warning(
                                    "Analyzer input drops=\(droppedAnalyzerInputs, privacy: .public)"
                                )
                            }
                        }
                    }
                }

                let finalInputs = try await converter.finish(to: analyzerFormatTransfer)
                for analyzerInput in finalInputs {
                    if case .dropped = analyzerInputContinuation.yield(analyzerInput) {
                        droppedAnalyzerInputs += 1
                    }
                }
            } catch is CancellationError {
                // Expected when Listening mode is stopped.
            } catch {
                await self?.handleAudioStreamFailure(error)
            }
        }

        audioEngine.prepare()
        analysisStartedAtNanoseconds = nil
        try audioEngine.start()
    }

    private func setAnalysisTimelineStartIfNeeded(_ nanoseconds: UInt64) {
        if analysisStartedAtNanoseconds == nil {
            analysisStartedAtNanoseconds = nanoseconds
        }
    }

    private func tearDown(finalize: Bool) async {
        if let teardownTask {
            await teardownTask.value
            return
        }

        let task = Task { [weak self] in
            guard let self else { return }
            await self.performTearDown(finalize: finalize)
        }
        teardownTask = task
        await task.value
        teardownTask = nil
    }

    private func performTearDown(finalize: Bool) async {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        if isInputTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            isInputTapInstalled = false
        }
        audioContinuation?.finish()
        audioContinuation = nil

        await audioTask?.value
        audioTask = nil
        await converter.reset()
        analyzerInputContinuation?.finish()
        analyzerInputContinuation = nil

        if let analyzer {
            if finalize {
                do {
                    try await analyzer.finalizeAndFinishThroughEndOfInput()
                } catch {
                    Telemetry.speech.error("Finalization failed: \(error.localizedDescription, privacy: .private)")
                    await analyzer.cancelAndFinishNow()
                }
            } else {
                await analyzer.cancelAndFinishNow()
            }
        }

        resultsTask?.cancel()
        await resultsTask?.value
        resultsTask = nil
        analyzer = nil
        transcriber = nil
        analyzerFormat = nil
        analysisStartedAtNanoseconds = nil
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
            await self.tearDown(finalize: false)
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

    private func commandVocabulary(namedCopies: [String]) -> [String] {
        var vocabulary = VoiceCommandParser.canonicalSpokenSlotNumbers.flatMap {
            ["copy \($0)", "paste \($0)"]
        }
        vocabulary += ["permanent copy", "clear copies", "save clipboard"]
        vocabulary += namedCopies.flatMap {
            ["copy \($0)", "paste \($0)", "permanent copy \($0)"]
        }
        return vocabulary
    }
}

struct RecognizedSpeechResult: Sendable {
    let text: String
    let tokens: [StreamingNumberedCommandToken]
    let range: CMTimeRange
    let finalizationTime: CMTime
    let isFinal: Bool
    let minimumConfidence: Double?
    let receivedAtNanoseconds: UInt64
    let audioEndUptimeNanoseconds: UInt64?
    private let analysisStartedAtNanoseconds: UInt64?

#if DEBUG
    let alternatives: [String]
#endif

    init(
        _ result: SpeechTranscriber.Result,
        analysisStartedAtNanoseconds: UInt64?
    ) {
        let attributedText = result.text
        text = String(attributedText.characters)
        tokens = attributedText.runs.map { run in
            StreamingNumberedCommandToken(
                String(attributedText[run.range].characters),
                range: run.audioTimeRange.map(SpeechResultRange.init),
                confidence: run.transcriptionConfidence
            )
        }
        range = result.range
        finalizationTime = result.resultsFinalizationTime
        isFinal = result.isFinal
        minimumConfidence = attributedText.runs
            .compactMap(\.transcriptionConfidence)
            .min()
        receivedAtNanoseconds = DispatchTime.now().uptimeNanoseconds
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

    private static func audioEndUptimeNanoseconds(
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
