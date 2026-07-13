import AppKit
import SwiftUI

struct ClipboardSlotRowStyle {
    let previewLineLimit: Int
    let minimumHeight: CGFloat
    let showsThumbnail: Bool

    static let dashboard = ClipboardSlotRowStyle(
        previewLineLimit: 1,
        minimumHeight: 49,
        showsThumbnail: false
    )
    static let hud = ClipboardSlotRowStyle(
        previewLineLimit: 2,
        minimumHeight: ClipboardHUDMetrics.rowHeight,
        showsThumbnail: true
    )
}

struct NumberedCopyRow: View {
    let number: Int
    let payload: ClipboardPayload
    let paste: () -> Void
    let delete: () -> Void
    let style: ClipboardSlotRowStyle
    let thumbnailProvider: ClipboardThumbnailProvider?

    @State private var isHovered = false

    init(
        number: Int,
        payload: ClipboardPayload,
        paste: @escaping () -> Void,
        delete: @escaping () -> Void,
        style: ClipboardSlotRowStyle = .dashboard,
        thumbnailProvider: ClipboardThumbnailProvider? = nil
    ) {
        self.number = number
        self.payload = payload
        self.paste = paste
        self.delete = delete
        self.style = style
        self.thumbnailProvider = thumbnailProvider
    }

    var body: some View {
        row
            .contextMenu { menuItems }
            .accessibilityElement(children: .contain)
            .accessibilityAction(named: "Paste slot \(number)") {
                paste()
            }
            .accessibilityAction(named: "Delete slot \(number)") {
                delete()
            }
    }

    private var row: some View {
        HStack(spacing: 10) {
            leadingView

            VStack(alignment: .leading, spacing: 2) {
                Text("Slot \(number)")
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(payload.preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(style.previewLineLimit)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button("Paste", action: paste)
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderless)
                .accessibilityLabel("Paste slot \(number)")
                .help("Paste slot \(number)")

            optionsMenu
        }
        .padding(.leading, 10)
        .padding(.trailing, 5)
        .frame(minHeight: style.minimumHeight)
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
    private var leadingView: some View {
        if style.showsThumbnail, let thumbnailProvider {
            ClipboardPayloadThumbnailView(
                payload: payload,
                provider: thumbnailProvider
            )
        } else {
            Text("\(number)")
                .font(.callout.monospacedDigit().weight(.semibold))
                .frame(width: 30, height: 30)
                .background(.quaternary, in: .rect(cornerRadius: 8))
                .accessibilityHidden(true)
        }
    }

    private var optionsMenu: some View {
        Menu { menuItems } label: {
            Image(systemName: "ellipsis")
                .frame(width: 24, height: 28)
                .contentShape(.rect)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Slot \(number) options")
        .help("Slot \(number) options")
    }

    @ViewBuilder
    private var menuItems: some View {
        Button("Paste", systemImage: "doc.on.clipboard", action: paste)
        Divider()
        Button("Delete Copy", systemImage: "trash", role: .destructive) {
            delete()
        }
    }
}

struct TemporaryNamedCopyRow: View {
    let name: String
    let payload: ClipboardPayload
    let paste: () -> Void
    let delete: () -> Void
    let style: ClipboardSlotRowStyle
    let thumbnailProvider: ClipboardThumbnailProvider?

    @State private var isHovered = false

    init(
        name: String,
        payload: ClipboardPayload,
        paste: @escaping () -> Void,
        delete: @escaping () -> Void,
        style: ClipboardSlotRowStyle = .dashboard,
        thumbnailProvider: ClipboardThumbnailProvider? = nil
    ) {
        self.name = name
        self.payload = payload
        self.paste = paste
        self.delete = delete
        self.style = style
        self.thumbnailProvider = thumbnailProvider
    }

    var body: some View {
        row
            .contextMenu { menuItems }
            .accessibilityElement(children: .contain)
            .accessibilityAction(named: "Paste copy \(name)") {
                paste()
            }
            .accessibilityAction(named: "Delete copy \(name)") {
                delete()
            }
    }

    private var row: some View {
        HStack(spacing: 10) {
            leadingView

            VStack(alignment: .leading, spacing: 2) {
                Text("Copy \(displayName)")
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(payload.preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(style.previewLineLimit)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button("Paste", action: paste)
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderless)
                .accessibilityLabel("Paste copy \(name)")
                .help("Paste copy \(name)")

            optionsMenu
        }
        .padding(.leading, 10)
        .padding(.trailing, 5)
        .frame(minHeight: style.minimumHeight)
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
    private var leadingView: some View {
        if style.showsThumbnail, let thumbnailProvider {
            ClipboardPayloadThumbnailView(
                payload: payload,
                provider: thumbnailProvider
            )
        } else {
            Image(systemName: "tag.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background(.quaternary, in: .rect(cornerRadius: 8))
                .accessibilityHidden(true)
        }
    }

    private var optionsMenu: some View {
        Menu { menuItems } label: {
            Image(systemName: "ellipsis")
                .frame(width: 24, height: 28)
                .contentShape(.rect)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Copy \(name) options")
        .help("Copy \(name) options")
    }

    @ViewBuilder
    private var menuItems: some View {
        Button("Paste", systemImage: "doc.on.clipboard", action: paste)
        Divider()
        Button("Delete Copy", systemImage: "trash", role: .destructive) {
            delete()
        }
    }

    private var displayName: String {
        name.prefix(1).uppercased() + String(name.dropFirst())
    }
}

struct PermanentCopyRow: View {
    private enum EditingField: Hashable {
        case name
        case content
    }

    let name: String
    let payload: ClipboardPayload
    let editingSession: DashboardEditingSession
    let paste: () -> Void
    let delete: () -> Void
    let rename: (UUID, String) throws -> String
    let updateText: (UUID, String) throws -> Void
    let style: ClipboardSlotRowStyle
    let thumbnailProvider: ClipboardThumbnailProvider?

    @State private var editingField: EditingField?
    @State private var nameDraft = ""
    @State private var contentDraft = ""
    @State private var validationMessage: String?
    @State private var isHovered = false
    @State private var editingToken: DashboardEditingSession.Token?
    @State private var editingPayloadID: UUID?
    @State private var editingPayloadSnapshot: ClipboardPayload?
    @State private var editingOriginalName: String?
    @State private var focusLossIsArmed = false
    @FocusState private var focusedField: EditingField?

    init(
        name: String,
        payload: ClipboardPayload,
        editingSession: DashboardEditingSession,
        paste: @escaping () -> Void,
        delete: @escaping () -> Void,
        rename: @escaping (UUID, String) throws -> String,
        updateText: @escaping (UUID, String) throws -> Void,
        style: ClipboardSlotRowStyle = .dashboard,
        thumbnailProvider: ClipboardThumbnailProvider? = nil
    ) {
        self.name = name
        self.payload = payload
        self.editingSession = editingSession
        self.paste = paste
        self.delete = delete
        self.rename = rename
        self.updateText = updateText
        self.style = style
        self.thumbnailProvider = thumbnailProvider
    }

    @ViewBuilder
    var body: some View {
        Group {
            if editingField == nil {
                idleAccessibleRow
            } else {
                row
                    .accessibilityElement(children: .contain)
            }
        }
        .onDisappear {
            if editingField != nil { cancelEditing() }
        }
        .onChange(of: payload) { _, newPayload in
            guard editingField != nil,
                  let editingPayloadSnapshot,
                  newPayload != editingPayloadSnapshot else {
                return
            }
            validationMessage = editConflictMessage
            if let editingField {
                focus(editingField, selectingAll: false)
            }
        }
        .onChange(of: name) { _, newName in
            guard editingField != nil,
                  let editingOriginalName,
                  newName != editingOriginalName else {
                return
            }
            validationMessage = editConflictMessage
            if let editingField {
                focus(editingField, selectingAll: false)
            }
        }
    }

    @ViewBuilder
    private var idleAccessibleRow: some View {
        if canEditContents {
            idleRowActions
                .accessibilityAction(named: "Edit contents of permanent copy \(name)") {
                    beginContentEditing()
                }
        } else {
            idleRowActions
        }
    }

    private var idleRowActions: some View {
        row
            .contextMenu { menuItems }
            .accessibilityElement(children: .contain)
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
            leadingView

            editorOrLabels

            if editingField == nil {
                Button("Paste", action: paste)
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Paste permanent copy \(name)")
                    .help("Paste permanent copy \(name)")

                optionsMenu
            } else {
                editorControls
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 5)
        .padding(.vertical, editingField == .content ? 8 : 0)
        .frame(minHeight: style.minimumHeight)
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
    private var leadingView: some View {
        if style.showsThumbnail, let thumbnailProvider {
            ClipboardPayloadThumbnailView(
                payload: payload,
                provider: thumbnailProvider
            )
        } else {
            Image(systemName: "pin.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background(.quaternary, in: .circle)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var editorOrLabels: some View {
        VStack(alignment: .leading, spacing: 3) {
            if editingField == .name {
                TextField("Permanent copy name", text: $nameDraft)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .name)
                    .onSubmit {
                        _ = commitCurrentEdit()
                    }
                    .onKeyPress(.escape) {
                        cancelEditing()
                        return .handled
                    }
                    .accessibilityLabel("Permanent copy name")
            } else {
                Text(name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .contentShape(.rect)
                    .onTapGesture(count: 2) {
                        beginNameEditing()
                    }
                    .accessibilityLabel("Permanent copy name, \(name)")
                    .help("Double-click to rename")
            }

            if editingField == .content {
                TextEditor(text: boundedContentDraft)
                    .font(.caption)
                    .scrollContentBackground(.hidden)
                    .padding(5)
                    .frame(minHeight: 64, maxHeight: 96)
                    .background(.quaternary, in: .rect(cornerRadius: 7))
                    .focused($focusedField, equals: .content)
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
                Text(payload.preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(style.previewLineLimit)
                    .contentShape(.rect)
                    .onTapGesture(count: 2) {
                        if canEditContents { beginContentEditing() }
                    }
                    .accessibilityLabel("Contents, \(payload.preview)")
                    .help(contentHelp)
            }

            if let validationMessage {
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
        Menu { menuItems } label: {
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

    private var contentHelp: String {
        switch payload.inlineTextEditability {
        case .editable:
            "Double-click to edit contents"
        case .notPlainText:
            "Only plain-text permanent copies can be edited"
        case .tooLarge:
            "Text larger than 256 KB can be pasted but not edited here"
        case .invalidEncoding:
            "This text encoding cannot be edited safely"
        }
    }

    private func beginNameEditing() {
        guard editingField == nil,
              let token = editingSession.begin(
                commit: { commitCurrentEdit() },
                cancel: { cancelEditing() }
              ) else {
            return
        }
        nameDraft = name
        validationMessage = nil
        focusLossIsArmed = false
        editingToken = token
        editingPayloadID = payload.id
        editingPayloadSnapshot = payload
        editingOriginalName = name
        editingField = .name
        focus(.name, selectingAll: true)
    }

    private func beginContentEditing() {
        guard editingField == nil,
              let text = payload.editableText,
              let token = editingSession.begin(
                commit: { commitCurrentEdit() },
                cancel: { cancelEditing() }
              ) else {
            return
        }
        contentDraft = text
        validationMessage = nil
        focusLossIsArmed = false
        editingToken = token
        editingPayloadID = payload.id
        editingPayloadSnapshot = payload
        editingOriginalName = name
        editingField = .content
        focus(.content, selectingAll: false)
    }

    private var boundedContentDraft: Binding<String> {
        let sizeMessage = "Permanent copy content must be 256 KB or smaller."
        return Binding(
            get: { contentDraft },
            set: { newValue in
                guard newValue.utf8.count <= ClipboardPayload.maximumInlineEditableTextBytes else {
                    validationMessage = sizeMessage
                    NSSound.beep()
                    return
                }
                contentDraft = newValue
                if validationMessage == sizeMessage {
                    validationMessage = nil
                }
            }
        )
    }

    @discardableResult
    private func commitCurrentEdit() -> Bool {
        guard let editingField else { return true }
        guard let editingPayloadID,
              editingPayloadID == payload.id,
              editingPayloadSnapshot == payload,
              editingOriginalName == name else {
            validationMessage = editConflictMessage
            focus(editingField, selectingAll: false)
            return false
        }

        do {
            switch editingField {
            case .name:
                _ = try rename(editingPayloadID, nameDraft)
            case .content:
                try updateText(editingPayloadID, contentDraft)
            }
            clearDrafts()
            self.editingField = nil
            self.editingPayloadID = nil
            editingPayloadSnapshot = nil
            editingOriginalName = nil
            focusedField = nil
            validationMessage = nil
            focusLossIsArmed = false
            finishEditingSession()
            return true
        } catch {
            validationMessage = error.localizedDescription
            focus(editingField, selectingAll: false)
            return false
        }
    }

    private func cancelEditing() {
        clearDrafts()
        editingField = nil
        editingPayloadID = nil
        editingPayloadSnapshot = nil
        editingOriginalName = nil
        focusedField = nil
        validationMessage = nil
        focusLossIsArmed = false
        finishEditingSession()
    }

    private func finishEditingSession() {
        guard let editingToken else { return }
        self.editingToken = nil
        editingSession.finish(editingToken)
    }

    private var editConflictMessage: String {
        "This permanent copy changed while you were editing. Cancel and edit the new copy."
    }

    private func clearDrafts() {
        nameDraft = String()
        contentDraft = String()
    }

    private func focus(_ field: EditingField, selectingAll: Bool) {
        let token = editingToken
        Task { @MainActor in
            await Task.yield()
            guard editingField == field, editingToken == token else { return }
            focusedField = field
            if selectingAll {
                await Task.yield()
                if editingField == field,
                   editingToken == token,
                   let fieldEditor = NSApplication.shared.keyWindow?.firstResponder as? NSTextView {
                    fieldEditor.selectAll(nil)
                }
            }

            try? await Task.sleep(for: .milliseconds(200))
            guard editingField == field, editingToken == token else { return }
            focusLossIsArmed = true
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
