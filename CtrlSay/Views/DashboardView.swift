import AppKit
import SwiftUI

/// The menu-bar surface stays deliberately compact. Clipboard management lives
/// in the floating HUD so this panel only carries status, app-level actions,
/// and Debug diagnostics.
struct DashboardView: View {
    let model: AppModel
    let presentationState: DashboardPresentationState

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

#if DEBUG
            developerDiagnostics
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
#endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .containerShape(.rect(cornerRadius: DashboardPanelMetrics.cornerRadius))
        .onAppear {
            model.refreshPermissions()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 27, weight: .medium))
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
                }

                Divider()
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

#if DEBUG
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
            .scrollIndicators(.automatic)
            .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
        } label: {
            Label("Developer diagnostics", systemImage: "wrench.and.screwdriver")
                .font(.caption.weight(.semibold))
        }
        .padding(11)
        .background(.quaternary, in: .rect(cornerRadius: 12))
    }

    private var diagnosticsExpansion: Binding<Bool> {
        Binding(
            get: { presentationState.showsDeveloperDiagnostics },
            set: { presentationState.showsDeveloperDiagnostics = $0 }
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
#endif

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
    DashboardView(
        model: AppModel(),
        presentationState: DashboardPresentationState()
    )
    .frame(
        width: DashboardPanelMetrics.preferredSize.width,
        height: DashboardPanelMetrics.preferredSize.height
    )
}
#endif
