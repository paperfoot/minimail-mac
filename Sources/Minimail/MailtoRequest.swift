import Foundation

/// RFC 6068 fields we can safely offer for review in a new draft. Unknown
/// headers (including From and attachment paths) are intentionally ignored.
struct MailtoRequest: Equatable, Sendable {
    let to: String
    let cc: String
    let bcc: String
    let subject: String
    let body: String

    init?(url: URL) {
        guard url.scheme?.lowercased() == "mailto",
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let items = parts.queryItems ?? []
        func values(_ name: String) -> [String] {
            items.filter { $0.name.lowercased() == name }.compactMap(\.value)
        }
        func header(_ text: String) -> String {
            text.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        }
        to = header(([parts.path] + values("to")).filter { !$0.isEmpty }.joined(separator: ", "))
        cc = header(values("cc").joined(separator: ", "))
        bcc = header(values("bcc").joined(separator: ", "))
        subject = header(values("subject").first ?? "")
        body = values("body").first ?? ""
    }
}

extension AppState {
    func composeMailto(_ url: URL) async {
        guard let request = MailtoRequest(url: url), await prepareToLeaveCompose() else { return }
        guard !session.accounts.isEmpty else {
            inbox.error = .other("Add an account before opening an email link.")
            router.currentView = .onboarding
            return
        }
        startCompose()
        compose.to = request.to
        compose.cc = request.cc
        compose.bcc = request.bcc
        compose.subject = request.subject
        compose.body = request.body
        scheduleAutosave()
    }
}

extension Notification.Name {
    static let minimailOpenMailto = Notification.Name("ai.paperfoot.minimail.openMailto")
}
