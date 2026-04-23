import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct ComposeView: View {
    @Environment(AppState.self) private var state
    @FocusState private var focus: Field?
    @State private var dropHighlight: Bool = false
    @State private var sendWarning: SendWarning?
    /// Held by the rich-text toolbar so buttons can reach the live NSTextView.
    @State private var editorHandle = RichTextEditorHandle()
    /// Hidden by default — clicking "Cc/Bcc" next to the To field expands
    /// these. Gmail / Apple Mail / iOS Mail all use this pattern to save
    /// vertical space when the user doesn't need those fields.
    @State private var showCcBcc: Bool = false

    enum Field { case to, cc, bcc, subject }

    /// A warning surfaced on "Send" click that the user must acknowledge.
    struct SendWarning: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    var body: some View {
        @Bindable var bound = state.compose

        VStack(spacing: 0) {
            header
            Divider().opacity(0.3)

            fromRow
            Divider().opacity(0.1)
            toRow
                .onChange(of: state.compose.to) { _, _ in state.scheduleAutosave() }
            if showCcBcc || !state.compose.cc.isEmpty || !state.compose.bcc.isEmpty {
                Divider().opacity(0.1)
                tokenRow(label: "Cc", binding: $bound.cc)
                    .onChange(of: state.compose.cc) { _, _ in state.scheduleAutosave() }
                Divider().opacity(0.1)
                tokenRow(label: "Bcc", binding: $bound.bcc)
                    .onChange(of: state.compose.bcc) { _, _ in state.scheduleAutosave() }
            }
            Divider().opacity(0.1)
            textFieldRow(label: "Subject", binding: $bound.subject, field: .subject)
                .onChange(of: state.compose.subject) { _, _ in state.scheduleAutosave() }
            Divider().opacity(0.1)

            if !state.compose.attachments.isEmpty {
                attachmentsRow
                Divider().opacity(0.1)
            }

            RichTextToolbar(textViewProvider: { editorHandle.textView })
            Divider().opacity(0.1)

            RichTextEditor(
                attributedText: $bound.bodyAttributed,
                onEdit: { state.scheduleAutosave() },
                handle: editorHandle
            )

            signaturePreview

            footer
        }
        .onAppear {
            if state.compose.to.isEmpty {
                focus = .to
            } else if state.compose.body.isEmpty {
                // Hand focus to the NSTextView after the window exists.
                DispatchQueue.main.async {
                    if let tv = editorHandle.textView {
                        tv.window?.makeFirstResponder(tv)
                    }
                }
            }
        }
        // Drag files (from Finder etc.) onto any part of compose → attach.
        .onDrop(of: [.fileURL], isTargeted: $dropHighlight) { providers in
            handleDroppedProviders(providers)
        }
        .overlay {
            if dropHighlight {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(2)
                    .allowsHitTesting(false)
            }
        }
        // Cmd-Shift-V → pull the current pasteboard image into attachments.
        // (NSTextView handles text paste natively; this only covers images,
        //  which otherwise become unusable binary blobs in the body.)
        .background(
            Button("") { pasteImageFromClipboard() }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                .opacity(0)
                .allowsHitTesting(false)
        )
        .alert(item: $sendWarning) { warning in
            Alert(
                title: Text(warning.title),
                message: Text(warning.message),
                primaryButton: .default(Text("Send Anyway")) {
                    Task { _ = await state.send() }
                },
                secondaryButton: .cancel()
            )
        }
    }

    /// Two soft guards before send: subject-empty warning and an
    /// "attached-but-no-attachment" heuristic. Returns nil when clear.
    private func validateBeforeSend() -> SendWarning? {
        let subject = state.compose.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        if subject.isEmpty {
            return SendWarning(
                title: "Send without a subject?",
                message: "Recipients often filter out messages without a subject. You can go back and add one."
            )
        }
        if state.compose.attachments.isEmpty {
            let body = state.compose.body.lowercased()
            let tokens = ["attached", "attaching", "attachment", "enclosed", "see attached"]
            if tokens.contains(where: body.contains) {
                return SendWarning(
                    title: "You mentioned an attachment",
                    message: "Your message references an attachment but nothing is attached. Send anyway?"
                )
            }
        }
        return nil
    }

    /// Shared send entrypoint — validations, then hands to AppState.
    private func attemptSend() {
        if let warning = validateBeforeSend() {
            sendWarning = warning
            return
        }
        Task { _ = await state.send() }
    }

    private func handleDroppedProviders(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                accepted = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    let url: URL?
                    if let data = item as? Data {
                        url = URL(dataRepresentation: data, relativeTo: nil)
                    } else if let u = item as? URL {
                        url = u
                    } else {
                        url = nil
                    }
                    if let url {
                        Task { @MainActor in
                            // Route every add through AppState so autosave
                            // fires. Previously a dropped file updated
                            // compose.attachments directly and the debounce
                            // scheduler stayed idle — closing the popover
                            // before typing dropped the file on the floor.
                            state.addAttachment(url)
                        }
                    }
                }
            }
        }
        return accepted
    }

    /// Looks at the current system pasteboard. If an image is present, writes
    /// it to a temp file (Minimail-paste-{timestamp}.png) and adds it to the
    /// attachment list so Resend sends it as a proper attachment.
    private func pasteImageFromClipboard() {
        let pb = NSPasteboard.general
        guard let images = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
              let image = images.first else { return }
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }

        let filename = "Minimail-paste-\(Int(Date().timeIntervalSince1970)).png"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        do {
            try png.write(to: url)
            state.addAttachment(url)
        } catch {
            state.compose.error = "Couldn't save pasted image: \(error.localizedDescription)"
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button {
                Task { await state.flushAutosave() }
                if let id = state.compose.replyToID {
                    state.router.currentView = .reader(id)
                } else {
                    state.router.currentView = .inbox
                }
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(IconButtonStyle())
            .keyboardShortcut(.cancelAction)
            .help("Close (saves draft)")
            .accessibilityLabel("Close compose — draft saved")

            Text(title)
                .font(.system(size: 13, weight: .semibold))

            savedIndicator

            Spacer()

            Button { pickAttachments() } label: {
                Image(systemName: "paperclip")
            }
            .buttonStyle(IconButtonStyle())
            .help("Attach files (⌘⇧K)")
            .accessibilityLabel("Attach files")
            .keyboardShortcut("k", modifiers: [.command, .shift])

            Menu {
                Button("Save & Close") {
                    Task {
                        await state.flushAutosave()
                        state.router.currentView = .inbox
                    }
                }
                Divider()
                Button("Discard Draft", role: .destructive) {
                    Task { await state.discardDraft() }
                }
                .disabled(state.compose.editingDraftID == nil)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("More actions")
            .accessibilityLabel("More compose actions")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var savedIndicator: some View {
        if state.compose.editingDraftID != nil {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(savedText)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 4)
            }
        }
    }

    private var savedText: String {
        guard let at = state.compose.lastAutosaveAt else { return "Draft saved" }
        let delta = Date().timeIntervalSince(at)
        if delta < 3 { return "Saved" }
        if delta < 60 { return "Saved \(Int(delta))s ago" }
        let mins = Int(delta / 60)
        return mins < 60 ? "Saved \(mins)m ago" : "Draft saved"
    }

    private func pickAttachments() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK {
            state.addAttachments(panel.urls)
        }
    }

    private var title: String {
        if state.compose.replyToID != nil {
            return state.compose.replyAll ? "Reply All" : "Reply"
        }
        if state.compose.forwardingID != nil { return "Forward" }
        return "New message"
    }

    private var fromRow: some View {
        // Resolved sender — fromOverride wins, else composeFromAccount.
        // Picking a different From in the dropdown sets fromOverride only;
        // it does NOT change the inbox view (so an All-Accounts user can
        // pick a sender without leaving the unified inbox).
        let resolved = state.compose.fromOverride ?? state.composeFromAccount
        let resolvedEmail = resolved?.email ?? "No account"
        return HStack(spacing: 10) {
            Text("From")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .frame(width: 52, alignment: .leading)
            Menu {
                ForEach(state.session.accounts) { acct in
                    Button {
                        state.compose.fromOverride = acct
                    } label: {
                        if acct.email == resolvedEmail {
                            Label(acct.email, systemImage: "checkmark")
                        } else {
                            Text(acct.email)
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    AccountAvatar(email: resolvedEmail)
                    Text(resolvedEmail)
                        .font(.system(size: 12))
                        .foregroundStyle(.primary)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.06), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func tokenRow(label: String, binding: Binding<String>) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .frame(width: 52, alignment: .leading)
                .padding(.top, 4)
            EmailTokenField(text: binding, placeholder: "", suggestions: state.contactIndex)
                .frame(minHeight: 24)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    /// Variant of tokenRow for the primary "To" field with a trailing
    /// "Cc/Bcc" toggle button. Clicking it reveals / hides the Cc and Bcc
    /// rows below, saving vertical space in the compact popover layout when
    /// the user doesn't need them.
    private var toRow: some View {
        @Bindable var bound = state.compose
        return HStack(alignment: .top, spacing: 10) {
            Text("To")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .frame(width: 52, alignment: .leading)
                .padding(.top, 4)
            EmailTokenField(text: $bound.to, placeholder: "", suggestions: state.contactIndex)
                .frame(minHeight: 24)
            if !showCcBcc && state.compose.cc.isEmpty && state.compose.bcc.isEmpty {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { showCcBcc = true }
                } label: {
                    Text("Cc / Bcc")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(Color.primary.opacity(0.06))
                        )
                }
                .buttonStyle(.plain)
                .help("Reveal Cc and Bcc fields")
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private var attachmentsRow: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("Files")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .frame(width: 52, alignment: .leading)
                .padding(.top, 4)
            FlowLayout(spacing: 6) {
                ForEach(state.compose.attachments, id: \.self) { url in
                    ComposeAttachmentChip(url: url) {
                        state.removeAttachment(url)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private func textFieldRow(label: String, binding: Binding<String>, field: Field) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .frame(width: 52, alignment: .leading)
            TextField("", text: binding)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focus, equals: field)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    /// Muted preview of what the resolved sender's signature will add to
    /// the outgoing message. Nil/empty signature hides the row entirely.
    /// Reads from `composeFromAccount` (or `fromOverride`) so the preview
    /// stays correct even in All-Accounts mode where currentAccount is nil.
    @ViewBuilder
    private var signaturePreview: some View {
        let sender = state.compose.fromOverride ?? state.composeFromAccount
        if let sig = sender?.signature,
           !sig.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Divider().opacity(0.1)
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "signature")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Text(sig)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.02))
            }
        }
    }

    private var footer: some View {
        HStack {
            if let err = state.compose.error {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                Text(err)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .lineLimit(1)
            } else {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            sendButton
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(state.compose.isSending || state.compose.to.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.04))
    }

    private var subtitle: String {
        if state.compose.replyToID != nil { return "Threaded reply · plain text" }
        if state.compose.forwardingID != nil { return "Forward · plain text" }
        return "Plain text"
    }

    @ViewBuilder
    private var sendButton: some View {
        let sending = state.compose.isSending
        Button {
            attemptSend()
        } label: {
            HStack(spacing: 6) {
                if sending {
                    ProgressView().controlSize(.small).tint(.white)
                }
                Text(sending ? "Sending…" : "Send")
                    .font(.system(size: 12, weight: .semibold))
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .opacity(sending ? 0 : 1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .foregroundStyle(.white)
            .background(
                LinearGradient(
                    colors: [Color.accentColor, Color.accentColor.opacity(0.85)],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                in: Capsule()
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Send (⌘↩)")
    }
}
