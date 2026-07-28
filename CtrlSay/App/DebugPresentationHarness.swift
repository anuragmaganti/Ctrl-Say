#if DEBUG
import Foundation

/// Owns command-line presentation fixtures and stress tools used by local UI
/// verification. The harness is excluded from Release builds and always uses
/// the `AppModel` supplied by `AppDelegate`.
@MainActor
final class DebugPresentationHarness {
    private enum Argument {
        static let seedHUD = "-CtrlSaySeedHUDForTesting"
        static let seedSingleTemporary = "-CtrlSaySeedSingleTemporaryForTesting"
        static let showHUD = "-CtrlSayShowHUDForTesting"
        static let showPermanentHUD = "-CtrlSayShowHUDPermanentForTesting"
        static let showNotchListening = "-CtrlSayShowNotchListeningForTesting"
        static let showNotchCopy = "-CtrlSayShowNotchCopyForTesting"
        static let stressNotch = "-CtrlSayStressNotchForTesting"
        static let stressHUD = "-CtrlSayStressHUDLayoutForTesting"
        static let stressSurfaces = "-CtrlSayStressPresentationSurfacesForTesting"
    }

    private let model: AppModel
    private let hudEditingSession: ClipboardHUDEditingSession
    private let hudPresentationState: ClipboardHUDPresentationState
    private let notchPresentationState: NotchFeedbackPresentationState
    private let ensureHUDPanel: () -> ClipboardHUDPanelController
    private let ensureNotchPanel: () -> NotchFeedbackPanelController

    init(
        model: AppModel,
        hudEditingSession: ClipboardHUDEditingSession,
        hudPresentationState: ClipboardHUDPresentationState,
        notchPresentationState: NotchFeedbackPresentationState,
        ensureHUDPanel: @escaping () -> ClipboardHUDPanelController,
        ensureNotchPanel: @escaping () -> NotchFeedbackPanelController
    ) {
        self.model = model
        self.hudEditingSession = hudEditingSession
        self.hudPresentationState = hudPresentationState
        self.notchPresentationState = notchPresentationState
        self.ensureHUDPanel = ensureHUDPanel
        self.ensureNotchPanel = ensureNotchPanel
    }

    static func requiresEphemeralStorage(arguments: [String]) -> Bool {
        arguments.contains(Argument.seedHUD)
            || arguments.contains(Argument.stressHUD)
            || arguments.contains(Argument.stressSurfaces)
    }

    func run(arguments: [String]) {
        if arguments.contains(Argument.seedHUD) {
            Task { @MainActor [weak self] in
                guard let self else { return }
                await model.waitForPermanentStorageRestore()
                seedHUD(singleTemporaryOnly: arguments.contains(Argument.seedSingleTemporary))
            }
        }
        if arguments.contains(Argument.showPermanentHUD) {
            hudPresentationState.selectedCollection = .permanent
        }
        if arguments.contains(Argument.showHUD)
            || arguments.contains(Argument.showPermanentHUD)
        {
            model.setClipboardHUDPresented(true)
        }
        if arguments.contains(Argument.showNotchListening) {
            _ = ensureNotchPanel()
            notchPresentationState.setListeningActivity(.listening)
        }
        if arguments.contains(Argument.showNotchCopy) {
            _ = ensureNotchPanel()
            notchPresentationState.setListeningActivity(.listening)
            notchPresentationState.presentPersistentPreview(
                .success(action: .copy, label: "House")
            )
        }
        if arguments.contains(Argument.stressNotch) {
            runNotchStressPreview()
        }
        if arguments.contains(Argument.stressHUD) {
            model.setClipboardHUDPresented(true)
            runHUDLayoutStressPreview()
        }
        if arguments.contains(Argument.stressSurfaces) {
            runPresentationSurfaceStressPreview()
        }
    }

    private func runPresentationSurfaceStressPreview() {
        let notchPanel = ensureNotchPanel()
        let hudPanel = ensureHUDPanel()

        Task { @MainActor [weak self] in
            guard let self else { return }
            await model.waitForPermanentStorageRestore()

            hudPanel.show()
            notchPresentationState.setListeningActivity(.listening)

            let transitionCount = 480
            for index in 0..<transitionCount {
                let payload = stressPayload(index: index)
                switch index % 10 {
                case 0:
                    try? model.slots.set(payload, at: 1)
                case 1:
                    try? model.slots.set(payload, named: "stress")
                case 2:
                    hudPresentationState.selectedCollection =
                        index
                            .isMultiple(of: 2) ? .numbered : .permanent
                    switch (index / 12) % 3 {
                    case 0:
                        notchPresentationState.setInteractionMode(.passive)
                    case 1:
                        notchPresentationState.setInteractionMode(.compactInteractive)
                    default:
                        notchPresentationState.setInteractionMode(.expandedInteractive)
                    }
                case 3:
                    switch (index / 12) % 4 {
                    case 0:
                        notchPresentationState.setListeningActivity(.preparing)
                    case 1:
                        notchPresentationState.present(
                            .success(action: .copy, label: "Stress")
                        )
                    case 2:
                        notchPresentationState.present(
                            .failure(message: "Stress failure")
                        )
                    default:
                        notchPresentationState.setListeningActivity(.inactive)
                    }
                case 4:
                    hudPanel.hide()
                case 5:
                    hudPanel.show()
                case 6:
                    notchPresentationState.setInteractionMode(
                        index.isMultiple(of: 2)
                            ? .compactInteractive
                            : .passive
                    )
                case 7:
                    let target = ClipboardHUDEditingSession.Target(
                        payloadID: UUID(),
                        location: .permanent,
                        field: .name
                    )
                    if hudEditingSession.begin(
                        target: target,
                        initialDraft: "Stress",
                        commit: { _ in }
                    ) != nil {
                        hudEditingSession.cancel(target)
                    }
                case 8:
                    _ = model.slots.removeNamed("stress")
                default:
                    _ = model.slots.removeNumbered(1)
                    notchPresentationState.setListeningActivity(.listening)
                }
                try? await Task.sleep(for: .milliseconds(4))
            }

            hudEditingSession.prepareForDismissal()
            hudPanel.hide()
            notchPresentationState.setInteractionMode(.passive)
            notchPresentationState.setListeningActivity(.inactive)
            try? await Task.sleep(for: .milliseconds(350))
            notchPanel.hideImmediately()
            Telemetry.interface.info(
                "Presentation surface stress complete transitions=\(transitionCount, privacy: .public)"
            )
        }
    }

    private func runHUDLayoutStressPreview() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await model.waitForPermanentStorageRestore()

            let transitionCount = 240
            for index in 0..<transitionCount {
                let payload = stressPayload(index: index)

                switch index % 6 {
                case 0:
                    try? model.slots.set(payload, at: 1)
                case 1:
                    try? model.slots.setTemporaryNamed(payload, named: "stress")
                case 2:
                    _ = model.slots.removeNumbered(1)
                case 3:
                    try? model.slots.set(payload, named: "stress")
                case 4:
                    _ = model.slots.removeTemporaryNamed("stress")
                default:
                    _ = model.slots.removeNamed("stress")
                }

                hudPresentationState.selectedCollection =
                    index.isMultiple(of: 2)
                    ? .numbered
                    : .permanent
                try? await Task.sleep(for: .milliseconds(5))
            }

            Telemetry.interface.info(
                "HUD layout stress complete transitions=\(transitionCount, privacy: .public)"
            )
        }
    }

    private func runNotchStressPreview() {
        _ = ensureNotchPanel()
        Task { @MainActor [weak self] in
            guard let self else { return }
            let transitionCount = 360
            for index in 0..<transitionCount {
                switch index % 8 {
                case 0:
                    notchPresentationState.setListeningActivity(.preparing)
                case 1, 7:
                    notchPresentationState.setListeningActivity(.listening)
                case 2:
                    notchPresentationState.present(
                        .success(action: .copy, label: "House")
                    )
                case 3:
                    notchPresentationState.setListeningActivity(.inactive)
                case 4:
                    notchPresentationState.setListeningActivity(.preparing)
                case 5:
                    notchPresentationState.present(
                        .success(action: .paste, label: "2")
                    )
                default:
                    notchPresentationState.setListeningActivity(.inactive)
                }
                try? await Task.sleep(for: .milliseconds(12))
            }
            notchPresentationState.setListeningActivity(.listening)
            Telemetry.interface.info(
                "Notch stress complete transitions=\(transitionCount, privacy: .public)"
            )
        }
    }

    private func seedHUD(singleTemporaryOnly: Bool) {
        let numberedSeedCount = singleTemporaryOnly ? 1 : 10
        for number in 1...numberedSeedCount {
            let text = "Example clipboard content for slot \(number) with a bounded two-line preview."
            try? model.slots.set(textPayload(text), at: number)
        }

        guard !singleTemporaryOnly else { return }

        try? model.slots.setTemporaryNamed(
            textPayload("Session-only content stored under a memorable spoken name."),
            named: "house"
        )
        try? model.slots.set(
            textPayload("123 Example Street, Example City"),
            named: "address"
        )
    }

    private func stressPayload(index: Int) -> ClipboardPayload {
        textPayload("Presentation stress payload \(index)")
    }

    private func textPayload(_ text: String) -> ClipboardPayload {
        let data = Data(text.utf8)
        return ClipboardPayload(
            items: [
                PasteboardItemPayload(
                    representations: [
                        PasteboardRepresentation(
                            typeIdentifier: "public.utf8-plain-text",
                            data: data
                        )
                    ]
                )
            ],
            kind: .text,
            preview: ClipboardPayload.preview(forText: text),
            byteCount: data.count
        )
    }
}
#endif
