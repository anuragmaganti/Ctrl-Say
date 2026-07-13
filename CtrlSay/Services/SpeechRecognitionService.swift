import AVFoundation
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
        case failed(String)

        var label: String {
            switch self {
            case .stopped: "Not listening"
            case .requestingMicrophone: "Requesting microphone access…"
            case .preparing: "Preparing on-device recognition…"
            case .downloadingModel: "Downloading Apple’s language model…"
            case .listening: "Listening"
            case .failed(let message): message
            }
        }
    }

    private(set) var state: State = .stopped
    private(set) var latestTranscript = ""
    private(set) var microphoneAuthorization = AVCaptureDevice.authorizationStatus(for: .audio)

    var isListening: Bool { state == .listening }

    @ObservationIgnored var onTranscript: ((String, Bool) -> Void)?

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

    func start(vocabulary: [String]) async {
        guard state == .stopped || isFailure else { return }
        state = .requestingMicrophone

        guard await requestMicrophoneAccess() else {
            state = .failed("Microphone access is required.")
            return
        }

        do {
            state = .preparing
            try await configure(vocabulary: vocabulary)
            try startAudioCapture()
            state = .listening
            Telemetry.speech.info("On-device listening started")
        } catch {
            await tearDown(finalize: false)
            state = .failed(error.localizedDescription)
            Telemetry.speech.error("Listening failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stop() async {
        guard state != .stopped else { return }
        await tearDown(finalize: true)
        state = .stopped
        latestTranscript = ""
        Telemetry.speech.info("Listening stopped")
    }

    func updateVocabulary(_ vocabulary: [String]) async {
        guard let analyzer else { return }
        let context = AnalysisContext()
        context.contextualStrings[.general] = commandVocabulary(namedCopies: vocabulary)
        do {
            try await analyzer.setContext(context)
        } catch {
            Telemetry.speech.error("Could not update command vocabulary: \(error.localizedDescription, privacy: .public)")
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

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [.transcriptionConfidence]
        )
        self.transcriber = transcriber

        if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            state = .downloadingModel
            try await installation.downloadAndInstall()
            state = .preparing
        }

        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw SpeechServiceError.noCompatibleAudioFormat
        }
        self.analyzerFormat = analyzerFormat

        let context = AnalysisContext()
        context.contextualStrings[.general] = commandVocabulary(namedCopies: vocabulary)

        let (inputSequence, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
        analyzerInputContinuation = inputContinuation

        let analyzer = SpeechAnalyzer(
            inputSequence: inputSequence,
            modules: [transcriber],
            options: .init(priority: .userInitiated, modelRetention: .whileInUse),
            analysisContext: context
        )
        self.analyzer = analyzer
        try await analyzer.prepareToAnalyze(in: analyzerFormat)

        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { return }
                    let text = String(result.text.characters)
                    self.latestTranscript = text
                    self.onTranscript?(text, result.isFinal)
                }
            } catch is CancellationError {
                // Expected when Listening mode is stopped.
            } catch {
                guard let self else { return }
                self.state = .failed(error.localizedDescription)
                Telemetry.speech.error("Result stream failed: \(error.localizedDescription, privacy: .public)")
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
            bufferingPolicy: .bufferingNewest(256)
        )
        audioContinuation = continuation

        let tapBlock = makeAudioTapBlock(continuation: continuation)
        inputNode.installTap(
            onBus: 0,
            bufferSize: 1_024,
            format: microphoneFormat,
            block: tapBlock
        )
        isInputTapInstalled = true

        let analyzerFormatTransfer = AudioFormatTransfer(format: analyzerFormat)
        audioTask = Task { [weak self] in
            guard let self else { return }
            do {
                for await transfer in audioStream {
                    try Task.checkCancellation()
                    let analyzerInput = try await self.converter.convert(transfer, to: analyzerFormatTransfer)
                    self.analyzerInputContinuation?.yield(analyzerInput)
                }
            } catch is CancellationError {
                // Expected when Listening mode is stopped.
            } catch {
                self.state = .failed(error.localizedDescription)
                Telemetry.speech.error("Audio stream failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    private func tearDown(finalize: Bool) async {
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
        analyzerInputContinuation?.finish()
        analyzerInputContinuation = nil

        if let analyzer {
            if finalize {
                do {
                    try await analyzer.finalizeAndFinishThroughEndOfInput()
                } catch {
                    Telemetry.speech.error("Finalization failed: \(error.localizedDescription, privacy: .public)")
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
    }

    private func commandVocabulary(namedCopies: [String]) -> [String] {
        let numbers = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]
        var vocabulary = numbers.flatMap { ["copy \($0)", "paste \($0)"] }
        vocabulary += ["permanent copy", "clear copies", "save clipboard"]
        vocabulary += namedCopies.flatMap { ["paste \($0)", "permanent copy \($0)"] }
        return vocabulary
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
