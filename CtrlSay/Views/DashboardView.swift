import AppKit
import SwiftUI

struct MenuBarStatusLabel: View {
    let model: AppModel

    var body: some View {
        Image("MenuBarIcon")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: 18, height: 18)
            .accessibilityLabel("Ctrl-Say")
            .accessibilityValue(statusDescription)
            .help("Ctrl-Say — \(statusDescription)")
    }

    private var statusDescription: String {
        if !model.isReadyForCommands { return "Complete setup" }
        switch model.speech.state {
        case .stopped:
            return "Not listening"
        case .requestingMicrophone, .preparing, .downloadingModel:
            return "Starting on-device listening"
        case .listening:
            return "Listening"
        case .stopping:
            return "Stopping listening"
        case .failed:
            return "Listening failed"
        }
    }
}

/// The menu-bar surface stays deliberately compact. Clipboard management lives
/// in the floating HUD so this menu carries status, compact settings,
/// app-level actions, and Debug diagnostics.
struct DashboardView: View {
    let model: AppModel

#if DEBUG
    @State private var showsDeveloperDiagnostics = false
#endif

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.vertical, 12)

            if !model.isReadyForCommands {
                Divider()

                CtrlSayPermissionSetupView(model: model)
                    .padding(.vertical, 12)
            }

            Divider()

            DashboardSettingsSection(model: model)
                .padding(.vertical, 12)

#if DEBUG
            Divider()

            developerDiagnostics
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 12)
#endif

            if model.slots.hasTemporaryCopies {
                Divider()

                clearTemporaryCopiesButton
                    .padding(.vertical, 10)
            }

            Divider()

            quitButton
                .padding(.vertical, 12)
        }
        .padding(.horizontal, 12)
        .onAppear {
            model.refreshPermissions()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Ctrl-Say")
                .font(.body)
                .foregroundStyle(.white)
                .fixedSize(horizontal: true, vertical: false)

            HStack(spacing: 5) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 5, height: 5)

                Text(statusTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            if model.isProcessingCommand {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Processing clipboard command")
            }
        }
    }

    private var clearTemporaryCopiesButton: some View {
        Button(role: .destructive) {
            model.clearTemporaryCopies()
        } label: {
            Label("Clear Temporary Copies", systemImage: "trash")
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .frame(minHeight: 20)
    }

    private var quitButton: some View {
        Button {
            NSApplication.shared.terminate(nil)
        } label: {
            Label("Quit Ctrl-Say", systemImage: "power")
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
        }
        .buttonStyle(.dashboardMenuAction)
        .accessibilityLabel("Quit Ctrl-Say")
    }

}

struct CtrlSaySetupView: View {
    let model: AppModel

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 34, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Set Up Ctrl-Say")
                        .font(.title2.weight(.semibold))
                    Text("Allow three system permissions for voice copy and paste.")
                        .foregroundStyle(.secondary)
                }
            }

            CtrlSayPermissionSetupView(model: model)
        }
        .padding(24)
        .frame(width: 430)
        .onAppear {
            model.refreshPermissions()
        }
        .onChange(of: model.isReadyForCommands) { _, isReady in
            if isReady { dismiss() }
        }
    }
}

private struct CtrlSayPermissionSetupView: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Finish setup")
                        .font(.callout.weight(.semibold))
                    Text("Required for voice copy and paste")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

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
                icon: "waveform.path",
                title: "Input Monitoring",
                isGranted: model.hasKeyboardMonitoringAccess,
                action: model.requestKeyboardMonitoringAccess
            )
            permissionRow(
                icon: "accessibility",
                title: "Accessibility",
                isGranted: model.hasEventPostingAccess,
                action: model.requestEventPostingAccess
            )
        }
        .accessibilityElement(children: .contain)
    }

    private func permissionRow(
        icon: String,
        title: String,
        isGranted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 9) {
            Image(systemName: isGranted ? "checkmark.circle.fill" : icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isGranted ? .green : .orange)
                .frame(width: 20)
                .accessibilityHidden(true)

            Text(title)
                .font(.callout)

            Spacer(minLength: 8)

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
        .frame(minHeight: 28)
        .accessibilityElement(children: isGranted ? .combine : .contain)
    }

    private var grantedPermissionCount: Int {
        var count = 0
        if model.speech.microphoneAuthorization == .authorized { count += 1 }
        if model.hasKeyboardMonitoringAccess { count += 1 }
        if model.hasEventPostingAccess { count += 1 }
        return count
    }
}

#if DEBUG
private extension DashboardView {
    private var developerDiagnostics: some View {
        DisclosureGroup(isExpanded: diagnosticsExpansion) {
            ScrollView {
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
                .frame(maxWidth: .infinity, alignment: .leading)
                .font(.caption2.monospaced())
                .padding(.top, 8)
            }
            .frame(maxHeight: 230)
            .scrollIndicators(.automatic)
            .scrollEdgeEffectStyle(.hard, for: [.top, .bottom])
        } label: {
            Label("Developer diagnostics", systemImage: "wrench.and.screwdriver")
                .font(.caption.weight(.semibold))
        }
        .controlSize(.small)
    }

    private var diagnosticsExpansion: Binding<Bool> {
        Binding(
            get: { showsDeveloperDiagnostics },
            set: { showsDeveloperDiagnostics = $0 }
        )
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
}
#endif

private extension DashboardView {
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
}

#if DEBUG
#Preview {
    DashboardView(model: AppModel())
}
#endif
