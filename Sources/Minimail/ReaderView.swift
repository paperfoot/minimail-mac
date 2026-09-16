import SwiftUI

struct ReaderView: View {
    let messageID: Int64
    @Environment(AppState.self) private var state
    /// Per-message opt-in for remote content (images / stylesheets / fonts
    /// that the privacy filter normally blocks). Reset whenever the user
    /// navigates to a different root message; within a thread, each message
    /// must be explicitly allowed.
    @State private var remoteContentAllowedIDs: Set<Int64> = []
    @State private var plainTextIDs: Set<Int64> = []
    @State private var detailIDs: Set<Int64> = []
    @State private var showsConversation = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.3)
            if let error = state.inbox.error { ErrorBanner(error: error) }
            content
            Divider().opacity(0.2)
            footer
        }
        // Root-message reset: the moment the user j/k's or taps another
        // inbox row, drop allowances so the next thread starts blocked.
        .onChange(of: messageID) { _, _ in
            remoteContentAllowedIDs.removeAll()
            plainTextIDs.removeAll()
            detailIDs.removeAll()
            showsConversation = false
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
            .accessibilityLabel("Back to inbox")

            Text(state.router.isExpanded ? "Message" : state.inbox.currentFolder.rawValue)
                .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            Spacer()
            if !state.router.isExpanded { CompactExpandButton() }
            if let msg = state.reader.loaded {
                Button {
                    Task {
                        if msg.isArchived { await state.unarchive(message: msg) }
                        else { await state.archive(message: msg) }
                    }
                } label: {
                    Image(systemName: msg.isArchived ? "tray.and.arrow.down" : "archivebox")
                }
                .buttonStyle(IconButtonStyle())
                .help(msg.isArchived ? "Move to Inbox (⌘⌫)" : "Archive (⌘⌫)")
                .accessibilityLabel(msg.isArchived ? "Move to Inbox" : "Archive message")
                .keyboardShortcut(.delete, modifiers: .command)

                Button {
                    Task { await state.toggleStar(msg) }
                } label: {
                    Image(systemName: msg.isStarred ? "star.fill" : "star")
                        .foregroundStyle(msg.isStarred ? .yellow : .secondary)
                }
                .buttonStyle(IconButtonStyle())
                .help(msg.isStarred ? "Unstar" : "Star (⇧⌘L)")
                .accessibilityLabel(msg.isStarred ? "Unstar message" : "Star message")
                // The window has a sibling search field; bare letters must
                // remain available for text input throughout the client.
                .keyboardShortcut("l", modifiers: [.command, .shift])

                Menu {
                    Button("Reply") { Task { await state.composeReply(to: msg) } }.keyboardShortcut("r", modifiers: .command)
                    Button("Reply All") { Task { await state.composeReply(to: msg, replyAll: true) } }.keyboardShortcut("r", modifiers: [.command, .shift])
                    Button("Forward") { Task { await state.composeReply(to: msg, forward: true) } }.keyboardShortcut("f", modifiers: [.command, .shift])
                    Divider()
                    Menu("Snooze") {
                        Button("Later Today (4h)") { Task { await state.snooze(msg, until: "4h") } }
                        Button("Tonight") { Task { await state.snooze(msg, until: "tonight") } }
                        Button("Tomorrow") { Task { await state.snooze(msg, until: "tomorrow") } }
                        Button("Next Week") { Task { await state.snooze(msg, until: "next-week") } }
                    }
                    if msg.isSnoozed { Button("Unsnooze") { Task { await state.unsnooze(msg) } } }
                    if msg.html_body?.isEmpty == false, msg.text_body?.isEmpty == false {
                        Button(plainTextIDs.contains(msg.id) ? "Show Original Formatting" : "Show Plain Text") {
                            if !plainTextIDs.insert(msg.id).inserted { plainTextIDs.remove(msg.id) }
                        }
                    }
                    Divider()
                    if msg.direction == "received" {
                        Button(msg.isUnread ? "Mark as Read" : "Mark as Unread") {
                            Task {
                                if msg.isUnread { await state.markRead(message: msg) }
                                else { await state.markUnread(message: msg) }
                            }
                        }
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
                .accessibilityLabel("More actions")
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
        if let msg = state.reader.loaded, state.reader.error == nil {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(msg.displaySubject)
                        .font(.system(size: state.router.isExpanded ? 22 : 17, weight: .semibold))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(16)
                    if state.reader.isLoading { ProgressView().controlSize(.small).padding(.horizontal, 16) }
                    if state.reader.thread.count > 1 {
                        threadStack(focusedID: msg.id)
                    } else {
                        singleMessage(msg)
                    }
                }
            }.id(messageID)
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
                Button("Try Again") { state.openMessage(id: messageID) }
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
            Text("Mailing list")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Button("Unsubscribe…") {
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
        if msg.hasUnsubscribeLink {
            unsubscribeRibbon(msg)
            Divider().opacity(0.2)
        }
        if let warning = lookalikeWarning(for: msg) {
            lookalikeRibbon(message: warning)
            Divider().opacity(0.2)
        }
        fromRow(msg)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        Divider().opacity(0.3)
        attachmentSection(for: msg)
        body(for: msg)
    }

    /// Conservative phishing heuristic: when the sender's display name
    /// claims a major brand but the email domain doesn't reflect it,
    /// surface a warning. False-positive cost is high (an unrecognised
    /// real "Apple Support" would flag a real apple.com email if we got
    /// the list wrong), so we only check a small allowlist of brands
    /// and require the brand string to appear in `name` but NOT in the
    /// domain part. Empty display name → never warn (no plausible
    /// impersonation vector without a name to spoof).
    private static let lookalikeBrands: [String] = [
        "apple", "google", "microsoft", "amazon", "paypal", "stripe",
        "facebook", "instagram", "linkedin", "github", "twitter",
        "x.com", "anthropic", "openai", "resend", "venmo", "coinbase",
        "binance", "bank of america", "chase", "wells fargo",
    ]
    private func lookalikeWarning(for msg: Message) -> String? {
        let parts = msg.fromParts
        guard let raw = parts.name?.lowercased(), !raw.isEmpty else { return nil }
        guard let host = parts.email.split(separator: "@").last.map(String.init)?.lowercased(),
              !host.isEmpty else { return nil }
        for brand in Self.lookalikeBrands {
            if raw.contains(brand) && !host.contains(brand) {
                return "This message claims to be from \(parts.name ?? brand) but was sent from \(host). Verify before clicking links."
            }
        }
        return nil
    }

    private func lookalikeRibbon(message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.primary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.10))
    }

    @ViewBuilder
    private func threadStack(focusedID: Int64) -> some View {
        Button { showsConversation.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: "text.bubble")
                Text(showsConversation ? "Hide conversation" : "Show conversation (\(state.reader.thread.count) messages)")
                Spacer()
                Image(systemName: showsConversation ? "chevron.up" : "chevron.down")
            }.font(.system(size: 11)).foregroundStyle(.secondary).contentShape(Rectangle())
        }.buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.03))
        Divider().opacity(0.2)

        ForEach(state.reader.thread.filter { showsConversation || $0.id == focusedID }) { m in
            let expanded = state.reader.expandedThreadIDs.contains(m.id) || m.id == focusedID
            if expanded {
                if m.hasUnsubscribeLink {
                    unsubscribeRibbon(m)
                    Divider().opacity(0.2)
                }
                if let warning = lookalikeWarning(for: m) {
                    lookalikeRibbon(message: warning)
                    Divider().opacity(0.2)
                }
                fromRow(m)

                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                Divider().opacity(0.25)
                attachmentSection(for: m)
                body(for: m)
                Divider().opacity(0.2)
            } else {
                Button { Task { await state.expandThreadMessage(m.id) } } label: {
                    CollapsedThreadRow(message: m).contentShape(Rectangle())
                }.buttonStyle(.plain)
                Divider().opacity(0.15)
            }
        }
    }

    @ViewBuilder
    private func body(for msg: Message) -> some View {
        if let html = msg.html_body, !html.isEmpty, !plainTextIDs.contains(msg.id) {
            // HTMLBodyView self-sizes to its content height now — don't add
            // a fixed `.frame(minHeight:)` here or it caps short messages
            // and reintroduces the inner-scrollbar problem we just fixed.
            let remoteContentAllowed = remoteContentAllowedIDs.contains(msg.id)
            if state.reader.remoteContentCount(for: msg.id) > 0 {
                remoteContentControl(for: msg, isAllowed: remoteContentAllowed)
            }
            if let error = state.reader.inlineImageErrors[msg.id] {
                HStack(alignment: .top) {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Retry") {
                        Task {
                            await state.reloadAttachments(messageID: msg.id)
                            await state.loadInlineImages(for: msg)
                        }
                    }
                }.padding(12)
            }
            HTMLBodyView(
                html: EmailHTML.resolvingInlineImages(in: html, images: state.reader.inlineImages[msg.id] ?? [:]),
                remoteContentAllowed: remoteContentAllowed
            )
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

    private func remoteContentControl(for msg: Message, isAllowed: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: isAllowed ? "shield.slash" : "shield.lefthalf.filled")
                .font(.system(size: 10))
            if isAllowed {
                Text("Remote content loaded")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                Button("Load remote content") {
                    remoteContentAllowedIDs.insert(msg.id)
                    state.focusThreadMessage(msg.id)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .accessibilityLabel("Load remote content for this message")
            }
            Spacer()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.03))
    }

    @ViewBuilder
    private func attachmentSection(for message: Message) -> some View {
        let attachments = state.reader.attachments(for: message.id)
        if !attachments.isEmpty { AttachmentShelf(messageID: message.id, attachments: attachments) }
        if let error = state.reader.attachmentErrors[message.id] {
            HStack(alignment: .top) {
                Label("Attachments: " + error, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Retry") { Task { await state.reloadAttachments(messageID: message.id) } }
            }.padding(.horizontal, 16).padding(.vertical, 8)
        }
    }

    private func fromRow(_ msg: Message) -> some View {
        let parts = msg.fromParts
        let expanded = detailIDs.contains(msg.id)
        let to = msg.to ?? []
        let cc = msg.cc ?? []
        let redirect = (msg.reply_to ?? []).filter { $0.emailAddressPart.lowercased() != parts.email.lowercased() }
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                state.focusThreadMessage(msg.id)
                if !detailIDs.insert(msg.id).inserted { detailIDs.remove(msg.id) }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(parts.name ?? parts.email).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(DateFormat.inboxList(msg.created_at)).font(.system(size: 11)).foregroundStyle(.secondary)
                        Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                    Text("To: " + to.map(\.emailAddressPart).joined(separator: ", ") + (cc.isEmpty ? "" : " · \(cc.count) Cc"))
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).help(expanded ? "Hide message details" : "Show sender and recipient details")
            if !redirect.isEmpty {
                Text("Replies to " + redirect.joined(separator: ", "))
                    .font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if expanded {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                    detailRow("From", value: msg.from_addr)
                    detailRow("To", value: to.joined(separator: ", "))
                    if !cc.isEmpty { detailRow("Cc", value: cc.joined(separator: ", ")) }
                    if msg.direction == "sent", let bcc = msg.bcc, !bcc.isEmpty { detailRow("Bcc", value: bcc.joined(separator: ", ")) }
                    detailRow("Date", value: DateFormat.readerHeader(msg.created_at))
                    if state.session.accounts.count > 1 { detailRow("Account", value: msg.account_email) }
                }.font(.system(size: 11)).padding(.top, 4).textSelection(.enabled)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detailRow(_ label: String, value: String) -> some View {
        GridRow(alignment: .top) {
            Text(label).foregroundStyle(.secondary)
            Text(value).fixedSize(horizontal: false, vertical: true)
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
        let positionLabel = state.reader.positionLabel
        return HStack(spacing: 8) {
            if let msg = state.reader.loaded {
                // When the original has CC'd recipients, Reply All is almost
                // always the intended action — a plain Reply silently drops
                // everyone else off the thread. Make Reply All the prominent
                // default in that case and keep Reply available alongside.
                let hasCc = !(msg.cc ?? []).isEmpty
                let multipleTo = (msg.to ?? []).count > 1
                let showReplyAll = hasCc || multipleTo

                if showReplyAll {
                    Button { Task { await state.composeReply(to: msg, replyAll: true) } } label: {
                        Label("Reply All", systemImage: "arrowshape.turn.up.left.2")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help("Reply to sender and all other recipients (⌘⇧R)")

                    Button { Task { await state.composeReply(to: msg) } } label: {
                        Label("Reply", systemImage: "arrowshape.turn.up.left")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Reply to sender only (⌘R)")
                } else {
                    Button { Task { await state.composeReply(to: msg) } } label: {
                        Label("Reply", systemImage: "arrowshape.turn.up.left")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help("Reply (⌘R)")
                }
            }
            Spacer()
            if let label = positionLabel {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            Button { state.openPrevious() } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless).help("Previous message").accessibilityLabel("Previous message")
            Button { state.openNext() } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless).help("Next message").accessibilityLabel("Next message")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}
