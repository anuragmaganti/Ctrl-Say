import SwiftUI

struct CtrlSaySettingsView: View {
    @AppStorage(CtrlSayPreferenceKey.showHUDWhenRightOptionStartsListening)
    private var showHUDWhenListeningStarts = true

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
        }
        .formStyle(.grouped)
        .frame(width: 470, height: 170)
        .navigationTitle("General")
    }
}
