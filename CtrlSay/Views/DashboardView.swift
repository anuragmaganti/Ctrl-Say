import AppKit
import SwiftUI

struct DashboardView: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            permissions
            Divider()
            slots
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 360, height: 500)
        .onAppear {
            model.refreshPermissions()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ctrl-Say")
                        .font(.title2.weight(.semibold))
                    Text(model.speech.state.label)
                        .font(.caption)
                        .foregroundStyle(model.speech.isListening ? .green : .secondary)
                }
                Spacer()
                if model.isProcessingCommand {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            Button {
                model.toggleListening()
            } label: {
                Label(
                    model.speech.isListening ? "Stop Listening" : "Start Listening",
                    systemImage: model.speech.isListening ? "stop.fill" : "waveform"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Text("Tap Right Option to start or stop listening")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)

            Text(model.lastError ?? model.lastAction)
                .font(.caption)
                .foregroundStyle(model.lastError == nil ? Color.secondary : Color.red)
                .lineLimit(2)
        }
    }

    @ViewBuilder
    private var permissions: some View {
        if !model.hasKeyboardMonitoringAccess || !model.hasEventPostingAccess {
            VStack(spacing: 10) {
                if !model.hasKeyboardMonitoringAccess {
                    permissionRow(
                        icon: "keyboard",
                        message: "Allow Input Monitoring for the Right Option shortcut.",
                        action: model.requestKeyboardMonitoringAccess
                    )
                }

                if !model.hasEventPostingAccess {
                    permissionRow(
                        icon: "hand.raised.fill",
                        message: "Allow Accessibility control for cross-app Copy and Paste.",
                        action: model.requestEventPostingAccess
                    )
                }
            }
        }
    }

    private func permissionRow(
        icon: String,
        message: String,
        action: @escaping () -> Void
    ) -> some View {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.caption)
                Spacer()
                Button("Allow", action: action)
            }
    }

    private var slots: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                sectionTitle("Numbered copies")

                if model.slots.numberedSlots.isEmpty {
                    Text("Say “copy one” to create your first slot.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                } else {
                    ForEach(model.slots.numberedSlots, id: \.number) { slot in
                        slotRow(title: "\(slot.number)", payload: slot.payload) {
                            model.submit(.pasteNumber(slot.number))
                        }
                    }
                }

                sectionTitle("Permanent copies")
                    .padding(.top, 4)

                if model.slots.namedSlots.isEmpty {
                    Text("Say “permanent copy house” while text or an item is selected.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                } else {
                    ForEach(model.slots.namedSlots, id: \.name) { slot in
                        slotRow(title: slot.name, payload: slot.payload) {
                            model.submit(.pasteNamed(slot.name))
                        }
                    }
                }
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func slotRow(
        title: String,
        payload: ClipboardPayload,
        paste: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: payload.kind.systemImage)
                .frame(width: 20)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(payload.preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("Paste", action: paste)
                .controlSize(.small)
        }
        .padding(10)
        .background(.quaternary, in: .rect(cornerRadius: 9))
    }

    private var footer: some View {
        HStack {
            Text("On-device speech • Session-only slots")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .controlSize(.small)
        }
    }
}

#Preview {
    DashboardView(model: AppModel())
}
