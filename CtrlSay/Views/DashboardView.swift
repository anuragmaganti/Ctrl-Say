import AppKit
import SwiftUI

/// The menu-bar surface stays deliberately compact. Clipboard management lives
/// in the floating HUD so this menu carries status, settings, app-level actions,
/// and Debug-only diagnostics.
struct DashboardView: View {
    let model: AppModel

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

            DeveloperDiagnosticsView(model: model)
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
