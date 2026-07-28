import SwiftUI

private enum TemporaryHUDRow: Identifiable {
    case pending(PendingClipboardCopy)
    case numbered(Int, ClipboardPayload)
    case named(String, ClipboardPayload)

    var id: PendingClipboardCopy.Destination {
        switch self {
        case .pending(let copy):
            copy.destination
        case .numbered(let number, _):
            .numbered(number)
        case .named(let name, _):
            .temporaryNamed(name)
        }
    }
}

private enum PermanentHUDRow: Identifiable {
    case pending(PendingClipboardCopy)
    case stored(String, ClipboardPayload)

    var id: PendingClipboardCopy.Destination {
        switch self {
        case .pending(let copy):
            copy.destination
        case .stored(let name, _):
            .permanentNamed(name)
        }
    }
}

struct ClipboardHUDView: View {
    let model: AppModel
    let presentationState: ClipboardHUDPresentationState
    let editingSession: ClipboardHUDEditingSession
    let thumbnailProvider: ClipboardThumbnailProvider

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            dragHeader
                .frame(height: ClipboardHUDMetrics.headerHeight)

            copyList
                .frame(maxHeight: .infinity)

            if presentationState.selectedCollection == .numbered,
                model.slots.hasTemporaryCopies
            {
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
            permanentCopies
        }
    }

    @ViewBuilder
    private var numberedCopies: some View {
        let rows = temporaryRows
        List {
            if rows.isEmpty {
                emptyState(
                    icon: "square.stack",
                    title: "No temporary copies",
                    detail: "Say “copy 1,” “copy house,” or a short named phrase.",
                    leadingPadding: 8,
                    trailingPadding: 8
                )
                .clipboardSlotListRow(showsBottomSeparator: false)
            } else {
                ForEach(rows) { row in
                    Group {
                        switch row {
                        case .pending(let copy):
                            PendingClipboardCopyRow(copy: copy)
                                .onAppear {
                                    model.recordPendingHUDRowAppearance(
                                        for: copy.id
                                    )
                                }

                        case .numbered(let number, let payload):
                            TemporaryCopyRow(
                                slot: .numbered(number),
                                payload: payload,
                                copyToClipboard: {
                                    model.copyToSystemClipboard(payload)
                                },
                                paste: {
                                    model.pasteNumberedCopy(
                                        payload,
                                        number: number
                                    )
                                },
                                delete: {
                                    model.deleteNumberedCopy(number)
                                },
                                thumbnailProvider: thumbnailProvider
                            )
                            .id(payload.id)
                            .onAppear {
                                model.recordHUDRowAppearance(for: payload.id)
                            }

                        case .named(let name, let payload):
                            TemporaryCopyRow(
                                slot: .named(name),
                                payload: payload,
                                copyToClipboard: {
                                    model.copyToSystemClipboard(payload)
                                },
                                paste: {
                                    model.pasteTemporaryNamedCopy(
                                        payload,
                                        name: name
                                    )
                                },
                                delete: {
                                    model.deleteTemporaryNamedCopy(name)
                                },
                                thumbnailProvider: thumbnailProvider
                            )
                            .id(payload.id)
                            .onAppear {
                                model.recordHUDRowAppearance(for: payload.id)
                            }
                        }
                    }
                    .clipboardSlotListRow(
                        showsBottomSeparator: row.id != rows.last?.id
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
        .scrollBounceBehavior(.basedOnSize, axes: .vertical)
        .scrollEdgeEffectStyle(.hard, for: [.top, .bottom])
    }

    @ViewBuilder
    private var permanentCopies: some View {
        let rows = permanentRows
        let showsPermanentCopies =
            !model.permanentStorageState.isLoading
            && !model.permanentStorageState.isUnavailable
            && !rows.isEmpty
        List {
            if model.permanentStorageState.userMessage != nil {
                PermanentStorageStatusRow(
                    state: model.permanentStorageState,
                    retry: model.retryPermanentStorage
                )
                .clipboardSlotListRow()
            }

            if !model.permanentStorageState.isLoading,
                !model.permanentStorageState.isUnavailable
            {
                if rows.isEmpty {
                    emptyState(
                        icon: "pin",
                        title: "No permanent copies",
                        detail: "Say “permanent copy house” with something selected.",
                        leadingPadding: 8,
                        trailingPadding: 8
                    )
                    .clipboardSlotListRow()
                } else {
                    ForEach(rows) { row in
                        Group {
                            switch row {
                            case .pending(let copy):
                                PendingClipboardCopyRow(copy: copy)
                                    .onAppear {
                                        model.recordPendingHUDRowAppearance(
                                            for: copy.id
                                        )
                                    }

                            case .stored(let name, let payload):
                                PermanentCopyRow(
                                    name: name,
                                    payload: payload,
                                    editingSession: editingSession,
                                    copyToClipboard: {
                                        model.copyToSystemClipboard(payload)
                                    },
                                    paste: {
                                        model.pastePermanentCopy(payload.id)
                                    },
                                    delete: {
                                        model.deletePermanentCopy(payload.id)
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
                                    thumbnailProvider: thumbnailProvider
                                )
                                .id(payload.id)
                                .onAppear {
                                    model.recordHUDRowAppearance(for: payload.id)
                                }
                            }
                        }
                        .clipboardSlotListRow(
                            showsBottomSeparator: row.id != rows.last?.id
                        )
                    }
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
            showsPermanentCopies
                ? 0
                : ClipboardHUDMetrics.listVerticalPadding / 2,
            for: .scrollContent
        )
        .scrollIndicators(.automatic)
        .scrollBounceBehavior(.basedOnSize, axes: .vertical)
        .scrollEdgeEffectStyle(.hard, for: [.top, .bottom])
    }

    private var temporaryRows: [TemporaryHUDRow] {
        let pending = model.pendingClipboardCopies.latestCopies(in: .temporary)
        let pendingByDestination = Dictionary(
            uniqueKeysWithValues: pending.map { ($0.destination, $0) }
        )
        let numberedByNumber = Dictionary(
            uniqueKeysWithValues: model.slots.numberedSlots.map {
                ($0.number, $0.payload)
            }
        )
        let pendingNumbers = pending.compactMap { copy -> Int? in
            guard case .numbered(let number) = copy.destination else {
                return nil
            }
            return number
        }
        let allNumbers = Set(numberedByNumber.keys)
            .union(pendingNumbers)
            .sorted()

        var rows = allNumbers.compactMap { number -> TemporaryHUDRow? in
            let destination = PendingClipboardCopy.Destination.numbered(number)
            if let pendingCopy = pendingByDestination[destination] {
                return .pending(pendingCopy)
            }
            return numberedByNumber[number].map {
                .numbered(number, $0)
            }
        }

        let storedNamedSlots = model.slots.temporaryNamedSlots
        let storedNames = Set(storedNamedSlots.map(\.name))
        for slot in storedNamedSlots {
            let destination = PendingClipboardCopy.Destination
                .temporaryNamed(slot.name)
            if let pendingCopy = pendingByDestination[destination] {
                rows.append(.pending(pendingCopy))
            } else {
                rows.append(.named(slot.name, slot.payload))
            }
        }
        for pendingCopy in pending {
            guard case .temporaryNamed(let name) = pendingCopy.destination,
                !storedNames.contains(name)
            else {
                continue
            }
            rows.append(.pending(pendingCopy))
        }
        return rows
    }

    private var permanentRows: [PermanentHUDRow] {
        let pending = model.pendingClipboardCopies.latestCopies(in: .permanent)
        let pendingByDestination = Dictionary(
            uniqueKeysWithValues: pending.map { ($0.destination, $0) }
        )
        let storedByName = Dictionary(
            uniqueKeysWithValues: model.slots.namedSlots.map {
                ($0.name, $0.payload)
            }
        )
        let pendingNames = pending.compactMap { copy -> String? in
            guard case .permanentNamed(let name) = copy.destination else {
                return nil
            }
            return name
        }
        let allNames = Set(storedByName.keys)
            .union(pendingNames)
            .sorted()

        return allNames.compactMap { name in
            let destination = PendingClipboardCopy.Destination
                .permanentNamed(name)
            if let pendingCopy = pendingByDestination[destination] {
                return .pending(pendingCopy)
            }
            return storedByName[name].map { .stored(name, $0) }
        }
    }

    private func emptyState(
        icon: String,
        title: String,
        detail: String,
        leadingPadding: CGFloat = 10,
        trailingPadding: CGFloat = 10
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
        .padding(.leading, leadingPadding)
        .padding(.trailing, trailingPadding)
        .accessibilityElement(children: .combine)
    }

    private var numberedFooter: some View {
        Button {
            model.clearTemporaryCopies()
        } label: {
            Label("Clear All", systemImage: "trash")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .center
                )
                .offset(y: -4)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Clear all temporary copies")
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
