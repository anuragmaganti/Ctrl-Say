import AppKit
import SwiftUI

struct DashboardView: View {
    let model: AppModel
    let editingSession: DashboardEditingSession

    @State private var selectedCollection: ClipboardCollection = .numbered
#if DEBUG
    @State private var showsDeveloperDiagnostics = false
#endif

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 13)

            ScrollView {
                VStack(spacing: 14) {
                    GlassEffectContainer(spacing: 12) {
                        listeningModule
                        if !model.isReadyForCommands {
                            setupModule
                        }
                    }

                    copiesSection

#if DEBUG
                    developerDiagnostics
#endif
                }
                .padding(.horizontal, 14)
                .padding(.top, 2)
                .padding(.bottom, 14)
            }
            .scrollIndicators(.automatic)
            .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])

            footer
        }
        .frame(
            minWidth: 320,
            maxWidth: .infinity,
            minHeight: 360,
            maxHeight: .infinity
        )
        .containerShape(.rect(cornerRadius: DashboardPanelMetrics.cornerRadius))
        .onAppear {
            model.refreshPermissions()
        }
    }

    private var header: some View {
        HStack(spacing: 11) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 28, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(statusColor)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Ctrl-Say")
                    .font(.headline)

                HStack(spacing: 5) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)
                    Text(statusTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 10)

            if model.isProcessingCommand {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Processing clipboard command")
            }

            Menu {
                SettingsLink {
                    Label("Settings…", systemImage: "gearshape")
                }

                if model.slots.hasTemporaryCopies {
                    Divider()
                    Button("Clear Temporary Copies", systemImage: "trash") {
                        model.clearTemporaryCopies()
                    }
                    Divider()
                }

                Button("Quit Ctrl-Say", systemImage: "power") {
                    NSApplication.shared.terminate(nil)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(.circle)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Ctrl-Say options")
            .help("Ctrl-Say options")
        }
    }

    private var listeningModule: some View {
        HStack(spacing: 13) {
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.14))
                Image(systemName: listeningModuleIcon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(statusColor)
            }
            .frame(width: 42, height: 42)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(listeningModuleTitle)
                    .font(.callout.weight(.semibold))

                Text(listeningModuleDetail)
                    .font(.caption)
                    .foregroundStyle(
                        model.lastError == nil ? Color.secondary : Color.red
                    )
                    .lineLimit(2)

                Label("Right Option", systemImage: "option")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.tertiary)
                    .labelStyle(.titleAndIcon)
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: 8)
            listeningAction
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(
            .regular.interactive(),
            in: .rect(cornerRadius: 16)
        )
        .accessibilityElement(children: .contain)
    }

    private var listeningAction: some View {
        Button {
            model.toggleListening()
        } label: {
            Group {
                if isListeningTransition {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: listeningButtonIcon)
                        .font(.system(size: 15, weight: .bold))
                }
            }
            .frame(width: 20, height: 20)
        }
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .tint(listeningActionTint)
        .disabled(!model.isReadyForCommands && !model.speech.isActive)
        .accessibilityLabel(listeningButtonTitle)
        .help(listeningButtonTitle)
    }

    private var setupModule: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Finish setup")
                        .font(.callout.weight(.semibold))
                    Text("Complete once for instant voice commands")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(grantedPermissionCount) of 3")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            permissionRow(
                icon: "mic.fill",
                title: "Microphone",
                isGranted: model.speech.microphoneAuthorization == .authorized,
                action: model.requestMicrophoneAccess
            )

            permissionRow(
                icon: "option",
                title: "Right Option",
                isGranted: model.hasKeyboardMonitoringAccess,
                action: model.requestKeyboardMonitoringAccess
            )

            permissionRow(
                icon: "doc.on.clipboard",
                title: "Copy & Paste",
                isGranted: model.hasEventPostingAccess,
                action: model.requestEventPostingAccess
            )
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: .rect(cornerRadius: 14))
    }

    private func permissionRow(
        icon: String,
        title: String,
        isGranted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: isGranted ? "checkmark.circle.fill" : icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isGranted ? .green : .orange)
                .frame(width: 20)
                .accessibilityHidden(true)

            Text(title)
                .font(.callout)

            Spacer()

            if isGranted {
                Text("Allowed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button("Allow", action: action)
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .accessibilityLabel("Allow \(title)")
            }
        }
        .accessibilityElement(children: isGranted ? .combine : .contain)
    }

    private var copiesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Clipboard")
                    .font(.headline)
                Spacer()
                Text(collectionCountLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Picker("Copy collection", selection: selectedCollectionBinding) {
                ForEach(ClipboardCollection.allCases) { collection in
                    Text(collection.rawValue)
                        .tag(collection)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            Group {
                switch selectedCollection {
                case .numbered:
                    numberedCopies
                case .permanent:
                    permanentCopies
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var numberedCopies: some View {
        let numberedSlots = model.slots.numberedSlots
        let namedSlots = model.slots.temporaryNamedSlots
        if numberedSlots.isEmpty && namedSlots.isEmpty {
            emptyState(
                icon: "square.stack.3d.up",
                title: "No temporary copies",
                instruction: "Say “copy one” or “copy house” with something selected."
            )
        } else {
            let rowCount = numberedSlots.count + namedSlots.count
            List {
                ForEach(numberedSlots, id: \.number) { slot in
                    NumberedCopyRow(
                        number: slot.number,
                        payload: slot.payload,
                        paste: {
                            model.pasteNumberedCopy(
                                slot.payload,
                                number: slot.number
                            )
                        },
                        delete: {
                            model.deleteNumberedCopy(slot.number)
                        }
                    )
                    .temporarySlotListRow(verticalInset: 1)
                }

                ForEach(namedSlots, id: \.name) { slot in
                    TemporaryNamedCopyRow(
                        name: slot.name,
                        payload: slot.payload,
                        paste: {
                            model.pasteTemporaryNamedCopy(
                                slot.payload,
                                name: slot.name
                            )
                        },
                        delete: {
                            model.deleteTemporaryNamedCopy(slot.name)
                        }
                    )
                    .temporarySlotListRow(verticalInset: 1)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            .contentMargins(.horizontal, 0, for: .scrollContent)
            .contentMargins(.vertical, 0, for: .scrollContent)
            .frame(height: CGFloat(rowCount * 51))
        }
    }

    @ViewBuilder
    private var permanentCopies: some View {
        let slots = model.slots.namedSlots
        VStack(spacing: 8) {
            PermanentStorageStatusRow(
                state: model.permanentStorageState,
                retry: model.retryPermanentStorage
            )

            if !model.permanentStorageState.isLoading,
               !model.permanentStorageState.isUnavailable {
                if slots.isEmpty {
                    emptyState(
                        icon: "pin",
                        title: "No permanent copies",
                        instruction: "Say “permanent copy house” with something selected."
                    )
                } else {
                    LazyVStack(spacing: 2) {
                        ForEach(slots, id: \.name) { slot in
                            PermanentCopyRow(
                                name: slot.name,
                                payload: slot.payload,
                                editingSession: editingSession,
                                paste: {
                                    model.pastePermanentCopy(slot.payload.id)
                                },
                                delete: {
                                    model.deletePermanentCopy(slot.payload.id)
                                },
                                rename: { payloadID, requestedName in
                                    try model.renamePermanentCopy(
                                        payloadID,
                                        to: requestedName
                                    )
                                },
                                updateText: { payloadID, text in
                                    try model.updatePermanentCopyText(
                                        payloadID,
                                        text: text
                                    )
                                }
                            )
                        }
                    }
                }
            }
        }
    }

    private func emptyState(
        icon: String,
        title: String,
        instruction: String
    ) -> some View {
        VStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(title)
                .font(.callout.weight(.semibold))
            Text(instruction)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 132)
        .padding(.horizontal, 20)
        .accessibilityElement(children: .combine)
    }

#if DEBUG
    private var developerDiagnostics: some View {
        DisclosureGroup(isExpanded: $showsDeveloperDiagnostics) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Memory-only • Never logged")
                    .foregroundStyle(.tertiary)

                diagnosticRow(
                    "Transcript",
                    model.debugDiagnostics.transcript.isEmpty
                        ? "No speech yet"
                        : model.debugDiagnostics.transcript
                )
                diagnosticRow("Result", model.debugDiagnostics.resultState)
                diagnosticRow("Confidence", model.debugDiagnostics.confidence)
                diagnosticRow("Parser", model.debugDiagnostics.parseOutcome)
                diagnosticRow("Recognition", model.debugDiagnostics.recognitionLatency)
                diagnosticRow("Tokenization", model.debugDiagnostics.tokenization)
                diagnosticRow("Name revision", model.debugDiagnostics.namedCopyRevision)
                diagnosticRow("Queue", model.debugDiagnostics.queue)
                diagnosticRow("Clipboard", model.debugDiagnostics.clipboardPath)
                diagnosticRow("Target", model.debugDiagnostics.target)

                if model.debugDiagnostics.alternatives.count > 1 {
                    diagnosticRow(
                        "Alternatives",
                        model.debugDiagnostics.alternatives.dropFirst().prefix(3)
                            .joined(separator: " • ")
                    )
                }
            }
            .font(.caption2.monospaced())
            .padding(.top, 8)
        } label: {
            Label("Developer diagnostics", systemImage: "wrench.and.screwdriver")
                .font(.caption.weight(.semibold))
        }
        .padding(12)
        .background(.quaternary, in: .rect(cornerRadius: 12))
    }

    private func diagnosticRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .leading)
            Text(value)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
#endif

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.fill")
                .font(.caption2)
                .accessibilityHidden(true)
            Text(
                "On-device speech • Temporary copies clear on quit • Permanent copies stay on this Mac"
            )
            .lineLimit(2)
            Spacer(minLength: 8)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .overlay(alignment: .top) {
            Divider()
        }
        .accessibilityElement(children: .combine)
    }

    private var statusTitle: String {
        if !model.isReadyForCommands { return "Setup required" }
        return model.speech.state.label
    }

    private var statusColor: Color {
        if !model.isReadyForCommands { return .orange }
        switch model.speech.state {
        case .listening:
            return .green
        case .requestingMicrophone, .preparing, .downloadingModel, .stopping:
            return .accentColor
        case .failed:
            return .red
        case .stopped:
            return .secondary
        }
    }

    private var listeningModuleTitle: String {
        switch model.speech.state {
        case .listening:
            return "Listening on device"
        case .requestingMicrophone, .preparing, .downloadingModel:
            return "Starting voice commands"
        case .stopping:
            return "Stopping voice commands"
        case .failed:
            return "Voice commands unavailable"
        case .stopped:
            return model.isReadyForCommands ? "Voice commands" : "Voice setup required"
        }
    }

    private var listeningModuleDetail: String {
        if let lastError = model.lastError { return lastError }
        if model.speech.isListening {
            return model.isProcessingCommand ? "Running clipboard command…" : model.lastAction
        }
        return model.isReadyForCommands ? "Ready when you are" : "Allow access below to begin"
    }

    private var listeningModuleIcon: String {
        switch model.speech.state {
        case .listening:
            return "waveform"
        case .failed:
            return "exclamationmark"
        case .requestingMicrophone, .preparing, .downloadingModel, .stopping:
            return "ellipsis"
        case .stopped:
            return model.isReadyForCommands ? "mic.fill" : "checklist"
        }
    }

    private var isListeningTransition: Bool {
        switch model.speech.state {
        case .requestingMicrophone, .preparing, .downloadingModel, .stopping:
            return true
        case .stopped, .listening, .failed:
            return false
        }
    }

    private var listeningButtonTitle: String {
        switch model.speech.state {
        case .requestingMicrophone, .preparing, .downloadingModel:
            return "Cancel starting"
        case .listening:
            return "Stop listening"
        case .stopping:
            return "Start again"
        case .stopped, .failed:
            return model.isReadyForCommands ? "Start listening" : "Complete setup to listen"
        }
    }

    private var listeningButtonIcon: String {
        model.speech.isListening ? "stop.fill" : "waveform"
    }

    private var listeningActionTint: Color {
        model.speech.isActive ? .red : .accentColor
    }

    private var grantedPermissionCount: Int {
        var count = 0
        if model.speech.microphoneAuthorization == .authorized { count += 1 }
        if model.hasKeyboardMonitoringAccess { count += 1 }
        if model.hasEventPostingAccess { count += 1 }
        return count
    }

    private var collectionCountLabel: String {
        let count: Int
        switch selectedCollection {
        case .numbered:
            count = model.slots.temporaryCopyCount
        case .permanent:
            count = model.slots.namedSlots.count
        }
        return count == 1 ? "1 copy" : "\(count) copies"
    }

    private var selectedCollectionBinding: Binding<ClipboardCollection> {
        Binding(
            get: { selectedCollection },
            set: { collection in
                editingSession.prepareForDismissal()
                selectedCollection = collection
            }
        )
    }
}

#if DEBUG
#Preview {
    DashboardView(
        model: AppModel(),
        editingSession: DashboardEditingSession()
    )
        .frame(width: DashboardPanelMetrics.preferredSize.width,
               height: DashboardPanelMetrics.preferredSize.height)
}
#endif
