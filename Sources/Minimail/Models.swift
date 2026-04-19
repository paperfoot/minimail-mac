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
    let subject: String?
    let text_body: String?
    let html_body: String?
    let rfc_message_id: String?
    let in_reply_to: String?
    let last_event: String?
    let is_read: Int?
    let created_at: String?
    let archived: Int?

    var isUnread: Bool { (is_read ?? 0) == 0 && direction == "received" }
    var displaySubject: String { subject?.isEmpty == false ? subject! : "(no subject)" }
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
