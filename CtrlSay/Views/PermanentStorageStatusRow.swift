import SwiftUI

struct PermanentStorageStatusRow: View {
    let state: PermanentCopyPersistenceState
    let retry: () -> Void

    var body: some View {
        if let message = state.userMessage {
            HStack(spacing: 9) {
                if state.isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                }

                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 6)

                if state.hasFailure {
                    Button("Retry", action: retry)
                        .controlSize(.small)
                        .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.quaternary, in: .rect(cornerRadius: 9))
            .accessibilityElement(children: .contain)
        }
    }
}
