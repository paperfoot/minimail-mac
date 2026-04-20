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
            .help("Back to inbox (esc)")

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

                Button {
                    Task { await state.toggleStar(msg) }
                } label: {
                    Image(systemName: msg.isStarred ? "star.fill" : "star")
                        .foregroundStyle(msg.isStarred ? .yellow : .secondary)
                }
                .buttonStyle(IconButtonStyle())
                .help(msg.isStarred ? "Unstar" : "Star (S)")
                .keyboardShortcut("s", modifiers: [])

                Menu {
                    Button("Later today (4h)") { Task { await state.snooze(msg, until: "4h") } }
                    Button("Tonight") { Task { await state.snooze(msg, until: "tonight") } }
                    Button("Tomorrow") { Task { await state.snooze(msg, until: "tomorrow") } }
                    Button("Next week") { Task { await state.snooze(msg, until: "next-week") } }
                    if msg.isSnoozed {
                        Divider()
                        Button("Unsnooze") { Task { await state.unsnooze(msg) } }
                    }
                    Divider()
                    Button("Mark as Unread") {
                        Task { await state.markUnread(message: msg) }
                    }
                    if msg.hasUnsubscribeLink {
                        Divider()
                        Button("Unsubscribe…") {
                            Task { await state.unsubscribeFrom(msg) }
                        }
                    }
                    Divider()
                    Button("Delete…", role: .destructive) {
                        state.reader.pendingDeleteConfirm = msg.id
                    }
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
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .confirmationDialog(
            "Delete this message?",
            isPresented: Binding(
                get: { state.reader.pendingDeleteConfirm != nil },
                set: { if !$0 { state.reader.pendingDeleteConfirm = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let id = state.reader.pendingDeleteConfirm,
                   let msg = state.reader.loaded, msg.id == id {
                    Task { await state.delete(message: msg) }
                }
                state.reader.pendingDeleteConfirm = nil
            }
            Button("Cancel", role: .cancel) {
                state.reader.pendingDeleteConfirm = nil
            }
        } message: {
            Text("You can't undo this. Archive keeps it out of the inbox instead.")
        }
        .onKeyPress("j") {
            state.openNext()
            return .handled
        }
        .onKeyPress("k") {
            state.openPrevious()
            return .handled
        }
        .onKeyPress(.downArrow) {
            state.openNext()
            return .handled
        }
        .onKeyPress(.upArrow) {
            state.openPrevious()
            return .handled
        }
        .focusable()
        .focusEffectDisabled()
    }

    @ViewBuilder
    private var content: some View {
        if let msg = state.reader.loaded {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if msg.hasUnsubscribeLink {
                        unsubscribeRibbon(msg)
                        Divider().opacity(0.2)
                    }
                    if state.reader.thread.count > 1 {
                        threadStack(focusedID: msg.id)
                    } else {
                        singleMessage(msg)
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

    private func unsubscribeRibbon(_ msg: Message) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "envelope.arrow.triangle.branch")
                .font(.system(size: 11))
                .foregroundStyle(Color.accentColor)
            Text("Mailing-list mail — one click to unsubscribe")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Button("Unsubscribe") {
                Task { await state.unsubscribeFrom(msg) }
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.06))
    }

    @ViewBuilder
    private func singleMessage(_ msg: Message) -> some View {
        fromRow(msg)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        Divider().opacity(0.3)
        body(for: msg)
        if !state.reader.attachments.isEmpty {
            attachmentsBar(messageID: msg.id)
        }
    }

    @ViewBuilder
    private func threadStack(focusedID: Int64) -> some View {
        // Banner — simple count readout to orient the user.
        HStack(spacing: 6) {
            Image(systemName: "text.bubble")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Text("\(state.reader.thread.count) messages in this thread")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.03))
        Divider().opacity(0.2)

        ForEach(state.reader.thread) { m in
            let expanded = state.reader.expandedThreadIDs.contains(m.id) || m.id == focusedID
            if expanded {
                fromRow(m)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                Divider().opacity(0.25)
                body(for: m)
                if m.id == focusedID && !state.reader.attachments.isEmpty {
                    attachmentsBar(messageID: m.id)
                }
                Divider().opacity(0.2)
            } else {
                CollapsedThreadRow(message: m)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        Task { await state.expandThreadMessage(m.id) }
                    }
                Divider().opacity(0.15)
            }
        }
    }

    @ViewBuilder
    private func body(for msg: Message) -> some View {
        if let html = msg.html_body, !html.isEmpty {
            HTMLBodyView(html: html)
                .frame(minHeight: 280)
        } else if let text = msg.text_body, !text.isEmpty {
            Text(text)
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .textSelection(.enabled)
        } else if state.reader.isLoading && msg.id == state.reader.loaded?.id {
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

    private struct CollapsedThreadRow: View {
        let message: Message

        var body: some View {
            HStack(alignment: .top, spacing: 10) {
                AccountAvatar(email: message.fromParts.email)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(message.fromParts.name ?? message.fromParts.email)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        Spacer()
                        Text(DateFormat.inboxList(message.created_at))
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    if let snippet = message.snippet, !snippet.isEmpty {
                        Text(snippet)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let msg = state.reader.loaded {
                Button { state.startCompose(replyTo: msg) } label: {
                    Label("Reply", systemImage: "arrowshape.turn.up.left")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            if let msg = state.reader.loaded,
               let html = msg.html_body,
               let count = Self.trackingPixelCount(in: html),
               count > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "shield.lefthalf.filled")
                        .font(.system(size: 9))
                    Text("Blocked \(count) tracker\(count == 1 ? "" : "s")")
                        .font(.system(size: 10))
                }
                .foregroundStyle(.tertiary)
                .help("Remote images blocked to prevent read tracking")
            }
            Spacer()
            // Message position indicator — "3 of 24" style
            if let msg = state.reader.loaded {
                let list = state.inbox.visible()
                if let idx = list.firstIndex(where: { $0.id == msg.id }) {
                    Text("\(idx + 1) of \(list.count)")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// Count of `<img src="http...">` elements — a proxy for tracking-pixel
    /// density since those are exactly the images our WKContentRuleList
    /// blocks. Bounded at a simple regex match; good enough for a badge.
    private static func trackingPixelCount(in html: String) -> Int? {
        let pattern = "<img[^>]+src=\"https?://"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        return regex.numberOfMatches(in: html, range: NSRange(html.startIndex..., in: html))
    }
}
