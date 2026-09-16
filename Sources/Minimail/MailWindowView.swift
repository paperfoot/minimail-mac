import SwiftUI

/// Both presentations share AppState. The window owns one stable toolbar and
/// a sidebar that compacts without removing access to any destination.
struct MailWindowView: View {
    @Environment(AppState.self) private var state
    @AppStorage(SettingsKey.compactSidebar) private var compactSidebar = false

    private var showingSettings: Bool { state.router.currentView == .settings }
    private var title: String {
        showingSettings ? "Settings" : (state.inbox.searchQuery.isEmpty ? state.inbox.currentFolder.rawValue : "Search Results")
    }

    var body: some View {
        HStack(spacing: 0) {
            MailSidebar(compact: compactSidebar)
                .frame(width: compactSidebar ? 56 : 196)
            Divider()
            Group {
                if showingSettings {
                    SettingsView(initialSection: state.router.settingsSection)
                        .frame(maxWidth: 800)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    HSplitView {
                        InboxView(expanded: true)
                            .frame(minWidth: 280, idealWidth: 320, maxWidth: 420)
                        detail
                            .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
                            .layoutPriority(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .navigationTitle(title)
        .toolbar {
            // Outside the split view: automatic sidebar items can migrate to
            // the trailing action group when their source column disappears.
            ToolbarItem(placement: .navigation) {
                Button { compactSidebar.toggle() } label: {
                    Label(compactSidebar ? "Expand Sidebar" : "Compact Sidebar", systemImage: "sidebar.left")
                }
                .help(compactSidebar ? "Expand sidebar (⌃⌘S)" : "Compact sidebar to icons (⌃⌘S)")
            }
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
                .disabled(showingSettings)
                .help("Search all mail (⌘F)")
                Button { NotificationCenter.default.post(name: .minimailReturnToMenuBar, object: nil) } label: {
                    Label("Return to Menu Bar", systemImage: "arrow.down.right.and.arrow.up.left")
                }
                .help("Return to the menu-bar view")
            }
        }
    }

    @ViewBuilder private var detail: some View {
        Group {
            switch state.router.currentView {
            case .reader(let id): ReaderView(messageID: id)
            case .compose: ComposeView()
            case .needsInstall: NeedsInstallView()
            case .onboarding: OnboardingView()
            case .inbox, .accountSwitcher, .settings:
                ContentUnavailableView(
                    state.inbox.selection.count > 1 ? "\(state.inbox.selection.count) Messages Selected" : "Select a Message",
                    systemImage: state.inbox.selection.count > 1 ? "envelope.stack" : "envelope.open",
                    description: Text(state.inbox.selection.count > 1 ? "Use the message list actions to manage your selection." : "Choose a message to read, or start a new one.")
                )
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct MailSidebar: View {
    @Environment(AppState.self) private var state
    let compact: Bool

    var body: some View {
        VStack(spacing: 0) {
            MailAccountMenu(compact: compact)
                .font(.callout)
                .frame(maxWidth: .infinity, minHeight: 36, alignment: compact ? .center : .leading)
                .padding(.horizontal, compact ? 8 : 14)
                .padding(.top, 8)
                .padding(.bottom, 12)
            ScrollView {
                VStack(spacing: 3) {
                    ForEach(InboxState.Folder.allCases, id: \.self) { folder in
                        SidebarDestination(
                            title: folder.rawValue, symbol: folder.symbol,
                            compact: compact,
                            selected: state.router.currentView != .settings && state.inbox.currentFolder == folder,
                            count: folder == .unread ? state.totalUnread : 0
                        ) { Task { await state.selectFolder(folder) } }
                    }
                }
                .padding(.horizontal, 8)
            }
            .scrollIndicators(.hidden)
            VStack(spacing: 3) {
                SidebarDestination(title: "Outbox", symbol: "tray.and.arrow.up", compact: compact,
                                   selected: state.router.currentView == .settings && state.router.settingsSection == "outbox") {
                    Task { await state.openOutbox() }
                }
                SidebarDestination(title: "Settings", symbol: "gearshape", compact: compact,
                                   selected: state.router.currentView == .settings && state.router.settingsSection != "outbox") {
                    Task { await state.openSettings(section: "general") }
                }
            }
            .padding(8)
        }
        .background(SidebarMaterial())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mailboxes")
    }
}

private struct SidebarDestination: View {
    let title: String
    let symbol: String
    let compact: Bool
    let selected: Bool
    var count = 0
    let action: () -> Void
    @Environment(\.controlActiveState) private var activeState
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 15))
                    .frame(width: 20)
                if !compact {
                    Text(title).font(.body).lineLimit(1)
                    Spacer(minLength: 0)
                    if count > 0 {
                        Text(count.formatted()).font(.caption).monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 34, alignment: compact ? .center : .leading)
            .padding(.horizontal, compact ? 0 : 10)
            .contentShape(Rectangle())
            .background(selectionColor, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if compact && count > 0 {
                    Circle().fill(Color.accentColor).frame(width: 5, height: 5)
                        .padding(5).accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .onHover { hovered = $0 }
        .help(count > 0 ? "\(title) — \(count) unread" : title)
        .accessibilityLabel(title)
        .accessibilityValue(count > 0 ? "\(count) unread" : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var selectionColor: Color {
        if selected {
            return Color(nsColor: activeState == .inactive ? .unemphasizedSelectedContentBackgroundColor : .selectedContentBackgroundColor).opacity(0.18)
        }
        return Color.primary.opacity(hovered ? 0.06 : 0)
    }
}

/// Native sidebar vibrancy also responds to inactive windows and Reduce Transparency.
private struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
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
    @Environment(AppState.self) private var state
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
                if state.session.currentAccount == nil {
                    Text(message.account_email).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
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
