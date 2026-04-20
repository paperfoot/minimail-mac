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
                    ForEach(state.session.accounts) { account in
                        Button {
                            state.session.currentAccount = account
                            state.router.currentView = .inbox
                            Task { await state.refreshInbox() }
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
                                        .foregroundStyle(.blue)
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
