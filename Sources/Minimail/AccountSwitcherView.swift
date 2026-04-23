import SwiftUI

struct AccountSwitcherView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    state.router.currentView = .inbox
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(IconButtonStyle())
                .keyboardShortcut(.escape, modifiers: [])
                .help("Back to inbox (esc)")

                Text("Accounts")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider().opacity(0.3)

            ScrollView {
                VStack(spacing: 0) {
                    // Unified inbox row — Apple Mail "All Inboxes" / Outlook
                    // "Unified Inbox" pattern. `currentAccount = nil` is the
                    // sentinel; CLI omits the --account flag and returns
                    // every account's mail merged.
                    Button {
                        Task { await state.selectUnifiedInbox() }
                        state.router.currentView = .inbox
                    } label: {
                        HStack(spacing: 10) {
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
                            VStack(alignment: .leading, spacing: 2) {
                                Text("All Accounts")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.primary)
                                Text("Unified inbox · ⌘0")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            if state.session.currentAccount == nil {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                                    .font(.system(size: 12, weight: .semibold))
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider().opacity(0.2)

                    ForEach(Array(state.session.accounts.enumerated()), id: \.element.id) { idx, account in
                        Button {
                            Task { await state.selectAccount(at: idx + 1) }
                            state.router.currentView = .inbox
                        } label: {
                            HStack(spacing: 10) {
                                AccountAvatar(email: account.email)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(account.email)
                                        .font(.system(size: 13))
                                        .foregroundStyle(.primary)
                                    if account.is_default == true {
                                        Text("Default")
                                            .font(.system(size: 10))
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                Spacer()
                                if state.session.currentAccount?.email == account.email {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.accentColor)
                                        .font(.system(size: 12, weight: .semibold))
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().opacity(0.2)
                    }
                }
            }
        }
    }
}
