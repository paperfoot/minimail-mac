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

            composeField(label: "From", value: state.currentAccount?.email ?? "", editable: false)
            Divider().opacity(0.15)
            composeFieldBinding(label: "To", binding: $bound.composeTo, field: .to)
            Divider().opacity(0.15)
            composeFieldBinding(label: "Cc", binding: $bound.composeCc, field: .cc)
            Divider().opacity(0.15)
            composeFieldBinding(label: "Subject", binding: $bound.composeSubject, field: .subject)
            Divider().opacity(0.15)

            TextEditor(text: $bound.composeBody)
                .font(.system(size: 13))
                .padding(10)
                .focused($focus, equals: .body)

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
                state.currentView = state.composeReplyTo != nil ? .reader(state.composeReplyTo!) : .inbox
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(IconButtonStyle())

            Text(state.composeReplyTo != nil ? "Reply" : "New message")
                .font(.system(size: 13, weight: .semibold))

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func composeField(label: String, value: String, editable: Bool) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .frame(width: 52, alignment: .leading)
            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func composeFieldBinding(label: String, binding: Binding<String>, field: Field) -> some View {
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
            if let err = state.errorBanner {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .lineLimit(1)
            } else {
                Text(state.composeReplyTo != nil ? "Threaded reply" : "Plain text")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Button {
                sending = true
                Task {
                    _ = await state.send()
                    sending = false
                }
            } label: {
                if sending {
                    ProgressView().controlSize(.small).frame(width: 40)
                } else {
                    Text("Send").frame(minWidth: 40)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(sending || state.composeTo.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quinary)
    }
}
