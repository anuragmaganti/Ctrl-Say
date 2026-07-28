import AppKit
import SwiftUI

private struct ClipboardPreview: View {
    let payload: ClipboardPayload
    let additionalHelp: String?

    @State private var isPreviewTruncated = false

    init(
        payload: ClipboardPayload,
        additionalHelp: String? = nil
    ) {
        self.payload = payload
        self.additionalHelp = additionalHelp
    }

    var body: some View {
        contextualPreviewLabel
    }

    private var previewLabel: some View {
        Text(displayedText)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(ClipboardHUDMetrics.previewLineLimit)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("Contents, \(payload.preview)")
            .onPreferenceChange(Text.LayoutKey.self) { layouts in
                let isTruncated = layouts.contains {
                    $0.layout.isTruncated
                }
                guard isPreviewTruncated != isTruncated else { return }
                isPreviewTruncated = isTruncated
            }
    }

    @ViewBuilder
    private var contextualPreviewLabel: some View {
        if let previewHelp {
            previewLabel
                .contentShape(.rect)
                .help(Text(verbatim: previewHelp))
        } else {
            previewLabel
        }
    }

    private var isTextPreview: Bool {
        payload.kind == .text || payload.kind == .mixed
    }

    private var displayedText: String {
        if isTextPreview {
            // Let SwiftUI truncate according to the actual glyph widths and
            // available row space. The short stored preview is intentionally
            // metadata-sized and can end before a visual line is full.
            return payload.expandedPreviewText
        }
        return payload.preview
    }

    private var previewHelp: String? {
        guard isPreviewTruncated else { return additionalHelp }
        let preview = payload.tooltipPreviewText
        guard !preview.isEmpty else { return additionalHelp }
        guard let additionalHelp else { return preview }
        return "\(preview)\n\(additionalHelp)"
    }
}

struct PendingClipboardCopyRow: View {
    let copy: PendingClipboardCopy

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(copy.destination.displayTitle)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text("Copying…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Image(systemName: "doc.on.doc")
                .font(.system(size: 14, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 8)
        .frame(minHeight: ClipboardHUDMetrics.rowHeight)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Copying to \(copy.destination.displayTitle)")
    }
}

struct TemporaryCopyRow: View {
    enum Slot {
        case numbered(Int)
        case named(String)

        var title: String {
            switch self {
            case .numbered(let number):
                String(number)
            case .named(let name):
                name.prefix(1).uppercased() + String(name.dropFirst())
            }
        }

        var copyAccessibilityName: String {
            switch self {
            case .numbered(let number):
                "slot \(number)"
            case .named(let name):
                name
            }
        }

        var actionAccessibilityName: String {
            switch self {
            case .numbered:
                copyAccessibilityName
            case .named:
                "copy \(copyAccessibilityName)"
            }
        }
    }

    let slot: Slot
    let payload: ClipboardPayload
    let editingSession: ClipboardHUDEditingSession
    let copyToClipboard: () -> Void
    let paste: () -> Void
    let delete: @MainActor @Sendable () -> Void
    let updateText: (UUID, String) throws -> Void
    let thumbnailProvider: ClipboardThumbnailProvider?

    @State private var isHovered = false
    @State private var focusLossIsArmed = false
    @FocusState private var contentIsFocused: Bool

    init(
        slot: Slot,
        payload: ClipboardPayload,
        editingSession: ClipboardHUDEditingSession,
        copyToClipboard: @escaping () -> Void,
        paste: @escaping () -> Void,
        delete: @escaping @MainActor @Sendable () -> Void,
        updateText: @escaping (UUID, String) throws -> Void,
        thumbnailProvider: ClipboardThumbnailProvider? = nil
    ) {
        self.slot = slot
        self.payload = payload
        self.editingSession = editingSession
        self.copyToClipboard = copyToClipboard
        self.paste = paste
        self.delete = delete
        self.updateText = updateText
        self.thumbnailProvider = thumbnailProvider
    }

    var body: some View {
        accessibleRow
            .onDisappear {
                editingSession.cancelEditing(payloadID: payload.id)
            }
            .onChange(of: payload) { oldPayload, newPayload in
                guard isEditingContent, newPayload != oldPayload else { return }
                editingSession.markConflict(
                    for: payload.id,
                    message: editConflictMessage
                )
                focusContentEditor()
            }
    }

    @ViewBuilder
    private var accessibleRow: some View {
        if canEditContents {
            interactiveRow
                .accessibilityAction(named: editAccessibilityLabel) {
                    beginContentEditing()
                }
        } else {
            interactiveRow
        }
    }

    private var interactiveRow: some View {
        row
            .temporarySlotSwipeToDelete(action: delete)
            .contextMenu { menuItems }
            .accessibilityElement(children: .contain)
            .accessibilityAction(named: copyAccessibilityLabel) {
                copyToClipboard()
            }
            .accessibilityAction(named: pasteAccessibilityLabel) {
                paste()
            }
            .accessibilityAction(named: deleteAccessibilityLabel) {
                delete()
            }
    }

    private var row: some View {
        HStack(alignment: isEditingContent ? .top : .center, spacing: 10) {
            leadingControl

            VStack(alignment: .leading, spacing: 2) {
                if isEditingContent {
                    Text(slot.title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    TextEditor(text: boundedContentDraft)
                        .font(.callout)
                        .scrollContentBackground(.hidden)
                        .padding(5)
                        .frame(height: ClipboardHUDMetrics.inlineContentEditorHeight)
                        .background(.quaternary, in: .rect(cornerRadius: 7))
                        .focused($contentIsFocused)
                        .onAppear {
                            focusContentEditor()
                        }
                        .onKeyPress(.escape) {
                            cancelEditing()
                            return .handled
                        }
                        .onKeyPress(.return, phases: .down) { press in
                            guard press.modifiers.contains(.command) else {
                                return .ignored
                            }
                            _ = commitContentEdit()
                            return .handled
                        }
                        .accessibilityLabel("Temporary copy contents")
                        .accessibilityHint(
                            "Press Command-Return to save or Escape to cancel"
                        )

                    if let validationMessage = editingSession.validationMessage {
                        Text(validationMessage)
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel(
                                "Editing error: \(validationMessage)"
                            )
                    }
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        titleCopyButton

                        pasteButton
                    }

                    previewCopyButton
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onChange(of: contentIsFocused) { oldValue, newValue in
                guard oldValue, !newValue, isEditingContent else { return }
                guard focusLossIsArmed else {
                    focusContentEditor()
                    return
                }
                Task { @MainActor in
                    await Task.yield()
                    if isEditingContent, !contentIsFocused {
                        _ = commitContentEdit()
                    }
                }
            }

            if isEditingContent {
                editorControls
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 8)
        .frame(minHeight: ClipboardHUDMetrics.rowHeight)
        .contentShape(.rect(cornerRadius: 11))
        .background(
            isHovered ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
            in: .rect(cornerRadius: 11)
        )
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }

    @ViewBuilder
    private var leadingControl: some View {
        if payload.kind.benefitsFromThumbnail,
            let thumbnailProvider
        {
            if isEditingContent {
                ClipboardPayloadThumbnailView(
                    payload: payload,
                    provider: thumbnailProvider
                )
            } else {
                Button(action: copyToClipboard) {
                    ClipboardPayloadThumbnailView(
                        payload: payload,
                        provider: thumbnailProvider
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(copyAccessibilityLabel)
            }
        }
    }

    private var titleCopyButton: some View {
        Button(action: copyToClipboard) {
            Text(slot.title)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(copyAccessibilityLabel)
    }

    private var previewCopyButton: some View {
        Button(action: copyToClipboard) {
            ClipboardPreview(
                payload: payload
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "Copy \(slot.copyAccessibilityName) contents to clipboard"
        )
    }

    private var pasteButton: some View {
        Button("Paste", action: paste)
            .controlSize(.small)
            .buttonStyle(.borderless)
            .accessibilityLabel(pasteAccessibilityLabel)
            .help(pasteAccessibilityLabel)
    }

    private var editorControls: some View {
        HStack(spacing: 2) {
            Button {
                cancelEditing()
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 22, height: 24)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Cancel editing")
            .help("Cancel")

            Button {
                _ = commitContentEdit()
            } label: {
                Image(systemName: "checkmark")
                    .fontWeight(.semibold)
                    .frame(width: 22, height: 24)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Save changes")
            .help("Save")
        }
    }

    @ViewBuilder
    private var menuItems: some View {
        Button("Paste", systemImage: "doc.on.clipboard", action: paste)
        Divider()
        Button("Edit Contents…", systemImage: "text.cursor") {
            beginContentEditing()
        }
        .disabled(!canEditContents)
        Divider()
        Button("Delete Copy", systemImage: "trash", role: .destructive) {
            delete()
        }
    }

    private var canEditContents: Bool {
        payload.inlineTextEditability == .editable
    }

    private var editTarget: ClipboardHUDEditingSession.Target {
        let location: ClipboardHUDEditingSession.Location
        switch slot {
        case .numbered(let number):
            location = .numbered(number)
        case .named(let name):
            location = .temporaryNamed(name)
        }
        return ClipboardHUDEditingSession.Target(
            payloadID: payload.id,
            location: location,
            field: .content
        )
    }

    private var isEditingContent: Bool {
        editingSession.isEditing(editTarget)
    }

    private func beginContentEditing() {
        guard !isEditingContent,
            let text = payload.editableText
        else {
            return
        }
        let payloadID = payload.id
        _ = editingSession.begin(
            target: editTarget,
            initialDraft: text,
            commit: { text in
                try updateText(payloadID, text)
            }
        )
    }

    private var boundedContentDraft: Binding<String> {
        let sizeMessage = "Copy content must be 256 KB or smaller."
        return Binding(
            get: { editingSession.draft },
            set: { newValue in
                guard
                    newValue.utf8.count
                        <= ClipboardPayload.maximumInlineEditableTextBytes
                else {
                    editingSession.setValidationMessage(sizeMessage)
                    NSSound.beep()
                    return
                }
                editingSession.updateDraft(newValue)
                editingSession.clearValidationMessage(matching: sizeMessage)
            }
        )
    }

    @discardableResult
    private func commitContentEdit() -> Bool {
        guard isEditingContent else { return true }
        let didCommit = editingSession.commit(editTarget)
        if !didCommit {
            focusContentEditor()
        }
        return didCommit
    }

    private func cancelEditing() {
        focusLossIsArmed = false
        contentIsFocused = false
        editingSession.cancel(editTarget)
    }

    private func focusContentEditor() {
        focusLossIsArmed = false
        Task { @MainActor in
            await Task.yield()
            guard isEditingContent else { return }
            contentIsFocused = true

            await Task.yield()
            guard isEditingContent else { return }
            focusLossIsArmed = true
        }
    }

    private var editConflictMessage: String {
        "This temporary copy changed while you were editing. Cancel and edit the new copy."
    }

    private var copyAccessibilityLabel: String {
        "Copy \(slot.copyAccessibilityName) to clipboard"
    }

    private var pasteAccessibilityLabel: String {
        "Paste \(slot.actionAccessibilityName)"
    }

    private var deleteAccessibilityLabel: String {
        "Delete \(slot.actionAccessibilityName)"
    }

    private var editAccessibilityLabel: String {
        "Edit contents of \(slot.actionAccessibilityName)"
    }
}

struct PermanentCopyRow: View {
    private enum EditingField: Hashable {
        case name
        case content
    }

    let name: String
    let payload: ClipboardPayload
    let editingSession: ClipboardHUDEditingSession
    let copyToClipboard: () -> Void
    let paste: () -> Void
    let delete: () -> Void
    let rename: (UUID, String) throws -> String
    let updateText: (UUID, String) throws -> Void
    let thumbnailProvider: ClipboardThumbnailProvider?

    @State private var isHovered = false
    @State private var nameSelection: TextSelection?
    @State private var focusLossIsArmed = false
    @FocusState private var focusedField: EditingField?

    init(
        name: String,
        payload: ClipboardPayload,
        editingSession: ClipboardHUDEditingSession,
        copyToClipboard: @escaping () -> Void,
        paste: @escaping () -> Void,
        delete: @escaping () -> Void,
        rename: @escaping (UUID, String) throws -> String,
        updateText: @escaping (UUID, String) throws -> Void,
        thumbnailProvider: ClipboardThumbnailProvider? = nil
    ) {
        self.name = name
        self.payload = payload
        self.editingSession = editingSession
        self.copyToClipboard = copyToClipboard
        self.paste = paste
        self.delete = delete
        self.rename = rename
        self.updateText = updateText
        self.thumbnailProvider = thumbnailProvider
    }

    var body: some View {
        accessibleRow
            .onDisappear {
                editingSession.cancelEditing(payloadID: payload.id)
            }
            .onChange(of: payload) { oldPayload, newPayload in
                guard editingField != nil, newPayload != oldPayload else { return }
                editingSession.markConflict(
                    for: payload.id,
                    message: editConflictMessage
                )
                if let editingField {
                    focus(editingField, selectingAll: false)
                }
            }
            .onChange(of: name) { oldName, newName in
                guard editingField != nil, newName != oldName else { return }
                editingSession.markConflict(
                    for: payload.id,
                    message: editConflictMessage
                )
                if let editingField {
                    focus(editingField, selectingAll: false)
                }
            }
    }

    @ViewBuilder
    private var accessibleRow: some View {
        if canEditContents {
            interactiveRow
                .accessibilityAction(named: "Edit contents of permanent copy \(name)") {
                    beginContentEditing()
                }
        } else {
            interactiveRow
        }
    }

    private var interactiveRow: some View {
        row
            .contextMenu { menuItems }
            .accessibilityElement(children: .contain)
            .accessibilityAction(named: "Copy permanent copy \(name) to clipboard") {
                copyToClipboard()
            }
            .accessibilityAction(named: "Paste permanent copy \(name)") {
                paste()
            }
            .accessibilityAction(named: "Rename permanent copy \(name)") {
                beginNameEditing()
            }
            .accessibilityAction(named: "Delete permanent copy \(name)") {
                delete()
            }
    }

    private var row: some View {
        HStack(alignment: editingField == .content ? .top : .center, spacing: 10) {
            leadingControl

            editorOrLabels

            if editingField == nil {
                rowActions
            } else {
                editorControls
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 8)
        .frame(minHeight: ClipboardHUDMetrics.rowHeight)
        .contentShape(.rect(cornerRadius: 11))
        .background(
            isHovered ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
            in: .rect(cornerRadius: 11)
        )
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }

    @ViewBuilder
    private var leadingControl: some View {
        if payload.kind.benefitsFromThumbnail,
            let thumbnailProvider
        {
            if editingField == nil {
                Button(action: copyToClipboard) {
                    ClipboardPayloadThumbnailView(
                        payload: payload,
                        provider: thumbnailProvider
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy permanent copy \(name) to clipboard")
            } else {
                ClipboardPayloadThumbnailView(
                    payload: payload,
                    provider: thumbnailProvider
                )
            }
        }
    }

    private var rowActions: some View {
        VStack(spacing: 0) {
            Button("Paste", action: paste)
                .controlSize(.small)
                .buttonStyle(.borderless)
                .accessibilityLabel("Paste permanent copy \(name)")
                .help("Paste permanent copy \(name)")

            optionsMenu
        }
    }

    @ViewBuilder
    private var editorOrLabels: some View {
        VStack(alignment: .leading, spacing: 2) {
            if editingField == .name {
                TextField(
                    "Permanent copy name",
                    text: editingDraft,
                    selection: $nameSelection
                )
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .name)
                .onAppear {
                    focus(.name, selectingAll: true)
                }
                .onSubmit {
                    _ = commitCurrentEdit()
                }
                .onKeyPress(.escape) {
                    cancelEditing()
                    return .handled
                }
                .accessibilityLabel("Permanent copy name")
            } else {
                Button(action: copyToClipboard) {
                    Text(displayName)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy permanent copy \(name) to clipboard")
                .help("Copy permanent copy \(name) to clipboard")
            }

            if editingField == .content {
                TextEditor(text: boundedContentDraft)
                    .font(.callout)
                    .scrollContentBackground(.hidden)
                    .padding(5)
                    .frame(height: ClipboardHUDMetrics.inlineContentEditorHeight)
                    .background(.quaternary, in: .rect(cornerRadius: 7))
                    .focused($focusedField, equals: .content)
                    .onAppear {
                        focus(.content, selectingAll: false)
                    }
                    .onKeyPress(.escape) {
                        cancelEditing()
                        return .handled
                    }
                    .onKeyPress(.return, phases: .down) { press in
                        guard press.modifiers.contains(.command) else {
                            return .ignored
                        }
                        _ = commitCurrentEdit()
                        return .handled
                    }
                    .accessibilityLabel("Permanent copy contents")
                    .accessibilityHint("Press Command-Return to save or Escape to cancel")
            } else {
                Button(action: copyToClipboard) {
                    ClipboardPreview(
                        payload: payload,
                        additionalHelp: contentHelp
                    )
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy permanent copy \(name) contents to clipboard")
            }

            if let validationMessage = editingSession.validationMessage {
                Text(validationMessage)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Editing error: \(validationMessage)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: focusedField) { oldValue, newValue in
            guard oldValue != nil, newValue == nil, editingField != nil else {
                return
            }
            guard focusLossIsArmed else {
                if let editingField {
                    focus(editingField, selectingAll: false)
                }
                return
            }
            Task { @MainActor in
                await Task.yield()
                if editingField != nil, focusedField == nil {
                    _ = commitCurrentEdit()
                }
            }
        }
    }

    private var editorControls: some View {
        HStack(spacing: 2) {
            Button {
                cancelEditing()
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 22, height: 24)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Cancel editing")
            .help("Cancel")

            Button {
                _ = commitCurrentEdit()
            } label: {
                Image(systemName: "checkmark")
                    .fontWeight(.semibold)
                    .frame(width: 22, height: 24)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Save changes")
            .help("Save")
        }
    }

    private var optionsMenu: some View {
        Menu {
            menuItems
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 24, height: 28)
                .contentShape(.rect)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Permanent copy \(name) options")
        .help("Permanent copy options")
    }

    @ViewBuilder
    private var menuItems: some View {
        Button("Paste", systemImage: "doc.on.clipboard", action: paste)
        Divider()
        Button("Rename…", systemImage: "pencil") {
            beginNameEditing()
        }

        Button("Edit Contents…", systemImage: "text.cursor") {
            beginContentEditing()
        }
        .disabled(!canEditContents)

        Divider()
        Button("Delete Copy", systemImage: "trash", role: .destructive) {
            delete()
        }
    }

    private var canEditContents: Bool {
        payload.inlineTextEditability == .editable
    }

    private var nameEditTarget: ClipboardHUDEditingSession.Target {
        ClipboardHUDEditingSession.Target(
            payloadID: payload.id,
            location: .permanent,
            field: .name
        )
    }

    private var contentEditTarget: ClipboardHUDEditingSession.Target {
        ClipboardHUDEditingSession.Target(
            payloadID: payload.id,
            location: .permanent,
            field: .content
        )
    }

    private var editingField: EditingField? {
        if editingSession.isEditing(nameEditTarget) {
            return .name
        }
        if editingSession.isEditing(contentEditTarget) {
            return .content
        }
        return nil
    }

    private var activeEditTarget: ClipboardHUDEditingSession.Target? {
        switch editingField {
        case .name:
            nameEditTarget
        case .content:
            contentEditTarget
        case nil:
            nil
        }
    }

    private var editingDraft: Binding<String> {
        Binding(
            get: { editingSession.draft },
            set: { editingSession.updateDraft($0) }
        )
    }

    private var displayName: String {
        name.prefix(1).uppercased() + String(name.dropFirst())
    }

    private var contentHelp: String? {
        switch payload.inlineTextEditability {
        case .editable:
            nil
        case .notPlainText:
            "Only plain-text permanent copies can be edited"
        case .tooLarge:
            "Text larger than 256 KB can be pasted but not edited here"
        case .invalidEncoding:
            "This text encoding cannot be edited safely"
        }
    }

    private func beginNameEditing() {
        guard editingField == nil else { return }
        let payloadID = payload.id
        _ = editingSession.begin(
            target: nameEditTarget,
            initialDraft: name,
            commit: { requestedName in
                _ = try rename(payloadID, requestedName)
            }
        )
    }

    private func beginContentEditing() {
        guard editingField == nil,
            let text = payload.editableText
        else {
            return
        }
        let payloadID = payload.id
        _ = editingSession.begin(
            target: contentEditTarget,
            initialDraft: text,
            commit: { text in
                try updateText(payloadID, text)
            }
        )
    }

    private var boundedContentDraft: Binding<String> {
        let sizeMessage = "Permanent copy content must be 256 KB or smaller."
        return Binding(
            get: { editingSession.draft },
            set: { newValue in
                guard newValue.utf8.count <= ClipboardPayload.maximumInlineEditableTextBytes else {
                    editingSession.setValidationMessage(sizeMessage)
                    NSSound.beep()
                    return
                }
                editingSession.updateDraft(newValue)
                editingSession.clearValidationMessage(matching: sizeMessage)
            }
        )
    }

    @discardableResult
    private func commitCurrentEdit() -> Bool {
        guard let editingField, let activeEditTarget else { return true }
        let didCommit = editingSession.commit(activeEditTarget)
        if didCommit {
            focusedField = nil
            nameSelection = nil
            focusLossIsArmed = false
        } else {
            focus(editingField, selectingAll: false)
        }
        return didCommit
    }

    private func cancelEditing() {
        guard let activeEditTarget else { return }
        editingSession.cancel(activeEditTarget)
        focusedField = nil
        nameSelection = nil
        focusLossIsArmed = false
    }

    private var editConflictMessage: String {
        "This permanent copy changed while you were editing. Cancel and edit the new copy."
    }

    private func focus(_ field: EditingField, selectingAll: Bool) {
        focusLossIsArmed = false
        Task { @MainActor in
            await Task.yield()
            guard editingField == field else { return }
            focusedField = field
            if selectingAll, field == .name {
                let draft = editingSession.draft
                nameSelection = TextSelection(
                    range: draft.startIndex..<draft.endIndex
                )
            }

            await Task.yield()
            guard editingField == field else { return }
            focusLossIsArmed = true
        }
    }
}

extension ClipboardContentKind {
    fileprivate var benefitsFromThumbnail: Bool {
        switch self {
        case .image, .files, .mixed:
            true
        case .text, .data:
            false
        }
    }
}

private struct ClipboardPayloadThumbnailView: View {
    let payload: ClipboardPayload
    let provider: ClipboardThumbnailProvider

    @State private var thumbnail: NSImage?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: payload.kind.systemImage)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 34, height: 34)
            .background(.quaternary, in: .rect(cornerRadius: 9))
            .clipShape(.rect(cornerRadius: 9))

            if payload.items.count > 1 {
                Text("\(payload.items.count)")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .frame(minHeight: 13)
                    .background(.primary, in: .capsule)
                    .offset(x: 3, y: 3)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: 38, height: 38)
        .accessibilityHidden(true)
        .task(id: payload.id) {
            thumbnail = nil
            thumbnail = await provider.thumbnail(for: payload)
        }
    }
}
