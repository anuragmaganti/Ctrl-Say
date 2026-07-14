import SwiftUI

struct CtrlSaySettingsView: View {
    let model: AppModel

    @AppStorage(CtrlSayPreferenceKey.showHUDWhenRightOptionStartsListening)
    private var showHUDWhenListeningStarts = true
    @State private var confirmsPermanentStorageReset = false

    var body: some View {
        Form {
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
        .frame(width: 500, height: 310)
        .navigationTitle("General")
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
