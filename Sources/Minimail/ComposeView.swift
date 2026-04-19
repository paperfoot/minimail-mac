import SwiftUI

struct ComposeView: View {
    @Environment(AppState.self) private var state
    @FocusState private var focus: Field?
    @State private var sending = false

    enum Field { case to, cc, subject, body }

    var body: some View {
        @Bindable var bound = state

        VStack(spacing: 0) {
            header
            Divider().opacity(0.3)

            fromRow
            Divider().opacity(0.1)
            tokenRow(label: "To", binding: $bound.composeTo, placeholder: "")
            Divider().opacity(0.1)
            tokenRow(label: "Cc", binding: $bound.composeCc, placeholder: "")
            Divider().opacity(0.1)
            textFieldRow(label: "Subject", binding: $bound.composeSubject, field: .subject)
            Divider().opacity(0.1)

            bodyEditor(bound: $bound.composeBody)

            footer
        }
        .onAppear {
            if state.composeTo.isEmpty { focus = .to }
            else if state.composeBody.isEmpty { focus = .body }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button {
                if let replyTo = state.composeReplyTo {
                    state.currentView = .reader(replyTo)
                } else {
                    state.currentView = .inbox
                }
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(IconButtonStyle())
            .keyboardShortcut(.cancelAction)

            Text(state.composeReplyTo != nil ? "Reply" : "New message")
                .font(.system(size: 13, weight: .semibold))

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var fromRow: some View {
        HStack(spacing: 10) {
            Text("From")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .frame(width: 52, alignment: .leading)
            Menu {
                ForEach(state.accounts) { acct in
                    Button {
                        state.currentAccount = acct
                    } label: {
                        if acct.email == state.currentAccount?.email {
                            Label(acct.email, systemImage: "checkmark")
                        } else {
                            Text(acct.email)
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    AccountAvatar(email: state.currentAccount?.email ?? "?")
                    Text(state.currentAccount?.email ?? "No account")
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

    private func tokenRow(label: String, binding: Binding<String>, placeholder: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .frame(width: 52, alignment: .leading)
                .padding(.top, 4)
            EmailTokenField(text: binding, placeholder: placeholder)
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

    private func bodyEditor(bound: Binding<String>) -> some View {
        TextEditor(text: bound)
            .font(.system(size: 13))
            .padding(10)
            .focused($focus, equals: .body)
            .scrollContentBackground(.hidden) // transparent bg (macOS 13+)
            .background(Color.clear)
    }

    private var footer: some View {
        HStack {
            if let err = state.composeError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                Text(err)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .lineLimit(1)
            } else {
                Text(state.composeReplyTo != nil ? "Threaded reply · plain text" : "Plain text")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            sendButton
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(sending || state.composeTo.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.04))
    }

    @ViewBuilder
    private var sendButton: some View {
        Button {
            sending = true
            Task {
                _ = await state.send()
                sending = false
            }
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
