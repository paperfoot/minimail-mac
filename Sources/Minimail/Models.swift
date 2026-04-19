import Foundation

// JSON envelope shared by every email-cli command.
struct Envelope<T: Decodable & Sendable>: Decodable, Sendable {
    let status: String
    let data: T?
    let error: CLIErrorPayload?
}

struct CLIErrorPayload: Decodable, Sendable {
    let code: String?
    let message: String?
    let suggestion: String?
}

struct Account: Decodable, Sendable, Identifiable, Hashable {
    var id: String { email }
    let email: String
    let profile_name: String
    let display_name: String?
    let is_default: Bool?
    let signature: String?
}

struct Message: Decodable, Sendable, Identifiable, Hashable {
    let id: Int64
    let remote_id: String?
    let direction: String
    let account_email: String
    let from_addr: String
    let to: [String]?
    let cc: [String]?
    let bcc: [String]?
    let reply_to: [String]?
    let subject: String?
    let text_body: String?
    let html_body: String?
    let rfc_message_id: String?
    let in_reply_to: String?
    let references: [String]?
    let last_event: String?
    let is_read: Bool?
    let created_at: String?
    let synced_at: String?
    let archived: Bool?
    /// One-line snippet supplied by `inbox list` / `search` / `thread`.
    /// The full-message detail endpoint omits it (use `text_body` instead).
    let text_preview: String?

    var isUnread: Bool { !(is_read ?? true) && direction == "received" }
    var isArchived: Bool { archived ?? false }
    var displaySubject: String {
        if let s = subject, !s.isEmpty { return s }
        return "(no subject)"
    }
    /// Best-effort preview line for Gmail-style row layout. Falls back to
    /// the first line of the full text body when the list endpoint didn't
    /// pre-compute one (e.g. older email-cli versions).
    var snippet: String? {
        if let preview = text_preview, !preview.isEmpty { return preview }
        guard let body = text_body else { return nil }
        return body.split(whereSeparator: { $0.isNewline })
            .lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty && !$0.hasPrefix(">") })
            .map { String($0.prefix(160)) }
    }

    /// Split "Name <email@host>" into (name?, email).
    var fromParts: (name: String?, email: String) {
        if let openIdx = from_addr.firstIndex(of: "<"),
           let closeIdx = from_addr.firstIndex(of: ">"),
           openIdx < closeIdx {
            let rawName = from_addr[..<openIdx]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let email = String(from_addr[from_addr.index(after: openIdx)..<closeIdx])
            return (rawName.isEmpty ? nil : rawName, email)
        }
        return (nil, from_addr)
    }
}

struct InboxListResponse: Decodable, Sendable {
    let messages: [Message]?
    let has_more: Bool?
    let next_cursor: Int64?
}

struct Stats: Decodable, Sendable {
    let inbox: Int?
    let unread: Int?
    let sent: Int?
    let archived: Int?
    let total: Int?
}

struct Attachment: Decodable, Sendable, Identifiable, Hashable {
    let id: String
    let filename: String?
    let content_type: String?
    let size: Int?
    let downloaded: Bool?
}

struct Draft: Decodable, Sendable, Identifiable, Hashable {
    let id: String
    let account_email: String?
    let to: [String]?
    let cc: [String]?
    let bcc: [String]?
    let subject: String?
    let text_body: String?
    let html_body: String?
    let reply_to_message_id: Int64?
    let created_at: String?
    let updated_at: String?
}

struct SignatureResponse: Decodable, Sendable {
    let account: String?
    let signature: String?
}
