import AppKit
import SwiftUI

struct DashboardView: View {
    let model: AppModel

#if DEBUG
    @State private var showsDeveloperDiagnostics = false
#endif

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
#if DEBUG
            developerDiagnostics
#endif
            permissions
            Divider()
            slots
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 360, height: 500)
        .onAppear {
            model.refreshPermissions()
        }
    }

#if DEBUG
    private var developerDiagnostics: some View {
        DisclosureGroup(
            isExpanded: $showsDeveloperDiagnostics
        ) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Memory-only diagnostic data • never logged")
                    .foregroundStyle(.secondary)

                diagnosticRow("Transcript", model.debugDiagnostics.transcript.isEmpty
                    ? "No speech yet"
                    : model.debugDiagnostics.transcript)
                diagnosticRow("Result", model.debugDiagnostics.resultState)
                diagnosticRow("Confidence", model.debugDiagnostics.confidence)
                diagnosticRow("Parser", model.debugDiagnostics.parseOutcome)
                diagnosticRow("Recognition", model.debugDiagnostics.recognitionLatency)
                diagnosticRow("Queue", model.debugDiagnostics.queue)
                diagnosticRow("Clipboard path", model.debugDiagnostics.clipboardPath)
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
            .padding(.top, 6)
        } label: {
            Label("Developer diagnostics", systemImage: "wrench.and.screwdriver")
                .font(.caption.weight(.semibold))
        }
    }

    private func diagnosticRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
#endif

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ctrl-Say")
                        .font(.title2.weight(.semibold))
                    Text(model.isReadyForCommands ? model.speech.state.label : "Setup required")
                        .font(.caption)
                        .foregroundStyle(model.speech.isListening ? .green : .secondary)
                }
                Spacer()
                if model.isProcessingCommand {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            Button {
                model.toggleListening()
            } label: {
                Label(
                    listeningButtonTitle,
                    systemImage: listeningButtonIcon
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!model.isReadyForCommands && !model.speech.isActive)

            Text("Tap Right Option to start or stop listening")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)

            Text(model.lastError ?? model.lastAction)
                .font(.caption)
                .foregroundStyle(model.lastError == nil ? Color.secondary : Color.red)
                .lineLimit(2)
        }
    }

    @ViewBuilder
    private var permissions: some View {
        if !model.isReadyForCommands {
            VStack(alignment: .leading, spacing: 10) {
                Text("Finish setup")
                    .font(.headline)
                Text("Complete these once so your first voice command works immediately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                permissionRow(
                    icon: "mic.fill",
                    message: "Microphone for on-device commands",
                    isGranted: model.speech.microphoneAuthorization == .authorized,
                    action: model.requestMicrophoneAccess
                )

                permissionRow(
                    icon: "keyboard",
                    message: "Input Monitoring for Right Option",
                    isGranted: model.hasKeyboardMonitoringAccess,
                    action: model.requestKeyboardMonitoringAccess
                )

                permissionRow(
                    icon: "hand.raised.fill",
                    message: "Accessibility for Copy and Paste",
                    isGranted: model.hasEventPostingAccess,
                    action: model.requestEventPostingAccess
                )
            }
        }
    }

    private func permissionRow(
        icon: String,
        message: String,
        isGranted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: isGranted ? "checkmark.circle.fill" : icon)
                .foregroundStyle(isGranted ? .green : .orange)
                .frame(width: 18)
            Text(message)
                .font(.caption)
            Spacer()
            if isGranted {
                Text("Allowed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button("Allow", action: action)
                    .controlSize(.small)
            }
        }
    }

    private var listeningButtonTitle: String {
        switch model.speech.state {
        case .requestingMicrophone, .preparing, .downloadingModel:
            return "Cancel Starting"
        case .listening:
            return "Stop Listening"
        case .stopping:
            return "Start Again"
        case .stopped, .failed:
            return model.isReadyForCommands
                ? "Start Listening"
                : "Complete Setup to Listen"
        }
    }

    private var listeningButtonIcon: String {
        switch model.speech.state {
        case .requestingMicrophone, .preparing, .downloadingModel, .listening:
            return "stop.fill"
        case .stopping, .stopped, .failed:
            return model.isReadyForCommands ? "waveform" : "checklist"
        }
    }

    private var slots: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                sectionTitle("Numbered copies")

                if model.slots.numberedSlots.isEmpty {
                    Text("Say “copy one” to create your first slot.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                } else {
                    ForEach(model.slots.numberedSlots, id: \.number) { slot in
                        slotRow(title: "\(slot.number)", payload: slot.payload) {
                            model.submit(.pasteNumber(slot.number))
                        }
                    }
                }

                sectionTitle("Permanent copies")
                    .padding(.top, 4)

                if model.slots.namedSlots.isEmpty {
                    Text("Say “permanent copy house” while text or an item is selected.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                } else {
                    ForEach(model.slots.namedSlots, id: \.name) { slot in
                        slotRow(title: slot.name, payload: slot.payload) {
                            model.submit(.pasteNamed(slot.name))
                        }
                    }
                }
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func slotRow(
        title: String,
        payload: ClipboardPayload,
        paste: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: payload.kind.systemImage)
                .frame(width: 20)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(payload.preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("Paste", action: paste)
                .controlSize(.small)
        }
        .padding(10)
        .background(.quaternary, in: .rect(cornerRadius: 9))
    }

    private var footer: some View {
        HStack {
            Text("On-device speech • Session-only slots")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .controlSize(.small)
        }
    }
}

#if DEBUG
#Preview {
    DashboardView(model: AppModel())
}
#endif
