import AppKit
import SwiftUI

struct DashboardSettingsSection: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            settingsSection

            Divider()
                .padding(.vertical, 12)

            storageSection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .controlSize(.small)
        .onAppear {
            model.refreshLaunchAtLogin()
        }
    }

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent {
                Toggle("Launch at Login", isOn: launchAtLoginBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityLabel("Launch at Login")
            } label: {
                Label("Launch at Login", systemImage: "arrow.up.forward.app")
                    .font(.body)
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(.white)
                    .accessibilityHidden(true)
            }

            launchAtLoginDetails
        }
    }

    private var storageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let storageStatusTitle {
                HStack(alignment: .center, spacing: 8) {
                    storageStatusIcon
                        .frame(width: 16)

                    Text(storageStatusTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)

                    if model.permanentStorageState.hasFailure {
                        Spacer(minLength: 6)

                        Button("Retry") {
                            model.retryPermanentStorage()
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .accessibilityElement(children: .contain)
            }

            Button(role: .destructive) {
                guard confirmsClearingPermanentCopies() else { return }
                Task {
                    await model.resetPermanentStorage()
                }
            } label: {
                Label("Clear Permanent Copies", systemImage: "trash")
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.dashboardMenuAction)
            .controlSize(.regular)
            .accessibilityLabel("Clear all permanent copies")
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
    private func confirmsClearingPermanentCopies() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Clear All Permanent Copies?"
        alert.informativeText =
            "This permanently deletes every saved permanent copy. "
            + "Temporary copies are unaffected."

        alert.addButton(withTitle: "Cancel")
        let clearButton = alert.addButton(withTitle: "Clear")
        clearButton.hasDestructiveAction = true

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

    @ViewBuilder
    private var storageStatusIcon: some View {
        switch model.permanentStorageState {
        case .loading, .saving:
            ProgressView()
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
