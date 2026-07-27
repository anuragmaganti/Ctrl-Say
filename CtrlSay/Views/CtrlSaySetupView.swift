import SwiftUI

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

struct CtrlSayPermissionSetupView: View {
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
