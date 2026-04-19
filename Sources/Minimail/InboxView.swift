import SwiftUI

struct InboxView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.3)
            if let err = state.errorBanner {
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
                .background(.quaternary, in: Capsule())
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
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func errorBanner(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(text).font(.system(size: 11)).lineLimit(2)
            Spacer()
            Button("×") { state.errorBanner = nil }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.12))
    }

    private var messageList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if state.messages.isEmpty, state.syncState != .syncing {
                    emptyState
                } else {
                    ForEach(state.messages) { msg in
                        MessageRow(message: msg)
                            .contentShape(Rectangle())
                            .onTapGesture { Task { await state.open(message: msg) } }
                        Divider().opacity(0.25)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 32))
                .opacity(0.3)
            Text("Inbox is empty")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var footer: some View {
        HStack {
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
            Text("\(state.messages.count) shown")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quinary)
    }
}

struct MessageRow: View {
    let message: Message

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(message.isUnread ? Color.accentColor : Color.clear)
                .frame(width: 8, height: 8)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(senderDisplay(message.from_addr))
                        .font(.system(size: 13, weight: message.isUnread ? .semibold : .regular))
                        .lineLimit(1)
                    Spacer()
                    Text(compactDate(message.created_at))
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
    }

    private func senderDisplay(_ raw: String) -> String {
        // "Name <email@x>" → Name, else email
        if let openIdx = raw.firstIndex(of: "<") {
            let name = raw[..<openIdx].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if !name.isEmpty { return name }
        }
        return raw
    }

    private func compactDate(_ iso: String?) -> String {
        guard let iso else { return "" }
        // email-cli returns either ISO-8601 or "YYYY-MM-DD HH:MM:SS"
        let formats = [
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
            "yyyy-MM-dd HH:mm:ss",
        ]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for fmt in formats {
            formatter.dateFormat = fmt
            if let date = formatter.date(from: iso) {
                return Self.relative.localizedString(for: date, relativeTo: Date())
            }
        }
        return iso.prefix(10).description
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
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
        let colors: [Color] = [
            .blue, .purple, .pink, .orange, .green, .teal, .indigo, .red
        ]
        return colors[hash % colors.count]
    }
}
