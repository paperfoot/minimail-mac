import Testing
import Foundation
@testable import Minimail

/// Contract tests against snapshotted email-cli JSON. If the wire shape drifts,
/// these fail before the user does.
@Suite("Model decoding")
struct ModelDecodingTests {
    let decoder = JSONDecoder()

    @Test("account list decodes")
    func accountList() throws {
        let env = try decoder.decode(
            Envelope<[Account]>.self,
            from: Data(Fixtures.accountList.utf8)
        )
        #expect(env.status == "success")
        #expect(env.data?.count == 2)
        #expect(env.data?.first?.email == "boris@paperfoot.com")
        #expect(env.data?.first?.is_default == true)
    }

    @Test("inbox list paginated envelope decodes")
    func inboxList() throws {
        let env = try decoder.decode(
            Envelope<InboxListResponse>.self,
            from: Data(Fixtures.inboxList.utf8)
        )
        let msgs = try #require(env.data?.messages)
        #expect(msgs.count == 1)
        let m = msgs[0]
        #expect(m.id == 77)
        #expect(m.is_read == false)
        #expect(m.archived == false)
        #expect(m.isUnread)
    }

    @Test("inbox stats decodes")
    func stats() throws {
        let env = try decoder.decode(
            Envelope<Stats>.self,
            from: Data(Fixtures.stats.utf8)
        )
        #expect(env.data?.unread == 7)
        #expect(env.data?.total == 83)
    }

    @Test("v0.7.0 fields (starred, snoozed_until, list_unsubscribe, text_preview, has_attachments) decode")
    func inboxListV07Fields() throws {
        let env = try decoder.decode(
            Envelope<InboxListResponse>.self,
            from: Data(Fixtures.inboxListV07.utf8)
        )
        let m = try #require(env.data?.messages?.first)
        #expect(m.starred == true)
        #expect(m.snoozed_until == "2026-04-21T08:00:00Z")
        #expect(m.has_attachments == true)
        #expect(m.text_preview?.hasPrefix("Short two-line") == true)
        #expect(m.list_unsubscribe?.contains("unsubscribe.example") == true)
    }

    @Test("message detail decodes with all optional fields")
    func messageDetail() throws {
        let env = try decoder.decode(
            Envelope<Message>.self,
            from: Data(Fixtures.messageDetail.utf8)
        )
        let m = try #require(env.data)
        #expect(m.html_body?.contains("Shipped") == true)
        #expect(m.references?.count == 1)
        #expect(m.in_reply_to != nil)
    }

    @Test("fromParts splits Name <email> correctly")
    func fromPartsSplit() throws {
        let env = try decoder.decode(
            Envelope<Message>.self,
            from: Data(Fixtures.messageDetail.utf8)
        )
        let m = try #require(env.data)
        let parts = m.fromParts
        #expect(parts.name == "Resend")
        #expect(parts.email == "notifications@resend.com")
    }

    @Test("fromParts handles raw email (no angle brackets)")
    func fromPartsPlain() {
        let msg = Message(
            id: 1, remote_id: nil, direction: "received", account_email: "me@x.com",
            from_addr: "sender@example.com", to: nil, cc: nil, bcc: nil, reply_to: nil,
            subject: nil, text_body: nil, html_body: nil, rfc_message_id: nil,
            in_reply_to: nil, references: nil, last_event: nil, is_read: nil,
            created_at: nil, synced_at: nil, archived: nil,
            text_preview: nil, starred: nil, snoozed_until: nil,
            list_unsubscribe: nil, has_attachments: nil
        )
        #expect(msg.fromParts.name == nil)
        #expect(msg.fromParts.email == "sender@example.com")
    }
}

@Suite("Email validator")
struct EmailValidatorTests {
    @Test("valid emails pass")
    func valid() {
        #expect("a@b.com".looksLikeEmail)
        #expect("boris+tag@paperfoot.ai".looksLikeEmail)
        #expect("first.last@sub.domain.co.uk".looksLikeEmail)
    }

    @Test("invalid strings fail")
    func invalid() {
        #expect(!"".looksLikeEmail)
        #expect(!"no-at-sign".looksLikeEmail)
        #expect(!"@missing-local.com".looksLikeEmail)
        #expect(!"space in@email.com".looksLikeEmail)
    }
}

@Suite("Date formatting")
@MainActor
struct DateFormatTests {
    @Test("parses ISO-8601 with millis")
    func parseISOFrac() {
        let d = DateFormat.parse("2026-04-17T20:00:59.710Z")
        #expect(d != nil)
    }

    @Test("parses ISO-8601 without millis")
    func parseISO() {
        let d = DateFormat.parse("2026-04-17T20:00:59Z")
        #expect(d != nil)
    }

    @Test("parses SQLite-native format")
    func parseSQLite() {
        let d = DateFormat.parse("2026-04-02 23:26:37")
        #expect(d != nil)
    }

    @Test("returns empty for nil/garbage")
    func parseGarbage() {
        #expect(DateFormat.parse(nil) == nil)
        #expect(DateFormat.parse("hello") == nil)
    }
}
