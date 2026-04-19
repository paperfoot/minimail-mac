import SwiftUI

struct ReaderView: View {
    let messageID: Int64
    @Environment(AppState.self) private var state
    @State private var detailed: Message?
    @State private var loadError: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.3)
            if let detailed {
                content(detailed)
            } else if let loadError {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.circle").font(.system(size: 28)).opacity(0.5)
                    Text("Couldn't load message")
                        .font(.system(size: 13, weight: .semibold))
                    Text(loadError)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                    Button("Try again") {
                        Task { await load() }
                    }
                    .controlSize(.small)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            footer
        }
        .task(id: messageID) {
            await load()
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button {
                state.back()
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(IconButtonStyle())

            Text(detailed?.displaySubject ?? state.selectedMessage?.displaySubject ?? "Loading…")
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)

            Spacer()

            if let msg = detailed {
                Button {
                    state.startCompose(replyTo: msg)
                } label: {
                    Image(systemName: "arrowshape.turn.up.left")
                }
                .buttonStyle(IconButtonStyle())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func content(_ msg: Message) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                fromRow(msg)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                Divider().opacity(0.3)

                Group {
                    if let html = msg.html_body, !html.isEmpty {
                        HTMLBodyView(html: html)
                            .frame(minHeight: 300)
                    } else if let text = msg.text_body, !text.isEmpty {
                        Text(text)
                            .font(.system(size: 13))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                            .textSelection(.enabled)
                    } else {
                        Text("(no body)")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .padding(16)
                    }
                }
            }
        }
    }

    private func fromRow(_ msg: Message) -> some View {
        HStack(spacing: 10) {
            AccountAvatar(email: msg.from_addr)
                .scaleEffect(1.4)
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(msg.from_addr)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text((msg.to ?? []).joined(separator: ", "))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer()
            Text(msg.created_at?.prefix(10) ?? "")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    private var footer: some View {
        HStack {
            if let msg = detailed {
                Button {
                    state.startCompose(replyTo: msg)
                } label: {
                    Label("Reply", systemImage: "arrowshape.turn.up.left")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quinary)
    }

    private func load() async {
        do {
            detailed = try await EmailCLI.shared.readMessage(id: messageID)
        } catch {
            loadError = error.localizedDescription
        }
    }
}
