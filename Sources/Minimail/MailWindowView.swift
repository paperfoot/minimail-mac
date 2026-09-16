import SwiftUI

/// The full client and the menu-bar presentation share the same AppState.
/// Only one presentation is mounted, so shortcuts and editors have one owner.
struct MailWindowView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                Menu {
                    Button("All Accounts") { Task { await state.selectUnifiedInbox() } }
                    Divider()
                    ForEach(Array(state.session.accounts.enumerated()), id: \.element.id) { index, account in
                        Button(account.email) { Task { await state.selectAccount(at: index + 1) } }
                    }
                } label: {
                    HStack {
                        Image(systemName: state.session.currentAccount == nil ? "tray.2" : "person.crop.circle")
                        Text(state.session.currentAccount?.email ?? "All Accounts")
                            .lineLimit(1).truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .menuStyle(.borderlessButton)
                .padding(16)
                List(selection: Binding<InboxState.Folder?>(
                    get: { state.inbox.currentFolder },
                    set: { folder in if let folder { Task { await state.selectFolder(folder) } } }
                )) {
                    Section("Mailboxes") {
                        ForEach(InboxState.Folder.allCases, id: \.self) { folder in
                            Label(folder.rawValue, systemImage: folder.symbol)
                                .badge(folder == .unread ? state.totalUnread : 0)
                                .tag(folder)
                        }
                    }
                }
                .listStyle(.sidebar)
                Spacer(minLength: 0)
                Button { Task { await state.openOutbox() } } label: {
                    Label("Outbox", systemImage: "tray.and.arrow.up")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain).padding(.horizontal, 16).padding(.vertical, 8)
                Button {
                    Task { await state.navigate(to: .settings) }
                } label: {
                    Label("Settings", systemImage: "gearshape")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(16)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
        } content: {
            InboxView(expanded: true)
                .navigationTitle(state.inbox.currentFolder.rawValue)
                .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 450)
        } detail: {
            Group {
                switch state.router.currentView {
                case .reader(let id): ReaderView(messageID: id)
                case .compose: ComposeView()
                case .settings: SettingsView(initialSection: state.router.settingsSection)
                case .needsInstall: NeedsInstallView()
                case .onboarding: OnboardingView()
                case .inbox, .accountSwitcher:
                    ContentUnavailableView(
                        state.inbox.selection.count > 1 ? "\(state.inbox.selection.count) Messages Selected" : "Select a Message",
                        systemImage: state.inbox.selection.count > 1 ? "envelope.stack" : "envelope.open",
                        description: Text(state.inbox.selection.count > 1 ? "Use the message list actions to manage your selection." : "Choose a message to read, or start a new one.")
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { Task { await state.saveComposeAndStartNew() } } label: {
                    Label("New Message", systemImage: "square.and.pencil")
                }
                .help("New message (⌘N)")
                Button { Task { await state.refreshInbox() } } label: {
                    Label("Check Mail", systemImage: "arrow.clockwise")
                }
                .disabled(state.inbox.syncState == .syncing)
                .help("Check for new mail (⇧⌘N)")
                Button { NotificationCenter.default.post(name: .minimailFocusSearch, object: nil) } label: {
                    Label("Search", systemImage: "magnifyingglass")
                }
                .help("Search all mail (⌘F)")
                Button { NotificationCenter.default.post(name: .minimailReturnToMenuBar, object: nil) } label: {
                    Label("Return to Menu Bar", systemImage: "arrow.down.right.and.arrow.up.left")
                }
                .help("Return to the menu-bar view")
            }
        }
    }
}

extension InboxState.Folder {
    var symbol: String {
        switch self {
        case .inbox: "tray"
        case .unread: "envelope.badge"
        case .starred: "star"
        case .snoozed: "clock"
        case .sent: "paperplane"
        case .drafts: "doc"
        case .archived: "archivebox"
        }
    }
}

struct WindowMessageRow: View {
    let message: Message
    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Circle().fill(message.isUnread ? Color.accentColor : .clear)
                .frame(width: 6, height: 6).padding(.top, 6)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(message.correspondent)
                        .font(.system(size: 13, weight: message.isUnread ? .semibold : .regular))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if message.isStarred { Image(systemName: "star.fill").font(.system(size: 10)).foregroundStyle(.yellow) }
                    if message.has_attachments == true { Image(systemName: "paperclip").font(.system(size: 10)).foregroundStyle(.secondary) }
                    Text(DateFormat.inboxList(message.created_at))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Text(message.displaySubject).font(.system(size: 12, weight: message.isUnread ? .medium : .regular)).lineLimit(1)
                if let snippet = message.snippet {
                    Text(snippet).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
        .accessibilityValue(message.isUnread ? "Unread" : "Read")
    }
}
