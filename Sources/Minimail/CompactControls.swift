import SwiftUI

struct CompactExpandButton: View {
    var body: some View {
        Button {
            NotificationCenter.default.post(name: .minimailExpandWindow, object: nil)
        } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
        }
        .buttonStyle(IconButtonStyle())
        .help("Open full mail window (⌥⌘1)")
        .accessibilityLabel("Open full mail window")
    }
}

struct MailAccountMenu: View {
    var compact = false
    @Environment(AppState.self) private var state

    var body: some View {
        Menu {
            Button { Task { await state.selectUnifiedInbox() } } label: {
                Label("All Accounts", systemImage: state.session.currentAccount == nil ? "checkmark" : "tray.2")
            }
            Divider()
            ForEach(Array(state.session.accounts.enumerated()), id: \.element.id) { index, account in
                Button { Task { await state.selectAccount(at: index + 1) } } label: {
                    Label(account.email, systemImage: account.id == state.session.currentAccount?.id ? "checkmark" : "person.crop.circle")
                }
            }
            Divider()
            Button("Manage Accounts…") {
                Task { await state.openSettings(section: "accounts") }
            }
        } label: {
            if compact {
                Image(systemName: state.session.currentAccount == nil ? "person.2.crop.square.stack" : "person.crop.circle")
                    .font(.system(size: 18))
                    .frame(width: 32, height: 32)
            } else {
                Text(state.session.currentAccount?.email ?? "All Accounts")
                    .lineLimit(1).truncationMode(.middle)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(compact ? .hidden : .visible)
        .help(state.session.currentAccount?.email ?? "All Accounts")
        .accessibilityLabel("Account: \(state.session.currentAccount?.email ?? "All Accounts")")
    }
}
