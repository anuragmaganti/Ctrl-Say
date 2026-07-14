import SwiftUI

struct CtrlSaySettingsView: View {
    let model: AppModel

    @AppStorage(CtrlSayPreferenceKey.showHUDWhenRightOptionStartsListening)
    private var showHUDWhenListeningStarts = true
    @State private var confirmsPermanentStorageReset = false

    var body: some View {
        Form {
            Section("Startup") {
                Toggle(
                    "Open Ctrl-Say at Login",
                    isOn: Binding(
                        get: { model.launchAtLogin.isEnabled },
                        set: { isEnabled in
                            model.setLaunchAtLoginEnabled(isEnabled)
                        }
                    )
                )

                Text("Starts Ctrl-Say automatically when you sign in to this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if model.launchAtLogin.state == .requiresApproval {
                    HStack(alignment: .firstTextBaseline) {
                        Label(
                            "Approval is required in Login Items.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(.orange)
                        Spacer()
                        Button("Open System Settings") {
                            model.launchAtLogin.openSystemSettings()
                        }
                    }
                }

                if model.launchAtLogin.state == .unavailable {
                    Label(
                        "Launch at Login is unavailable for this app build.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                }

                if let errorMessage = model.launchAtLogin.errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Clipboard HUD") {
                Toggle(
                    "Show Clipboard HUD when Right Option starts listening",
                    isOn: $showHUDWhenListeningStarts
                )
                Text(
                    "This affects tap-to-start only. Holding Right Option can always show or hide the HUD."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Permanent Copies") {
                HStack(spacing: 9) {
                    storageStatusIcon
                    VStack(alignment: .leading, spacing: 2) {
                        Text(storageStatusTitle)
                        Text("Permanent copies stay on this Mac until you delete them.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.permanentStorageState.hasFailure {
                        Button("Retry") {
                            model.retryPermanentStorage()
                        }
                    }
                }

                Button("Reset Permanent Storage…", role: .destructive) {
                    confirmsPermanentStorageReset = true
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 440)
        .navigationTitle("General")
        .onAppear {
            model.refreshLaunchAtLogin()
        }
        .alert(
            "Reset Permanent Storage?",
            isPresented: $confirmsPermanentStorageReset
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                Task {
                    await model.resetPermanentStorage()
                }
            }
        } message: {
            Text("This permanently deletes every saved permanent copy. Temporary copies are unaffected.")
        }
    }

    @ViewBuilder
    private var storageStatusIcon: some View {
        switch model.permanentStorageState {
        case .loading, .saving:
            ProgressView()
                .controlSize(.small)
        case .ready:
            Image(systemName: "internaldrive.fill")
                .foregroundStyle(.secondary)
        case .loadFailed, .saveFailed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    private var storageStatusTitle: String {
        switch model.permanentStorageState {
        case .loading:
            "Loading permanent copies…"
        case .ready:
            "Saved locally"
        case .saving(let pendingCount):
            "Saving \(pendingCount) change\(pendingCount == 1 ? "" : "s")…"
        case .loadFailed:
            "Permanent storage unavailable"
        case .saveFailed(let pendingCount):
            "\(pendingCount) unsaved change\(pendingCount == 1 ? "" : "s")"
        }
    }
}
