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
