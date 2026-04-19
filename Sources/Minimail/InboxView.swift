import SwiftUI

struct InboxView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var bound = state

        VStack(spacing: 0) {
            header
            Divider().opacity(0.25)
            folderRow
            Divider().opacity(0.15)
            searchRow(bound: $bound.searchQuery)
            Divider().opacity(0.15)
            if let err = state.inboxError {
                errorBanner(err)
            }
            messageList
            footer
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                state.currentView = .accountSwitcher
            } label: {
                HStack(spacing: 8) {
                    AccountAvatar(email: state.currentAccount?.email ?? "?")
                    Text(state.currentAccount?.email ?? "No account")
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.06), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                state.startCompose()
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .buttonStyle(IconButtonStyle())
            .help("New message (⌘N)")
            .keyboardShortcut("n", modifiers: .command)

            Button {
                Task { await state.refreshInbox() }
            } label: {
                if state.syncState == .syncing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(IconButtonStyle())
            .help("Refresh (⌘R)")
            .keyboardShortcut("r", modifiers: .command)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var folderRow: some View {
        HStack(spacing: 2) {
            ForEach(AppState.Folder.allCases, id: \.self) { folder in
                FolderTab(
                    title: folder.rawValue,
                    count: count(for: folder),
                    selected: state.currentFolder == folder
                ) {
                    state.currentFolder = folder
                }
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func count(for folder: AppState.Folder) -> Int? {
        switch folder {
        case .inbox:
            let n = state.messages.filter { $0.direction == "received" && !$0.isArchived && $0.isUnread }.count
            return n > 0 ? n : nil
        case .sent:
            return nil
        case .archived:
            return nil
        }
    }

    private func searchRow(bound: Binding<String>) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
            TextField("Search", text: bound)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func errorBanner(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(text).font(.system(size: 11)).lineLimit(2)
            Spacer()
            Button {
                state.inboxError = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.12))
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if state.visibleMessages.isEmpty, state.syncState != .syncing {
                        emptyState
                    } else {
                        ForEach(Array(state.visibleMessages.enumerated()), id: \.element.id) { idx, msg in
                            MessageRow(
                                message: msg,
                                isSelected: state.selectedMessage?.id == msg.id,
                                isFocused: idx == state.focusedRowIndex
                            )
                            .id(msg.id)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                state.focusedRowIndex = idx
                                Task { await state.open(message: msg) }
                            }
                            Divider().opacity(0.15)
                        }
                    }
                }
            }
            .onKeyPress(.upArrow) {
                moveFocus(-1, proxy: proxy); return .handled
            }
            .onKeyPress(.downArrow) {
                moveFocus(1, proxy: proxy); return .handled
            }
            .onKeyPress(.return) {
                let msgs = state.visibleMessages
                let idx = state.focusedRowIndex
                if idx >= 0, idx < msgs.count {
                    Task { await state.open(message: msgs[idx]) }
                }
                return .handled
            }
            .onKeyPress("j") { moveFocus(1, proxy: proxy); return .handled }
            .onKeyPress("k") { moveFocus(-1, proxy: proxy); return .handled }
            .focusable()
        }
    }

    private func moveFocus(_ delta: Int, proxy: ScrollViewProxy) {
        let count = state.visibleMessages.count
        guard count > 0 else { return }
        let next: Int
        if state.focusedRowIndex < 0 {
            next = delta > 0 ? 0 : count - 1
        } else {
            next = max(0, min(count - 1, state.focusedRowIndex + delta))
        }
        state.focusedRowIndex = next
        withAnimation(.easeOut(duration: 0.12)) {
            proxy.scrollTo(state.visibleMessages[next].id, anchor: .center)
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
        switch state.currentFolder {
        case .inbox: return "tray"
        case .sent: return "paperplane"
        case .archived: return "archivebox"
        }
    }

    private var emptyText: String {
        if !state.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
            return "No matches"
        }
        switch state.currentFolder {
        case .inbox: return "Inbox is empty"
        case .sent: return "Nothing sent yet"
        case .archived: return "No archived messages"
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if state.totalUnread > 0 {
                Text("\(state.totalUnread) unread")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                Text("All caught up")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await state.markAllRead() }
            } label: {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 13))
            }
            .buttonStyle(IconButtonStyle())
            .help("Mark all read")
            .disabled(state.totalUnread == 0)

            Button {
                // placeholder for settings — v0.2
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
            }
            .buttonStyle(IconButtonStyle())
            .help("Settings")
            .disabled(true)
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
    let message: Message
    var isSelected: Bool = false
    var isFocused: Bool = false
    @State private var hovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Unread dot: only reserves space when unread; read rows get left-flush.
            if message.isUnread {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 8, height: 8)
                    .padding(.top, 6)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(message.fromParts.name ?? message.fromParts.email)
                        .font(.system(size: 13, weight: message.isUnread ? .semibold : .regular))
                        .lineLimit(1)
                    Spacer()
                    Text(DateFormat.inboxList(message.created_at))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                Text(message.displaySubject)
                    .font(.system(size: 12))
                    .foregroundStyle(message.isUnread ? .primary : .secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(rowBackground)
        .onHover { hovered = $0 }
    }

    @ViewBuilder
    private var rowBackground: some View {
        if isFocused {
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

/// Gmail-style relative dates: "2:14 PM" today, "Mon" this week, "Mar 15" this
/// year, "3/15/24" older. Formatters are main-actor cached; views always call
/// from the main actor anyway.
@MainActor
enum DateFormat {
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoNoFrac: ISO8601DateFormatter = {
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
    private static let timeOnly: DateFormatter = {
        let f = DateFormatter(); f.locale = .current; f.dateFormat = "h:mm a"; return f
    }()
    private static let weekday: DateFormatter = {
        let f = DateFormatter(); f.locale = .current; f.dateFormat = "EEE"; return f
    }()
    private static let monthDay: DateFormatter = {
        let f = DateFormatter(); f.locale = .current; f.dateFormat = "MMM d"; return f
    }()
    private static let shortDate: DateFormatter = {
        let f = DateFormatter(); f.locale = .current; f.dateFormat = "M/d/yy"; return f
    }()
    private static let fullDate: DateFormatter = {
        let f = DateFormatter(); f.locale = .current; f.dateStyle = .medium; f.timeStyle = .short; return f
    }()

    static func parse(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        if let d = iso.date(from: raw) { return d }
        if let d = isoNoFrac.date(from: raw) { return d }
        if let d = sqlite.date(from: raw) { return d }
        return nil
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
        let hash = abs(email.hashValue)
        let colors: [Color] = [.blue, .purple, .pink, .orange, .green, .teal, .indigo, .red]
        return colors[hash % colors.count]
    }
}
