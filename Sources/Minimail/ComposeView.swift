import SwiftUI

struct ComposeView: View {
    @Environment(AppState.self) private var state
    @FocusState private var focus: Field?

    enum Field { case to, cc, bcc, subject, body }

    var body: some View {
        @Bindable var bound = state.compose

        VStack(spacing: 0) {
            header
            Divider().opacity(0.3)

            fromRow
            Divider().opacity(0.1)
            tokenRow(label: "To", binding: $bound.to)
            Divider().opacity(0.1)
            tokenRow(label: "Cc", binding: $bound.cc)
            Divider().opacity(0.1)
            tokenRow(label: "Bcc", binding: $bound.bcc)
            Divider().opacity(0.1)
            textFieldRow(label: "Subject", binding: $bound.subject, field: .subject)
            Divider().opacity(0.1)

            TextEditor(text: $bound.body)
                .font(.system(size: 13))
                .padding(10)
                .focused($focus, equals: .body)
                .scrollContentBackground(.hidden)
                .background(Color.clear)

            footer
        }
        .onAppear {
            if state.compose.to.isEmpty { focus = .to }
            else if state.compose.body.isEmpty { focus = .body }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button {
                if let id = state.compose.replyToID {
                    state.router.currentView = .reader(id)
                } else {
                    state.router.currentView = .inbox
                }
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(IconButtonStyle())
            .keyboardShortcut(.cancelAction)

            Text(title)
                .font(.system(size: 13, weight: .semibold))

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var title: String {
        if state.compose.replyToID != nil {
            return state.compose.replyAll ? "Reply All" : "Reply"
        }
        if state.compose.forwardingID != nil { return "Forward" }
        return "New message"
    }

    private var fromRow: some View {
        HStack(spacing: 10) {
            Text("From")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .frame(width: 52, alignment: .leading)
            Menu {
                ForEach(state.session.accounts) { acct in
                    Button {
                        state.session.currentAccount = acct
                    } label: {
                        if acct.email == state.session.currentAccount?.email {
                            Label(acct.email, systemImage: "checkmark")
                        } else {
                            Text(acct.email)
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    AccountAvatar(email: state.session.currentAccount?.email ?? "?")
                    Text(state.session.currentAccount?.email ?? "No account")
                        .font(.system(size: 12))
                        .foregroundStyle(.primary)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.06), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func tokenRow(label: String, binding: Binding<String>) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .frame(width: 52, alignment: .leading)
                .padding(.top, 4)
            EmailTokenField(text: binding, placeholder: "")
                .frame(minHeight: 24)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private func textFieldRow(label: String, binding: Binding<String>, field: Field) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .frame(width: 52, alignment: .leading)
            TextField("", text: binding)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focus, equals: field)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var footer: some View {
        HStack {
            if let err = state.compose.error {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                Text(err)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .lineLimit(1)
            } else {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            sendButton
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(state.compose.isSending || state.compose.to.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.04))
    }

    private var subtitle: String {
        if state.compose.replyToID != nil { return "Threaded reply · plain text" }
        if state.compose.forwardingID != nil { return "Forward · plain text" }
        return "Plain text"
    }

    @ViewBuilder
    private var sendButton: some View {
        let sending = state.compose.isSending
        Button {
            Task { _ = await state.send() }
        } label: {
            HStack(spacing: 6) {
                if sending {
                    ProgressView().controlSize(.small).tint(.white)
                }
                Text(sending ? "Sending…" : "Send")
                    .font(.system(size: 12, weight: .semibold))
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .opacity(sending ? 0 : 1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .foregroundStyle(.white)
            .background(
                LinearGradient(
                    colors: [Color.accentColor, Color.accentColor.opacity(0.85)],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                in: Capsule()
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
