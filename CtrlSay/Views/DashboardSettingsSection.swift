import AppKit
import SwiftUI

struct DashboardSettingsSection: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsSection
            storageSection
        }
        .onAppear {
            model.refreshLaunchAtLogin()
        }
    }

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionTitle("Settings")

            HStack(alignment: .center, spacing: 12) {
                Text("Launch at Login")
                    .font(.callout)

                Spacer(minLength: 6)

                Toggle("Launch at Login", isOn: launchAtLoginBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .accessibilityLabel("Launch at Login")
            }

            launchAtLoginDetails
        }
    }

    private var storageSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let storageStatusTitle {
                HStack(alignment: .top, spacing: 9) {
                    storageStatusIcon
                        .frame(width: 16, height: 18)

                    Text(storageStatusTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .contain)
            }

            if model.permanentStorageState.hasFailure {
                Button("Retry") {
                    model.retryPermanentStorage()
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }

            Button(
                "Reset Permanent Copies…",
                systemImage: "trash",
                role: .destructive
            ) {
                guard confirmsPermanentStorageReset() else { return }
                Task {
                    await model.resetPermanentStorage()
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.small)
            .accessibilityHint(
                "Opens a confirmation before deleting every permanent copy"
            )
        }
    }

    /// A window-style MenuBarExtra is a transient, popover-like host. A
    /// SwiftUI alert creates a separate presentation that can make that host
    /// dismiss before its first click is delivered. An app-modal NSAlert owns
    /// the event loop until the user explicitly responds, which is the native
    /// AppKit path for an alert without a document window to attach to.
    private func confirmsPermanentStorageReset() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Reset Permanent Storage?"
        alert.informativeText =
            "This permanently deletes every saved permanent copy. "
            + "Temporary copies are unaffected."

        alert.addButton(withTitle: "Cancel")
        let resetButton = alert.addButton(withTitle: "Reset")
        resetButton.hasDestructiveAction = true

        return alert.runModal() == .alertSecondButtonReturn
    }

    @ViewBuilder
    private var launchAtLoginDetails: some View {
        switch model.launchAtLogin.state {
        case .requiresApproval:
            VStack(alignment: .leading, spacing: 4) {
                Label(
                    "Approval required in Login Items",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)

                Button("Open Login Items") {
                    model.launchAtLogin.openSystemSettings()
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
        case .unavailable:
            Label(
                "Unavailable for this app build",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(.orange)
        case .disabled, .enabled:
            EmptyView()
        }

        if let errorMessage = model.launchAtLogin.errorMessage {
            Text(errorMessage)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sectionTitle(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private var storageStatusIcon: some View {
        switch model.permanentStorageState {
        case .loading, .saving:
            ProgressView()
                .controlSize(.small)
        case .ready:
            EmptyView()
        case .loadFailed, .saveFailed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { model.launchAtLogin.isEnabled },
            set: { model.setLaunchAtLoginEnabled($0) }
        )
    }

    private var storageStatusTitle: String? {
        switch model.permanentStorageState {
        case .loading:
            "Loading saved copies…"
        case .ready:
            nil
        case .saving(let pendingCount):
            "Saving \(pendingCount) change\(pendingCount == 1 ? "" : "s")…"
        case .loadFailed:
            "Storage unavailable"
        case .saveFailed(let pendingCount):
            "\(pendingCount) unsaved change\(pendingCount == 1 ? "" : "s")"
        }
    }
}
