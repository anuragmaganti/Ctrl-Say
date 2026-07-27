#if DEBUG
import SwiftUI

struct DeveloperDiagnosticsView: View {
    let model: AppModel

    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ScrollView {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Memory-only • Never logged")
                        .foregroundStyle(.tertiary)

                    diagnosticRow(
                        "Transcript",
                        model.debugDiagnostics.transcript.isEmpty
                            ? "No speech yet"
                            : model.debugDiagnostics.transcript
                    )
                    diagnosticRow("Result", model.debugDiagnostics.resultState)
                    diagnosticRow("Confidence", model.debugDiagnostics.confidence)
                    diagnosticRow("Parser", model.debugDiagnostics.parseOutcome)
                    diagnosticRow("Recognition", model.debugDiagnostics.recognitionLatency)
                    diagnosticRow("Tokenization", model.debugDiagnostics.tokenization)
                    diagnosticRow("Name revision", model.debugDiagnostics.namedCopyRevision)
                    diagnosticRow("Queue", model.debugDiagnostics.queue)
                    diagnosticRow("Clipboard", model.debugDiagnostics.clipboardPath)
                    diagnosticRow("Target", model.debugDiagnostics.target)

                    if model.debugDiagnostics.alternatives.count > 1 {
                        diagnosticRow(
                            "Alternatives",
                            model.debugDiagnostics.alternatives.dropFirst().prefix(3)
                                .joined(separator: " • ")
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .font(.caption2.monospaced())
                .padding(.top, 8)
            }
            .frame(maxHeight: 230)
            .scrollIndicators(.automatic)
            .scrollEdgeEffectStyle(.hard, for: [.top, .bottom])
        } label: {
            Label("Developer diagnostics", systemImage: "wrench.and.screwdriver")
                .font(.caption.weight(.semibold))
        }
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func diagnosticRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .leading)
            Text(value)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
#endif
