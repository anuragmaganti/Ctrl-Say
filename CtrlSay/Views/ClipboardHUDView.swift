import SwiftUI

struct ClipboardHUDView: View {
    let model: AppModel
    let presentationState: ClipboardHUDPresentationState
    let editingSession: DashboardEditingSession
    let thumbnailProvider: ClipboardThumbnailProvider

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            dragHeader
                .frame(height: ClipboardHUDMetrics.headerHeight)

            copyList
                .frame(maxHeight: .infinity)

            if presentationState.selectedCollection == .numbered,
               model.slots.hasTemporaryCopies {
                numberedFooter
                    .frame(height: ClipboardHUDMetrics.numberedFooterHeight)
            }
        }
        .frame(width: ClipboardHUDMetrics.width)
        .containerShape(.rect(cornerRadius: ClipboardHUDMetrics.cornerRadius))
        .glassEffect(
            .clear,
            in: .rect(cornerRadius: ClipboardHUDMetrics.cornerRadius)
        )
        .glassEffectTransition(.materialize)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Ctrl-Say Clipboard HUD")
    }

    private var dragHeader: some View {
        ZStack {
            Color.clear
                .contentShape(.rect)
                .gesture(WindowDragGesture())
                .allowsWindowActivationEvents(true)
                .accessibilityHidden(true)

            HStack {
                Button {
                    model.toggleListening()
                } label: {
                    ZStack {
                        Circle()
                            .fill(statusColor.opacity(0.14))
                        Image(systemName: statusIcon)
                            .font(.system(size: 15, weight: .semibold))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(statusColor)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .frame(width: 32, height: 32)
                    .contentShape(.circle)
                    .animation(
                        reduceMotion ? nil : .smooth(duration: 0.24),
                        value: statusIcon
                    )
                }
                .buttonStyle(.plain)
                .disabled(!model.isReadyForCommands && !model.speech.isActive)
                .accessibilityLabel(listeningButtonTitle)
                .accessibilityValue(statusAccessibilityLabel)
                .help(listeningButtonTitle)

                Spacer()

                if model.isProcessingCommand {
                    ProgressView()
                        .controlSize(.mini)
                        .allowsHitTesting(false)
                        .accessibilityLabel("Processing clipboard command")
                }
            }
            .padding(.horizontal, 14)

            collectionPicker
                .frame(width: 184)
        }
    }

    private var collectionPicker: some View {
        Picker(
            "Clipboard collection",
            selection: selectedCollectionBinding
        ) {
            ForEach(ClipboardCollection.allCases) { collection in
                Text(collection.rawValue)
                    .tag(collection)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    @ViewBuilder
    private var copyList: some View {
        switch presentationState.selectedCollection {
        case .numbered:
            numberedCopies
        case .permanent:
            ScrollView {
                permanentCopies
                    .padding(.horizontal, 8)
                    .padding(.vertical, ClipboardHUDMetrics.listVerticalPadding / 2)
            }
            .scrollIndicators(.automatic)
            .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
        }
    }

    @ViewBuilder
    private var numberedCopies: some View {
        let numberedSlots = model.slots.numberedSlots
        let namedSlots = model.slots.temporaryNamedSlots
        let finalPayloadID = namedSlots.last?.payload.id ?? numberedSlots.last?.payload.id
        List {
            if numberedSlots.isEmpty && namedSlots.isEmpty {
                emptyState(
                    icon: "square.stack",
                    title: "No temporary copies",
                    detail: "Say “copy 1,” “copy house,” or a short named phrase."
                )
                .temporarySlotListRow(showsBottomSeparator: false)
            } else {
                ForEach(numberedSlots, id: \.number) { slot in
                    NumberedCopyRow(
                        number: slot.number,
                        payload: slot.payload,
                        paste: {
                            model.pasteNumberedCopy(
                                slot.payload,
                                number: slot.number
                            )
                        },
                        delete: {
                            model.deleteNumberedCopy(slot.number)
                        },
                        style: .hud,
                        thumbnailProvider: thumbnailProvider
                    )
                    .id(slot.payload.id)
                    .onAppear {
                        model.recordHUDRowAppearance(for: slot.payload.id)
                    }
                    .temporarySlotListRow(
                        showsBottomSeparator: slot.payload.id != finalPayloadID
                    )
                }

                ForEach(namedSlots, id: \.name) { slot in
                    TemporaryNamedCopyRow(
                        name: slot.name,
                        payload: slot.payload,
                        paste: {
                            model.pasteTemporaryNamedCopy(
                                slot.payload,
                                name: slot.name
                            )
                        },
                        delete: {
                            model.deleteTemporaryNamedCopy(slot.name)
                        },
                        style: .hud,
                        thumbnailProvider: thumbnailProvider
                    )
                    .id(slot.payload.id)
                    .onAppear {
                        model.recordHUDRowAppearance(for: slot.payload.id)
                    }
                    .temporarySlotListRow(
                        showsBottomSeparator: slot.payload.id != finalPayloadID
                    )
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .contentMargins(.horizontal, 8, for: .scrollContent)
        .contentMargins(
            .top,
            ClipboardHUDMetrics.listVerticalPadding / 2,
            for: .scrollContent
        )
        .contentMargins(
            .bottom,
            model.slots.hasTemporaryCopies
                ? 0
                : ClipboardHUDMetrics.listVerticalPadding / 2,
            for: .scrollContent
        )
        .scrollIndicators(.automatic)
        .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
    }

    @ViewBuilder
    private var permanentCopies: some View {
        let slots = model.slots.namedSlots
        VStack(spacing: 8) {
            PermanentStorageStatusRow(
                state: model.permanentStorageState,
                retry: model.retryPermanentStorage
            )

            if !model.permanentStorageState.isLoading,
               !model.permanentStorageState.isUnavailable {
                if slots.isEmpty {
                    emptyState(
                        icon: "pin",
                        title: "No permanent copies",
                        detail: "Say “permanent copy house” with something selected."
                    )
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(slots, id: \.payload.id) { slot in
                            PermanentCopyRow(
                                name: slot.name,
                                payload: slot.payload,
                                editingSession: editingSession,
                                paste: {
                                    model.pastePermanentCopy(slot.payload.id)
                                },
                                delete: {
                                    model.deletePermanentCopy(slot.payload.id)
                                },
                                rename: { payloadID, requestedName in
                                    try model.renamePermanentCopy(
                                        payloadID,
                                        to: requestedName
                                    )
                                },
                                updateText: { payloadID, text in
                                    try model.updatePermanentCopyText(
                                        payloadID,
                                        text: text
                                    )
                                },
                                style: .hud,
                                thumbnailProvider: thumbnailProvider
                            )
                            .onAppear {
                                model.recordHUDRowAppearance(for: slot.payload.id)
                            }
                            .clipboardRowSeparator(
                                isVisible: slot.payload.id != slots.last?.payload.id
                            )
                        }
                    }
                }
            }
        }
    }

    private func emptyState(
        icon: String,
        title: String,
        detail: String
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(width: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: ClipboardHUDMetrics.emptyListHeight)
        .padding(.horizontal, 10)
        .accessibilityElement(children: .combine)
    }

    private var numberedFooter: some View {
        ZStack(alignment: .trailing) {
            Button("Clear All", systemImage: "trash") {
                model.clearTemporaryCopies()
            }
            .font(.caption2)
            .buttonStyle(.borderless)
            .controlSize(.mini)
            .accessibilityLabel("Clear all temporary copies")
            .padding(.trailing, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var selectedCollectionBinding: Binding<ClipboardCollection> {
        Binding(
            get: { presentationState.selectedCollection },
            set: { collection in
                editingSession.prepareForDismissal()
                presentationState.selectedCollection = collection
            }
        )
    }

    private var statusAccessibilityLabel: String {
        if !model.isReadyForCommands { return "Voice control setup required" }
        switch model.speech.state {
        case .requestingMicrophone, .preparing, .downloadingModel:
            return "Voice control preparing"
        case .listening:
            return "Voice control active"
        case .stopping:
            return "Voice control becoming inactive"
        case .failed:
            return "Voice control unavailable"
        case .stopped:
            return "Voice control inactive"
        }
    }

    private var listeningButtonTitle: String {
        switch model.speech.state {
        case .requestingMicrophone, .preparing, .downloadingModel:
            return "Cancel starting"
        case .listening:
            return "Stop listening"
        case .stopping:
            return "Start again"
        case .stopped, .failed:
            return model.isReadyForCommands
                ? "Start listening"
                : "Complete setup to listen"
        }
    }

    private var statusIcon: String {
        switch model.speech.state {
        case .requestingMicrophone, .preparing, .downloadingModel, .listening:
            return "mic.fill"
        case .stopping, .failed, .stopped:
            return "mic.slash.fill"
        }
    }

    private var statusColor: Color {
        if !model.isReadyForCommands { return .orange }
        switch model.speech.state {
        case .listening:
            return .green
        case .requestingMicrophone, .preparing, .downloadingModel, .stopping:
            return .accentColor
        case .failed:
            return .red
        case .stopped:
            return .secondary
        }
    }
}
