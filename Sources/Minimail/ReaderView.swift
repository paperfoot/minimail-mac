import SwiftUI

struct ReaderView: View {
    let messageID: Int64
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.3)
            content
            footer
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button { state.back() } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(IconButtonStyle())
            .keyboardShortcut(.escape, modifiers: [])

            Text(state.reader.loaded?.displaySubject ?? "Loading…")
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)

            Spacer()

            if let msg = state.reader.loaded {
                Button { state.startCompose(replyTo: msg) } label: {
                    Image(systemName: "arrowshape.turn.up.left")
                }
                .buttonStyle(IconButtonStyle())
                .help("Reply (⌘R)")
                .keyboardShortcut("r", modifiers: .command)

                Button { state.startCompose(replyTo: msg, replyAll: true) } label: {
                    Image(systemName: "arrowshape.turn.up.left.2")
                }
                .buttonStyle(IconButtonStyle())
                .help("Reply All (⌘⇧R)")
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Button { state.startForward(of: msg) } label: {
                    Image(systemName: "arrowshape.turn.up.right")
                }
                .buttonStyle(IconButtonStyle())
                .help("Forward (⌘⇧F)")
                .keyboardShortcut("f", modifiers: [.command, .shift])

                Button {
                    Task { await state.archive(message: msg) }
                } label: {
                    Image(systemName: "archivebox")
                }
                .buttonStyle(IconButtonStyle())
                .help("Archive (⌘⌫)")
                .keyboardShortcut(.delete, modifiers: .command)

                Menu {
                    Button("Mark as Unread") {
                        Task {
                            await state.markUnread(message: msg)
                            state.back()
                        }
                    }
                    Divider()
                    Button("Delete…", role: .destructive) {
                        state.compose.pendingDeleteConfirm = msg.id
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 28, height: 28)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .confirmationDialog(
            "Delete permanently?",
            isPresented: Binding(
                get: { state.compose.pendingDeleteConfirm != nil },
                set: { if !$0 { state.compose.pendingDeleteConfirm = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let id = state.compose.pendingDeleteConfirm,
                   let msg = state.reader.loaded, msg.id == id {
                    Task { await state.delete(message: msg) }
                }
                state.compose.pendingDeleteConfirm = nil
            }
            Button("Archive instead") {
                if let msg = state.reader.loaded {
                    Task { await state.archive(message: msg) }
                }
                state.compose.pendingDeleteConfirm = nil
            }
            Button("Cancel", role: .cancel) {
                state.compose.pendingDeleteConfirm = nil
            }
        } message: {
            Text("This removes the message from your local mailbox. Use Archive to keep it out of the inbox without deleting.")
        }
    }

    @ViewBuilder
    private var content: some View {
        if let msg = state.reader.loaded {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    fromRow(msg)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    Divider().opacity(0.3)

                    Group {
                        if let html = msg.html_body, !html.isEmpty {
                            HTMLBodyView(html: html)
                                .frame(minHeight: 300)
                        } else if let text = msg.text_body, !text.isEmpty {
                            Text(text)
                                .font(.system(size: 13))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 14)
                                .textSelection(.enabled)
                        } else if state.reader.isLoading {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 40)
                        } else {
                            Text("(no body)")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .padding(16)
                        }
                    }

                    if !state.reader.attachments.isEmpty {
                        attachmentsBar(messageID: msg.id)
                    }
                }
            }
        } else if let err = state.reader.error {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.circle").font(.system(size: 28)).opacity(0.5)
                Text("Couldn't load message")
                    .font(.system(size: 13, weight: .semibold))
                Text(err)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                Button("Back to inbox") { state.back() }
                    .controlSize(.small)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func attachmentsBar(messageID: Int64) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "paperclip")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Text("\(state.reader.attachments.count) attachment\(state.reader.attachments.count == 1 ? "" : "s")")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            FlowLayout(spacing: 6) {
                ForEach(state.reader.attachments) { att in
                    AttachmentChip(attachment: att) {
                        saveAttachment(att, messageID: messageID)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func saveAttachment(_ attachment: Attachment, messageID: Int64) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = attachment.filename ?? "attachment"
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            Task { await state.downloadAttachment(attachment, messageID: messageID, to: url) }
        }
    }

    private func fromRow(_ msg: Message) -> some View {
        let parts = msg.fromParts
        return HStack(alignment: .top, spacing: 10) {
            AccountAvatar(email: parts.email)
                .scaleEffect(1.4)
                .frame(width: 30, height: 30)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(parts.name ?? parts.email)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if parts.name != nil {
                    Text(parts.email)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text("to " + (msg.to ?? []).joined(separator: ", "))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer()
            Text(DateFormat.readerHeader(msg.created_at))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    private var footer: some View {
        HStack {
            if let msg = state.reader.loaded {
                Button { state.startCompose(replyTo: msg) } label: {
                    Label("Reply", systemImage: "arrowshape.turn.up.left")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.04))
    }
}
