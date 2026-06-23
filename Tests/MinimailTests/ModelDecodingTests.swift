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

    @Test("attachment list decodes stable string IDs")
    func attachmentList() throws {
        let json = """
        {
          "version": "1",
          "status": "success",
          "data": [
            {
              "id": "2a0c9ce0-3112-4728-976e-47ddcd16a318",
              "row_id": 12,
              "message_id": 77,
              "remote_attachment_id": "2a0c9ce0-3112-4728-976e-47ddcd16a318",
              "filename": "invoice.pdf",
              "content_type": "application/pdf",
              "size": 4096,
              "downloaded": true
            }
          ]
        }
        """
        let env = try decoder.decode(Envelope<[Minimail.Attachment]>.self, from: Data(json.utf8))
        let attachment = try #require(env.data?.first)
        #expect(attachment.id == "2a0c9ce0-3112-4728-976e-47ddcd16a318")
        #expect(attachment.filename == "invoice.pdf")
        #expect(attachment.downloaded == true)
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
        #expect("Alice Example <alice@example.com>".looksLikeEmail)
        #expect("\"Doe, Jane\" <jane@example.com>".looksLikeEmail)
    }

    @Test("invalid strings fail")
    func invalid() {
        #expect(!"".looksLikeEmail)
        #expect(!"no-at-sign".looksLikeEmail)
        #expect(!"@missing-local.com".looksLikeEmail)
        #expect(!"space in@email.com".looksLikeEmail)
        #expect(!"Alice <not-an-address>".looksLikeEmail)
    }

    @Test("address list preserves display names")
    func addressListSplit() {
        let raw = "\"Doe, Jane\" <jane@example.com>, bob@example.com; Alice Example <alice@example.com>"
        #expect(raw.splitAddressTokens() == [
            "\"Doe, Jane\" <jane@example.com>",
            "bob@example.com",
            "Alice Example <alice@example.com>",
        ])
    }
}

@MainActor
@Suite("Reply compose")
struct ReplyComposeTests {
    @Test("reply uses Reply-To when present")
    func replyUsesReplyTo() {
        let state = makeState()
        let msg = makeMessage(
            direction: "received",
            from: "Sender <sender@example.com>",
            to: ["Me <me@example.com>", "Other <other@example.com>"],
            cc: ["CC <cc@example.com>"],
            replyTo: ["Replies <reply@example.com>"]
        )

        state.startCompose(replyTo: msg)

        #expect(state.compose.fromOverride?.email == "me@example.com")
        #expect(state.compose.to == "Replies <reply@example.com>")
        #expect(state.compose.cc.isEmpty)
        #expect(state.compose.replyToID == msg.id)
    }

    @Test("reply all excludes self and dedupes To")
    func replyAllExcludesSelfAndDedupe() {
        let state = makeState()
        let msg = makeMessage(
            direction: "received",
            from: "Sender <sender@example.com>",
            to: ["Me <me@example.com>", "Other <other@example.com>"],
            cc: ["Other <other@example.com>", "CC <cc@example.com>"],
            replyTo: ["Sender <sender@example.com>"]
        )

        state.startCompose(replyTo: msg, replyAll: true)

        #expect(state.compose.to == "Sender <sender@example.com>")
        #expect(state.compose.cc == "Other <other@example.com>, CC <cc@example.com>")
    }

    @Test("replying to sent mail targets original recipients")
    func sentReplyTargetsOriginalRecipients() {
        let state = makeState()
        let msg = makeMessage(
            direction: "sent",
            from: "Me <me@example.com>",
            to: ["Alice <alice@example.com>"],
            cc: ["Team <team@example.com>"],
            replyTo: []
        )

        state.startCompose(replyTo: msg)

        #expect(state.compose.to == "Alice <alice@example.com>")
        #expect(state.compose.cc.isEmpty)
    }

    @Test("reply all to sent mail keeps original CC")
    func sentReplyAllKeepsOriginalCC() {
        let state = makeState()
        let msg = makeMessage(
            direction: "sent",
            from: "Me <me@example.com>",
            to: ["Alice <alice@example.com>"],
            cc: ["Team <team@example.com>", "Me <me@example.com>"],
            replyTo: []
        )

        state.startCompose(replyTo: msg, replyAll: true)

        #expect(state.compose.to == "Alice <alice@example.com>")
        #expect(state.compose.cc == "Team <team@example.com>")
    }

    private func makeState() -> AppState {
        let state = AppState()
        state.session.accounts = [
            Account(
                email: "me@example.com",
                profile_name: "local",
                display_name: nil,
                is_default: true,
                signature: ""
            ),
        ]
        return state
    }

    private func makeMessage(
        direction: String,
        from: String,
        to: [String],
        cc: [String],
        replyTo: [String]
    ) -> Message {
        Message(
            id: 10,
            remote_id: "remote-10",
            direction: direction,
            account_email: "me@example.com",
            from_addr: from,
            to: to,
            cc: cc,
            bcc: [],
            reply_to: replyTo,
            subject: "Hello",
            text_body: "Original body",
            html_body: nil,
            rfc_message_id: "<original@example.com>",
            in_reply_to: nil,
            references: [],
            last_event: direction == "sent" ? "sent" : "received",
            is_read: true,
            created_at: "2026-04-17T20:00:59Z",
            synced_at: nil,
            archived: false,
            text_preview: nil,
            starred: false,
            snoozed_until: nil,
            list_unsubscribe: nil,
            has_attachments: false
        )
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

@Suite("External link scheme allowlist")
struct ExternalLinkTests {
    @Test("web and mail schemes are allowed")
    func allowed() {
        #expect(ExternalLink.isAllowed(URL(string: "https://example.com")!))
        #expect(ExternalLink.isAllowed(URL(string: "http://example.com")!))
        #expect(ExternalLink.isAllowed(URL(string: "mailto:a@b.com")!))
        // Scheme comparison is case-insensitive.
        #expect(ExternalLink.isAllowed(URL(string: "HTTPS://example.com")!))
    }

    @Test("dangerous and custom schemes are blocked")
    func blocked() {
        #expect(!ExternalLink.isAllowed(URL(string: "file:///etc/passwd")!))
        #expect(!ExternalLink.isAllowed(URL(string: "smb://host/share")!))
        #expect(!ExternalLink.isAllowed(URL(string: "ftp://host/x")!))
        #expect(!ExternalLink.isAllowed(URL(string: "x-apple.systempreferences:com.apple.x")!))
        #expect(!ExternalLink.isAllowed(URL(string: "javascript:alert(1)")!))
    }
}

@Suite("Launch-at-login offer")
@MainActor
struct LaunchAtLoginOfferTests {
    // Mirror of AppState's private didOfferLaunchAtLoginKey.
    private static let key = "minimail.didOfferLaunchAtLogin"

    private func withCleanFlag(_ body: (AppState) -> Void) {
        let saved = UserDefaults.standard.object(forKey: Self.key)
        UserDefaults.standard.removeObject(forKey: Self.key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: Self.key) }
            else { UserDefaults.standard.removeObject(forKey: Self.key) }
        }
        body(AppState())
    }

    @Test("closing the popover while shown records the ask and stops re-showing")
    func dismissRecordsAndStopsReshow() {
        withCleanFlag { state in
            state.offerLaunchAtLoginIfNeeded()
            #expect(state.pendingLaunchAtLoginOffer == true)   // first run: offered

            // User closes the popover without pressing a button.
            state.dismissLaunchAtLoginOfferIfShown()
            #expect(state.pendingLaunchAtLoginOffer == false)
            #expect(UserDefaults.standard.bool(forKey: Self.key) == true)

            // A later bootstrap (or popover reopen) must NOT re-offer.
            state.offerLaunchAtLoginIfNeeded()
            #expect(state.pendingLaunchAtLoginOffer == false)
        }
    }

    @Test("dismiss is a no-op when the card was never shown")
    func dismissNoopWhenNotShown() {
        withCleanFlag { state in
            state.dismissLaunchAtLoginOfferIfShown()
            // Nothing was shown, so we should NOT have burned the one-time ask.
            #expect(UserDefaults.standard.bool(forKey: Self.key) == false)
        }
    }
}
