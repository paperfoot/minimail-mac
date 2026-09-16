import SwiftUI

struct InboxView: View {
    @Environment(AppState.self) private var state
    var expanded = false
    @FocusState private var searchFocused: Bool
    @State private var pendingDeleteIDs: [Int64] = []
    @State private var pendingDeleteDraft: Draft?

    var body: some View {
        let inbox = state.inbox
        let session = state.session

        @Bindable var boundInbox = inbox

        VStack(spacing: 0) {
            if !expanded {
                header(session: session)
                Divider().opacity(0.25)
                folderRow(inbox: inbox)
                Divider().opacity(0.15)
            }
            searchRow(bound: $boundInbox.searchQuery)
            Divider().opacity(0.15)
            if let err = inbox.error {
                ErrorBanner(error: err)
            } else if let err = inbox.searchError {
                // Surface FTS/search failures through the same channel as
                // the generic inbox error — the user sees a classified,
                // redacted message rather than raw CLI stderr.
                ErrorBanner(error: err)
            }
            messageList
            footer
        }
        .confirmationDialog("Permanently delete these messages?", isPresented: Binding(
            get: { !pendingDeleteIDs.isEmpty },
            set: { if !$0 { pendingDeleteIDs = [] } }
        )) {
            Button("Delete \(pendingDeleteIDs.count) Message\(pendingDeleteIDs.count == 1 ? "" : "s")", role: .destructive) {
                let ids = pendingDeleteIDs
                pendingDeleteIDs = []
                Task { await state.deleteMessages(ids: ids) }
            }
            Button("Cancel", role: .cancel) { pendingDeleteIDs = [] }
        } message: { Text("This removes the local messages and cannot be undone.") }
        .confirmationDialog("Discard this draft?", isPresented: Binding(
            get: { pendingDeleteDraft != nil },
            set: { if !$0 { pendingDeleteDraft = nil } }
        )) {
            Button("Discard Draft", role: .destructive) {
                if let draft = pendingDeleteDraft { Task { await state.deleteDraft(draft) } }
                pendingDeleteDraft = nil
            }
            Button("Cancel", role: .cancel) { pendingDeleteDraft = nil }
        }
        .onReceive(NotificationCenter.default.publisher(for: .minimailFocusSearch)) { _ in searchFocused = true }
        .background(Button("") { searchFocused = true }.keyboardShortcut("f", modifiers: .command).hidden())
        .onAppear {
            // Land the keyboard selection on the first unread message when
            // the inbox first appears — saves the user pressing j to get to
            // what they actually want to read.
            if state.inbox.focusedRowIndex < 0 {
                let visible = state.inbox.visible()
                if let idx = visible.firstIndex(where: { $0.isUnread }) {
                    state.inbox.focusedRowIndex = idx
                }
            }
        }
    }

    private func header(session: SessionState) -> some View {
        HStack(spacing: 8) {
            Button {
                state.openAccountSwitcher()
            } label: {
                HStack(spacing: 8) {
                    if session.currentAccount == nil && !session.accounts.isEmpty {
                        // Unified inbox indicator — same gradient + symbol as
                        // the AccountSwitcher row so the user immediately
                        // recognises the mode.
                        ZStack {
                            Circle()
                                .fill(LinearGradient(
                                    colors: [.indigo, .purple],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ))
                                .frame(width: 20, height: 20)
                            Image(systemName: "tray.2.fill")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        Text("All accounts")
                            .font(.system(size: 13, weight: .medium))
                    } else {
                        AccountAvatar(email: session.currentAccount?.email ?? "?")
                        Text(session.currentAccount?.email ?? "No account")
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .glassEffect(.regular, in: .capsule)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Switch account (⌘0 = all, ⌘1…⌘9 = individual)")

            Spacer()

            Button { Task { await state.saveComposeAndStartNew() } } label: {
                Image(systemName: "square.and.pencil")
            }
            .buttonStyle(IconButtonStyle())
            .help("New message (⌘N)")
            .accessibilityLabel("New message")
            .keyboardShortcut("n", modifiers: .command)

            Button {
                Task { await state.refreshInbox() }
            } label: {
                if state.inbox.syncState == .syncing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(IconButtonStyle())
            .help("Check for new mail (⇧⌘N)")
            .accessibilityLabel(state.inbox.syncState == .syncing ? "Syncing" : "Refresh inbox")
            .keyboardShortcut("n", modifiers: [.command, .shift])
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func folderRow(inbox: InboxState) -> some View {
        HStack {
            Menu {
                ForEach(InboxState.Folder.allCases, id: \.self) { folder in
                    Button {
                        Task { await state.selectFolder(folder) }
                    } label: {
                        Label(folder.rawValue + (badge(for: folder, inbox: inbox).map { " (\($0))" } ?? ""), systemImage: folder.symbol)
                    }
                }
            } label: {
                Label(inbox.currentFolder.rawValue, systemImage: inbox.currentFolder.symbol)
                    .font(.system(size: 12, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Mailboxes: \(inbox.currentFolder.rawValue)")
            Spacer()
            if let count = badge(for: inbox.currentFolder, inbox: inbox) {
                Text("\(count)").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func badge(for folder: InboxState.Folder, inbox: InboxState) -> Int? {
        switch folder {
        case .inbox:
            let n = inbox.messages.filter {
                $0.direction == "received" && !$0.isArchived && !$0.isSnoozed && $0.isUnread
            }.count
            return n > 0 ? n : nil
        case .unread:
            // Authoritative CLI-sourced count — matches the footer badge
            // and survives across the 100-row window (messages we don't
            // have loaded still contribute). Mirror of inbox.totalUnread.
            return inbox.totalUnread > 0 ? inbox.totalUnread : nil
        case .starred:
            let n = AppState.mergeMessages(inbox.messages + inbox.snoozedMessages).filter { $0.isStarred }.count
            return n > 0 ? n : nil
        case .snoozed:
            let n = inbox.snoozedMessages.count
            return n > 0 ? n : nil
        case .drafts:
            let n = inbox.drafts.count
            return n > 0 ? n : nil
        default:
            return nil
        }
    }

    private func searchRow(bound: Binding<String>) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
            TextField("Search all mail", text: bound)
                .focused($searchFocused)
                .accessibilityLabel("Search all mail")
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                // Free-text search only for the widget (per product-split.md
                // — operator parsing like from:/is:unread ships with the
                // full app). Each keystroke reschedules the 300ms debounce.
                .onChange(of: bound.wrappedValue) { _, _ in
                    state.scheduleSearch()
                }
            if !bound.wrappedValue.isEmpty {
                Button { bound.wrappedValue = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).accessibilityLabel("Clear search")
            }
            if state.inbox.isSearching {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // Error banner lives in its own view so each case owns its icon,
    // colour, copy and CTA without one giant switch in a modifier chain.
    // Intentionally flat: no animations, glass, or shadows — this is
    // content, not chrome.


    @ViewBuilder
    private var messageList: some View {
        if state.inbox.selection.count > (expanded ? 1 : 0) {
            selectionBar
            Divider().opacity(0.2)
        }
        if state.inbox.currentFolder == .drafts {
            draftsList
        } else if expanded {
            nativeMessageList
        } else {
            regularList
        }
    }

    private var nativeMessageList: some View {
        let visible = state.inbox.visible()
        return List(selection: Binding(
            get: { state.inbox.selection },
            set: { ids in
                Task {
                    guard await state.prepareToLeaveCompose() else { return }
                    state.inbox.selection = ids
                    if ids.count == 1, let id = ids.first, let message = visible.first(where: { $0.id == id }) {
                        state.open(message: message)
                    } else { state.back() }
                }
            }
        )) {
            ForEach(visible) { message in
                WindowMessageRow(message: message)
                    .tag(message.id)
                    .contextMenu { messageContextMenu(for: message) }
            }
            if state.inbox.canLoadMore && state.inbox.searchQuery.isEmpty {
                Button(state.inbox.isLoadingMore ? "Loading…" : "Load Older Messages") {
                    Task { await state.loadMoreMessages() }
                }.disabled(state.inbox.isLoadingMore)
            }
        }
        .listStyle(.inset)
        .overlay {
            if visible.isEmpty && (!state.inbox.searchQuery.isEmpty || !state.inbox.canLoadMore) {
                if state.inbox.isSearching || state.inbox.syncState == .syncing { ProgressView() }
                else { emptyState }
            }
        }
    }

    private var selectionBar: some View {
        HStack(spacing: 10) {
            Text("\(state.inbox.selection.count) selected")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary)
            Spacer()
            Button {
                Task { await state.bulkArchive() }
            } label: {
                Image(systemName: state.inbox.currentFolder == .archived ? "tray.and.arrow.down" : "archivebox")
                    .help(state.inbox.currentFolder == .archived ? "Move selected messages to Inbox" : "Archive selected messages")
                    .accessibilityLabel(state.inbox.currentFolder == .archived ? "Move selected messages to Inbox" : "Archive selected messages")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            Button {
                Task { await state.bulkMarkRead() }
            } label: {
                Image(systemName: "envelope.open").help("Mark selected messages as read").accessibilityLabel("Mark selected messages as read")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            Menu {
                Button("Mark as Read") { Task { await state.bulkMarkRead() } }
                Button("Mark as Unread") { Task { await state.bulkMarkUnread() } }
            } label: { Image(systemName: "envelope.badge") }
            .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Read status for selected messages")
            Button(role: .destructive) {
                pendingDeleteIDs = Array(state.inbox.selection)
            } label: {
                Image(systemName: "trash").help("Delete selected messages").accessibilityLabel("Delete selected messages")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
            Button {
                state.inbox.clearSelection()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Clear selection")
            .accessibilityLabel("Clear selection")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .glassEffect(.regular.tint(Color.accentColor.opacity(0.15)),
                     in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var draftsList: some View {
        let visible = state.inbox.visibleDrafts()
        return ScrollView {
            LazyVStack(spacing: 0) {
                if visible.isEmpty {
                    if state.inbox.syncState == .syncing {
                        ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40)
                    } else {
                        emptyState
                    }
                } else {
                    ForEach(visible) { draft in
                        Button { Task { await state.openDraft(draft) } } label: {
                            DraftRow(draft: draft).contentShape(Rectangle())
                        }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Open Draft") { Task { await state.openDraft(draft) } }
                                Button("Discard Draft…", role: .destructive) { pendingDeleteDraft = draft }
                            }
                        Divider().opacity(0.15)
                    }
                }
            }
        }
    }

    private var regularList: some View {
        let visible = state.inbox.visible()
        let groups = DayGrouping.group(visible)
        // Pre-flatten the group/row index into a dict so per-row lookup is
        // O(1) instead of `DayGrouping.globalIndex`'s O(N²) nested scan
        // (called once per row per render = ~N² comparisons per inbox
        // re-render at N=100). Rebuilt once per render of regularList.
        let indexMap: [Int64: Int] = {
            var map: [Int64: Int] = [:]
            var idx = 0
            for group in groups {
                for msg in group.messages {
                    map[msg.id] = idx
                    idx += 1
                }
            }
            return map
        }()
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    if visible.isEmpty, state.inbox.syncState != .syncing, !state.inbox.isSearching {
                        emptyState
                    } else {
                        ForEach(groups, id: \.label) { group in
                            Section {
                                ForEach(group.messages) { msg in
                                    let globalIdx = indexMap[msg.id] ?? 0
                                    MessageRow(
                                        message: msg,
                                        isSelected: state.reader.loaded?.id == msg.id,
                                        isFocused: globalIdx == state.inbox.focusedRowIndex,
                                        isChecked: state.inbox.selection.contains(msg.id)
                                    )
                                    .id(msg.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        if !state.inbox.selection.isEmpty {
                                            state.inbox.toggle(msg.id)
                                        } else {
                                            state.inbox.focusedRowIndex = globalIdx
                                            state.open(message: msg)
                                        }
                                    }
                                    .contextMenu {
                                        messageContextMenu(for: msg)
                                    }
                                    Divider().opacity(0.15)
                                }
                            } header: {
                                DayHeader(label: group.label)
                            }
                        }
                    }
                    if state.inbox.canLoadMore && state.inbox.searchQuery.isEmpty {
                        Button(state.inbox.isLoadingMore ? "Loading…" : "Load Older Messages") {
                            Task { await state.loadMoreMessages() }
                        }.disabled(state.inbox.isLoadingMore).padding(12)
                    }
                }
            }
            .onKeyPress(.upArrow) { moveFocus(-1, visible: visible, proxy: proxy); return .handled }
            .onKeyPress(.downArrow) { moveFocus(1, visible: visible, proxy: proxy); return .handled }
            .onKeyPress("j") { moveFocus(1, visible: visible, proxy: proxy); return .handled }
            .onKeyPress("k") { moveFocus(-1, visible: visible, proxy: proxy); return .handled }
            .onKeyPress(.return) {
                let idx = state.inbox.focusedRowIndex
                if idx >= 0, idx < visible.count {
                    state.open(message: visible[idx])
                }
                return .handled
            }
            // Scroll view needs focus to receive onKeyPress events, but the
            // default macOS focus ring looks like a selection rectangle
            // around the whole list — hide it, keyboard nav still works.
            .focusable()
            .focusEffectDisabled()
        }
    }

    @ViewBuilder
    private func messageContextMenu(for msg: Message) -> some View {
        Button("Open") { Task { if await state.prepareToLeaveCompose() { state.open(message: msg) } } }
        Divider()
        Button("Reply") {
            Task { await state.composeReply(to: msg) }
        }
        Button("Reply All") {
            Task { await state.composeReply(to: msg, replyAll: true) }
        }
        Button("Forward") {
            Task { await state.composeReply(to: msg, forward: true) }
        }
        Divider()
        Button(msg.isStarred ? "Unstar" : "Star") {
            Task { await state.toggleStar(msg) }
        }
        Menu("Snooze") {
            Button("Later today (4h)") { Task { await state.snooze(msg, until: "4h") } }
            Button("Tonight") { Task { await state.snooze(msg, until: "tonight") } }
            Button("Tomorrow") { Task { await state.snooze(msg, until: "tomorrow") } }
            Button("Next week") { Task { await state.snooze(msg, until: "next-week") } }
        }
        if msg.isSnoozed {
            Button("Unsnooze") { Task { await state.unsnooze(msg) } }
        }
        if msg.hasUnsubscribeLink {
            Button("Unsubscribe…") { Task { await state.unsubscribeFrom(msg) } }
        }
        Divider()
        if msg.isUnread {
            Button("Mark as Read") { Task { await state.markRead(message: msg) } }
        } else if msg.direction == "received" {
            Button("Mark as Unread") { Task { await state.markUnread(message: msg) } }
        }
        if msg.isArchived {
            Button("Move to Inbox") { Task { await state.unarchive(message: msg) } }
        } else {
            Button("Archive") { Task { await state.archive(message: msg) } }
        }
        Divider()
        Button(state.inbox.selection.contains(msg.id) ? "Deselect" : "Add to Selection") {
            state.inbox.toggle(msg.id)
        }
        Divider()
        Button("Delete", role: .destructive) {
            pendingDeleteIDs = [msg.id]
        }
    }

    private func moveFocus(_ delta: Int, visible: [Message], proxy: ScrollViewProxy) {
        guard !visible.isEmpty else { return }
        let next: Int
        if state.inbox.focusedRowIndex < 0 {
            next = delta > 0 ? 0 : visible.count - 1
        } else {
            next = max(0, min(visible.count - 1, state.inbox.focusedRowIndex + delta))
        }
        state.inbox.focusedRowIndex = next
        withAnimation(.easeOut(duration: 0.12)) {
            proxy.scrollTo(visible[next].id, anchor: .center)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: emptyIcon)
                .font(.system(size: 32))
                .opacity(0.3)
            Text(emptyText)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var emptyIcon: String {
        switch state.inbox.currentFolder {
        case .inbox: return "tray"
        case .unread: return "envelope.badge"
        case .starred: return "star"
        case .snoozed: return "alarm"
        case .sent: return "paperplane"
        case .drafts: return "doc"
        case .archived: return "archivebox"
        }
    }

    private var emptyText: String {
        if !state.inbox.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
            return "No matches"
        }
        switch state.inbox.currentFolder {
        case .inbox: return "Inbox is empty"
        case .unread: return "All caught up"
        case .starred: return "No starred messages"
        case .snoozed: return "Nothing snoozed"
        case .sent: return "Nothing sent yet"
        case .drafts: return "No drafts"
        case .archived: return "No archived messages"
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if state.inbox.totalUnread > 0 {
                Text("\(state.inbox.totalUnread) unread")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                Text("All caught up")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { Task { await state.markAllRead() } } label: {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 13))
            }
            .buttonStyle(IconButtonStyle())
            .help("Mark all messages as read")
            .accessibilityLabel("Mark all messages as read")
            .disabled(state.inbox.totalUnread == 0)

            if !expanded {
            Button { Task { await state.navigate(to: .settings) } } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
            }
            .buttonStyle(IconButtonStyle())
            .help("Settings")
            .accessibilityLabel("Settings")
            .keyboardShortcut(",", modifiers: .command)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.04))
    }
}

struct FolderTab: View {
    let title: String
    let count: Int?
    let selected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 12, weight: selected ? .semibold : .medium))
                if let count {
                    Text(String(count))
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(selected ? Color.accentColor : Color.primary.opacity(0.12),
                                    in: Capsule())
                        .foregroundStyle(selected ? Color.white : .secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(selected ? Color.accentColor.opacity(0.18) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7))
            .foregroundStyle(selected ? Color.accentColor : .secondary)
        }
        .buttonStyle(.plain)
    }
}

struct MessageRow: View {
    @Environment(AppState.self) private var state
    let message: Message
    var isSelected: Bool = false
    var isFocused: Bool = false
    var isChecked: Bool = false
    @State private var hovered = false

    /// Unified inbox: each row shows a small mini-avatar of the destination
    /// account so the user can tell at a glance which mailbox the message
    /// belongs to. Hidden when focused on a single account (redundant).
    private var showAccountIndicator: Bool {
        state.session.currentAccount == nil
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Leading gutter — unread dot OR checkbox on hover/select.
            leadingGutter
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if showAccountIndicator {
                        AccountAvatar(email: message.account_email)
                            .frame(width: 14, height: 14)
                            .help("To: \(message.account_email)")
                    }
                    if message.isStarred {
                        Image(systemName: "star.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.yellow)
                    }
                    Text(message.correspondent)
                        .font(.system(size: 13, weight: message.isUnread ? .semibold : .regular))
                        .lineLimit(1)
                    if message.has_attachments == true {
                        Image(systemName: "paperclip")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 4)
                    Text(DateFormat.inboxList(message.created_at))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                Text(message.displaySubject)
                    .font(.system(size: 12, weight: message.isUnread ? .medium : .regular))
                    .foregroundStyle(message.isUnread ? .primary : .secondary)
                    .lineLimit(1)
                if let snippet = message.snippet, !snippet.isEmpty {
                    Text(snippet)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            // Always reserved so showing / hiding doesn't reflow the row.
            // Gmail / Apple Mail use the same trick.
            hoverActions
                .opacity(hovered ? 1 : 0)
                .allowsHitTesting(hovered)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(rowBackground)
        .onHover { hovered = $0 }
    }

    @ViewBuilder
    private var leadingGutter: some View {
        if isChecked {
            Button { state.inbox.toggle(message.id) } label: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
                    .font(.system(size: 14))
            }
            .buttonStyle(.plain)
            .frame(width: 14, height: 14)
            .accessibilityLabel("Deselect message")
        } else if hovered || !state.inbox.selection.isEmpty {
            Button { state.inbox.toggle(message.id) } label: {
                Image(systemName: "circle")
                    .foregroundStyle(.tertiary)
                    .font(.system(size: 14))
            }
            .buttonStyle(.plain)
            .frame(width: 14, height: 14)
            .accessibilityLabel("Select message")
        } else if message.isUnread {
            Circle().fill(Color.accentColor).frame(width: 8, height: 8)
                .frame(width: 14, height: 14)
        } else {
            Color.clear.frame(width: 14, height: 14)
        }
    }

    private var hoverActions: some View {
        HStack(spacing: 4) {
            Button {
                Task { await state.toggleStar(message) }
            } label: {
                Image(systemName: message.isStarred ? "star.fill" : "star")
                    .foregroundStyle(message.isStarred ? AnyShapeStyle(Color.yellow) : AnyShapeStyle(HierarchicalShapeStyle.tertiary))
            }
            .buttonStyle(.plain)
            .help(message.isStarred ? "Unstar" : "Star")
            .accessibilityLabel(message.isStarred ? "Unstar message" : "Star message")

            Button {
                Task {
                    if message.isArchived { await state.unarchive(message: message) }
                    else { await state.archive(ids: [message.id]) }
                }
            } label: {
                Image(systemName: message.isArchived ? "tray.and.arrow.down" : "archivebox")
                    .foregroundStyle(HierarchicalShapeStyle.tertiary)
            }
            .buttonStyle(.plain)
            .help(message.isArchived ? "Move to Inbox" : "Archive")
            .accessibilityLabel(message.isArchived ? "Move to Inbox" : "Archive message")
        }
        .font(.system(size: 12))
    }

    @ViewBuilder
    private var rowBackground: some View {
        if isChecked {
            Color.accentColor.opacity(0.1)
        } else if isFocused {
            Color.accentColor.opacity(0.18)
        } else if isSelected {
            Color.accentColor.opacity(0.14)
        } else if hovered {
            Color.primary.opacity(0.05)
        } else {
            Color.clear
        }
    }
}

/// Day-group header rendered as a sticky section header inside the inbox list.
struct DayHeader: View {
    let label: String
    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial)
    }
}

/// Groups chronological messages into human-friendly buckets (Today,
/// Yesterday, This week, Earlier). Used by the inbox list to produce sticky
/// section headers. `globalIndex` recomputes the flat position across all
/// groups so keyboard j/k still traverses every row linearly.
@MainActor
enum DayGrouping {
    struct Group { let label: String; let messages: [Message] }

    static func group(_ messages: [Message]) -> [Group] {
        let cal = Calendar.current
        let now = Date()
        let weekStart = cal.date(byAdding: .day, value: -7, to: now) ?? now
        var buckets: [(String, [Message])] = [
            ("Today", []), ("Yesterday", []), ("This Week", []), ("Earlier", []),
        ]
        for m in messages {
            guard let d = DateFormat.parse(m.created_at) else {
                buckets[3].1.append(m); continue
            }
            if cal.isDateInToday(d) { buckets[0].1.append(m) }
            else if cal.isDateInYesterday(d) { buckets[1].1.append(m) }
            else if d > weekStart { buckets[2].1.append(m) }
            else { buckets[3].1.append(m) }
        }
        return buckets.compactMap { b in b.1.isEmpty ? nil : Group(label: b.0, messages: b.1) }
    }

    static func globalIndex(of message: Message, in groups: [Group]) -> Int {
        var idx = 0
        for g in groups {
            for m in g.messages {
                if m.id == message.id { return idx }
                idx += 1
            }
        }
        return -1
    }
}

/// Thread-safe timestamp parser shared by every caller (Models.Message,
/// DateFormat, etc.). Uses three formats in priority order: ISO-8601 with
/// fractional seconds, plain ISO-8601, and SQLite `yyyy-MM-dd HH:mm:ss` (UTC).
/// Non-isolated so it's callable from Decodable init paths off the main actor.
enum Dates {
    // ISO8601DateFormatter is not Sendable (yet); DateFormatter is. For the
    // ISO variants we opt out of concurrency checking — they're functionally
    // immutable once configured and we only read from them.
    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let isoNoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let sqlite: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    static func parse(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        if let d = iso.date(from: raw) { return d }
        if let d = isoNoFrac.date(from: raw) { return d }
        if let d = sqlite.date(from: raw) { return d }
        return nil
    }
}

@MainActor
enum DateFormat {
    private static let timeOnly: DateFormatter = {
        let f = DateFormatter(); f.locale = .current; f.timeStyle = .short; return f
    }()
    private static let weekday: DateFormatter = {
        let f = DateFormatter(); f.locale = .current; f.dateFormat = "EEE"; return f
    }()
    private static let monthDay: DateFormatter = {
        let f = DateFormatter(); f.locale = .current; f.setLocalizedDateFormatFromTemplate("MMMd"); return f
    }()
    private static let shortDate: DateFormatter = {
        let f = DateFormatter(); f.locale = .current; f.dateStyle = .short; return f
    }()
    private static let fullDate: DateFormatter = {
        let f = DateFormatter(); f.locale = .current; f.dateStyle = .medium; f.timeStyle = .short; return f
    }()

    static func parse(_ raw: String?) -> Date? {
        Dates.parse(raw)
    }

    static func inboxList(_ raw: String?) -> String {
        guard let date = parse(raw) else { return "" }
        let cal = Calendar.current
        let now = Date()
        if cal.isDateInToday(date) { return timeOnly.string(from: date) }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let days = cal.dateComponents([.day], from: date, to: now).day ?? 0
        if days < 7 { return weekday.string(from: date) }
        if cal.component(.year, from: date) == cal.component(.year, from: now) {
            return monthDay.string(from: date)
        }
        return shortDate.string(from: date)
    }

    static func readerHeader(_ raw: String?) -> String {
        guard let date = parse(raw) else { return "" }
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today at " + timeOnly.string(from: date) }
        if cal.isDateInYesterday(date) { return "Yesterday at " + timeOnly.string(from: date) }
        let now = Date()
        if cal.component(.year, from: date) == cal.component(.year, from: now) {
            return monthDay.string(from: date) + " at " + timeOnly.string(from: date)
        }
        return fullDate.string(from: date)
    }
}

struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 28, height: 28)
            .foregroundStyle(configuration.isPressed ? .primary : .secondary)
            .background(
                Circle()
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.1 : 0))
            )
            .contentShape(Circle())
    }
}

struct AccountAvatar: View {
    let email: String

    var body: some View {
        Circle()
            .fill(LinearGradient(
                colors: [color(for: email).opacity(0.85), color(for: email)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ))
            .frame(width: 20, height: 20)
            .overlay(
                Text(initials(email))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
            )
    }

    private func initials(_ s: String) -> String {
        let name = s.split(separator: "@").first.map(String.init) ?? s
        let parts = name.split(whereSeparator: { !$0.isLetter })
        let first = parts.first?.first.map(String.init) ?? "?"
        let second = parts.dropFirst().first?.first.map(String.init) ?? ""
        return (first + second).uppercased()
    }

    private func color(for email: String) -> Color {
        // Stable between launches and safe even for Int.min (abs would trap).
        let hash = email.lowercased().utf8.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1) }
        let colors: [Color] = [.blue, .purple, .pink, .orange, .green, .teal, .indigo, .red]
        return colors[Int(hash % UInt64(colors.count))]
    }
}
