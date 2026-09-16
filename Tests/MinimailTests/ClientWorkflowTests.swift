import Foundation
import Testing
@testable import Minimail

@MainActor
@Suite("Client workflow regressions")
struct ClientWorkflowTests {
    @Test("Cc, Bcc, and Reply-To alone each make a draft worth saving")
    func secondaryRecipientsCountAsContent() {
        let ccOnly = ComposeState()
        ccOnly.cc = "copy@example.com"
        #expect(ccOnly.hasContent)

        let bccOnly = ComposeState()
        bccOnly.bcc = "private@example.com"
        #expect(bccOnly.hasContent)

        let replyToOnly = ComposeState()
        replyToOnly.replyTo = "replies@example.com"
        #expect(replyToOnly.hasContent)
    }

    @Test("Tomorrow schedule choices stay on the next local day across DST")
    func tomorrowScheduleChoicesUseNextCalendarDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/London"))

        // Each date is the day before a UK clock change. Testing once before
        // 09:00 and once after 17:00 catches both the old same-day bug and
        // accidental 24-hour arithmetic across daylight-saving transitions.
        let cases = [
            try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 28, hour: 8))),
            try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: 18))),
        ]

        for now in cases {
            let options = ComposeView.scheduleOptions(now: now, calendar: calendar)
            let morning = try #require(options.first { $0.label.hasPrefix("Tomorrow morning") }?.date)
            let evening = try #require(options.first { $0.label.hasPrefix("Tomorrow evening") }?.date)
            let expectedDay = try #require(calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)))

            #expect(calendar.isDate(morning, inSameDayAs: expectedDay))
            #expect(calendar.component(.hour, from: morning) == 9)
            #expect(calendar.isDate(evening, inSameDayAs: expectedDay))
            #expect(calendar.component(.hour, from: evening) == 17)
        }
    }

    @Test("Message merge deduplicates and sorts equal timestamps by descending id")
    func mergeMessagesIsDeterministic() {
        let older = Self.message(id: 1, account: "me@example.com", subject: "older", createdAt: "2026-09-15T10:00:00Z")
        let tieLow = Self.message(id: 2, account: "me@example.com", subject: "low", createdAt: "2026-09-16T10:00:00Z")
        let tieHigh = Self.message(id: 3, account: "me@example.com", subject: "kept", createdAt: "2026-09-16T10:00:00Z")
        let duplicate = Self.message(id: 3, account: "me@example.com", subject: "discarded", createdAt: "2026-09-01T10:00:00Z")

        let merged = AppState.mergeMessages([older, tieLow, tieHigh, duplicate])

        #expect(merged.map { $0.id } == [3, 2, 1])
        #expect(merged.first?.subject == "kept")
    }

    @Test("Opening a pending draft restores the complete Undo Send snapshot")
    func openingPendingDraftRestoresSnapshot() async throws {
        let state = AppState(cli: EmailCLI(binaryPath: "/path/that/must/not/run"))
        let sendingAccount = Account(
            email: "sender@example.com",
            profile_name: "local",
            display_name: "Sender",
            is_default: false,
            signature: ""
        )
        state.session.accounts = [sendingAccount]

        let scheduled = try #require(ISO8601DateFormatter().date(from: "2026-10-25T18:30:00Z"))
        let attachment = URL(fileURLWithPath: "/tmp/minimail-undo-attachment.pdf")
        state.pendingSend = PendingSend(
            from: sendingAccount.email,
            to: ["to@example.com"],
            cc: ["cc@example.com"],
            bcc: ["bcc@example.com"],
            replyTo: ["replies@example.com"],
            subject: "Complete snapshot",
            text: "Draft body",
            html: nil,
            attachments: [attachment],
            replyToMessageID: 404,
            scheduledAt: AppState.isoFormatter.string(from: scheduled),
            originalDraftID: "draft-123",
            queuedAt: Date(),
            deadline: Date().addingTimeInterval(10)
        )

        let pendingDraftJSON = #"{"status":"success","data":{"id":"draft-123","subject":"Stale sidebar copy"}}"#
        let pendingDraft = try #require(
            JSONDecoder().decode(Envelope<Draft>.self, from: Data(pendingDraftJSON.utf8)).data
        )
        await state.openDraft(pendingDraft)

        #expect(state.pendingSend == nil)
        #expect(state.compose.fromOverride == sendingAccount)
        #expect(state.compose.to == "to@example.com")
        #expect(state.compose.cc == "cc@example.com")
        #expect(state.compose.bcc == "bcc@example.com")
        #expect(state.compose.replyTo == "replies@example.com")
        #expect(state.compose.subject == "Complete snapshot")
        #expect(state.compose.body == "Draft body")
        #expect(state.compose.attachments == [attachment])
        #expect(state.compose.replyToID == 404)
        #expect(state.compose.editingDraftID == "draft-123")
        #expect(abs(try #require(state.compose.scheduledAt).timeIntervalSince(scheduled)) < 1)
        #expect(state.router.currentView == .compose(404))
    }

    @Test("Inbox pagination passes the cursor to the CLI and decodes the next cursor")
    func inboxPagePassesAfterCursor() async throws {
        let fixture = try Self.makeExecutableScript(
            body: #"""
            printf '%s\n' "$@" > "${0}.args"
            printf '%s\n' '{"status":"success","data":{"messages":[],"has_more":true,"next_cursor":987}}'
            """#
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let cli = EmailCLI(binaryPath: fixture.executable.path)
        let page = try await cli.listInboxPage(
            account: "me@example.com",
            archived: true,
            limit: 25,
            after: 321
        )
        let argsText = try String(contentsOf: fixture.arguments, encoding: .utf8)
        let args = argsText.split(whereSeparator: { $0.isNewline }).map(String.init)

        #expect(page.has_more == true)
        #expect(page.next_cursor == 987)
        #expect(args.contains("--archived"))
        #expect(Self.adjacentValue(for: "--account", in: args) == "me@example.com")
        #expect(Self.adjacentValue(for: "--limit", in: args) == "25")
        #expect(Self.adjacentValue(for: "--after", in: args) == "321")
    }

    @Test("A slower previous account refresh cannot overwrite the newly selected account")
    func accountRefreshIsScopedToSelection() async throws {
        let fixture = try Self.makeExecutableScript(body: Self.accountScopedScript)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let state = AppState(cli: EmailCLI(binaryPath: fixture.executable.path))
        let accountA = Self.account(email: "a@example.com")
        let accountB = Self.account(email: "b@example.com")
        state.session.accounts = [accountA, accountB]

        let slowA = Task { @MainActor in await state.selectAccount(at: 1) }
        try await Task.sleep(for: .milliseconds(60))
        let fastB = Task { @MainActor in await state.selectAccount(at: 2) }
        await fastB.value
        await slowA.value

        #expect(state.session.currentAccount?.email == accountB.email)
        #expect(!state.inbox.messages.isEmpty)
        #expect(state.inbox.messages.allSatisfy { $0.account_email == accountB.email })
    }

    @Test("Search results are discarded when the selected account changes mid-request")
    func searchResultsAreScopedToAccount() async throws {
        let fixture = try Self.makeExecutableScript(body: Self.accountScopedScript)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let state = AppState(cli: EmailCLI(binaryPath: fixture.executable.path))
        let accountA = Self.account(email: "a@example.com")
        let accountB = Self.account(email: "b@example.com")
        state.session.accounts = [accountA, accountB]
        state.session.currentAccount = accountA
        state.inbox.searchQuery = "needle"

        let search = Task { @MainActor in await state.performSearch() }
        try await Task.sleep(for: .milliseconds(60))
        state.session.currentAccount = accountB
        await search.value

        #expect(state.inbox.searchResults.isEmpty)
    }

    @Test("Older draft JSON remains compatible when delivery fields are absent")
    func legacyDraftDecodesWithoutDeliveryFields() throws {
        let json = #"""
        {
          "status": "success",
          "data": {
            "id": "legacy-draft",
            "account_email": "sender@example.com",
            "to": ["to@example.com"],
            "cc": [],
            "bcc": [],
            "subject": "Legacy",
            "text_body": "Saved before the new fields existed",
            "html_body": null,
            "reply_to_message_id": null
          }
        }
        """#

        let envelope = try JSONDecoder().decode(Envelope<Draft>.self, from: Data(json.utf8))
        let draft = try #require(envelope.data)

        #expect(draft.reply_to == nil)
        #expect(draft.scheduled_at == nil)
    }

    @Test("Reopening a current draft restores delivery fields and keeps newer edits")
    func currentDraftRestoresDeliveryFields() async throws {
        let json = #"""
        {
          "status": "success",
          "data": {
            "id": "current-draft",
            "account_email": "sender@example.com",
            "to": ["to@example.com"],
            "cc": [],
            "bcc": [],
            "reply_to": ["replies@example.com", "team@example.com"],
            "scheduled_at": "2026-10-25T18:30:00Z",
            "subject": "Scheduled draft",
            "text_body": "Remember every field",
            "html_body": null,
            "reply_to_message_id": 404
          }
        }
        """#
        let draft = try #require(
            JSONDecoder().decode(Envelope<Draft>.self, from: Data(json.utf8)).data
        )
        let fixture = try Self.makeExecutableScript(
            body: #"""
            printf '%s\n' '{"status":"success","data":{"id":"current-draft","attachment_paths":[]}}'
            """#
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let state = AppState(cli: EmailCLI(binaryPath: fixture.executable.path))
        state.session.accounts = [Self.account(email: "sender@example.com")]

        state.edit(draft: draft)

        #expect(state.compose.replyTo == "replies@example.com, team@example.com")
        #expect(state.compose.replyToID == 404)
        #expect(state.compose.editingDraftID == "current-draft")
        #expect(state.compose.fromOverride?.email == "sender@example.com")
        #expect(state.compose.scheduledAt == Dates.parse("2026-10-25T18:30:00Z"))
        #expect(state.router.currentView == .compose(nil))

        state.compose.subject = "Newer local subject"
        await state.openDraft(draft)

        #expect(state.compose.editingDraftID == draft.id)
        #expect(state.compose.subject == "Newer local subject")
    }

    @Test("Explicitly clearing draft delivery and HTML fields emits clear flags")
    func editDraftEmitsExplicitClearFlags() async throws {
        let fixture = try Self.makeExecutableScript(
            body: #"""
            printf '%s\n' "$@" > "${0}.args"
            printf '%s\n' '{"status":"success","data":{"id":"draft-clear","attachment_paths":[]}}'
            """#
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let cli = EmailCLI(binaryPath: fixture.executable.path)

        try await cli.editDraft(
            id: "draft-clear",
            to: nil,
            cc: nil,
            bcc: nil,
            subject: nil,
            text: nil,
            replyTo: [],
            clearSchedule: true,
            clearHTML: true
        )
        let args = try Self.recordedArguments(from: fixture.arguments)

        #expect(args.contains("--clear-html"))
        #expect(args.contains("--clear-schedule"))
        #expect(Self.adjacentValue(for: "--reply-to", in: args) == "")
    }

    @Test("Omitted draft fields leave their CLI flags absent")
    func editDraftOmitsPreservedFields() async throws {
        let fixture = try Self.makeExecutableScript(
            body: #"""
            printf '%s\n' "$@" > "${0}.args"
            printf '%s\n' '{"status":"success","data":{"id":"draft-preserve","attachment_paths":[]}}'
            """#
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let cli = EmailCLI(binaryPath: fixture.executable.path)

        try await cli.editDraft(
            id: "draft-preserve",
            to: nil,
            cc: nil,
            bcc: nil,
            subject: nil,
            text: nil
        )
        let args = try Self.recordedArguments(from: fixture.arguments)

        #expect(args.contains("--reply-to") == false)
        #expect(args.contains("--scheduled-at") == false)
        #expect(args.contains("--clear-schedule") == false)
        #expect(args.contains("--html") == false)
        #expect(args.contains("--clear-html") == false)
    }

    @Test("Adding a profile validates it while keeping the API key out of argv")
    func profileAddUsesValidatedEnvironmentSecret() async throws {
        let fixture = try Self.makeExecutableScript(
            body: #"""
            printf '%s\n' "$@" > "${0}.args"
            printf '%s' "${MINIMAIL_RESEND_API_KEY-}" > "${0}.secret"
            """#
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let secret = "re_test_secret_that_must_not_reach_argv"
        let cli = EmailCLI(binaryPath: fixture.executable.path)

        try await cli.addProfile(name: "work", apiKey: secret)
        let args = try Self.recordedArguments(from: fixture.arguments)
        let capturedSecret = try String(
            contentsOf: URL(fileURLWithPath: fixture.executable.path + ".secret"),
            encoding: .utf8
        )

        #expect(args.prefix(3) == ["profile", "add", "work"])
        #expect(args.contains("--validate"))
        #expect(Self.adjacentValue(for: "--api-key-env", in: args) == "MINIMAIL_RESEND_API_KEY")
        #expect(args.contains(secret) == false)
        #expect(capturedSecret == secret)
    }

    @Test("Editing an account serializes its display name and profile")
    func accountEditSerializesNameAndProfile() async throws {
        let fixture = try Self.makeExecutableScript(
            body: #"""
            printf '%s\n' "$@" > "${0}.args"
            """#
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let cli = EmailCLI(binaryPath: fixture.executable.path)

        try await cli.editAccount(
            email: "sender@example.com",
            name: "Sender Name",
            profile: "production"
        )
        let args = try Self.recordedArguments(from: fixture.arguments)

        #expect(args.prefix(3) == ["account", "edit", "sender@example.com"])
        #expect(Self.adjacentValue(for: "--name", in: args) == "Sender Name")
        #expect(Self.adjacentValue(for: "--profile", in: args) == "production")
    }

    @Test("Removing an account is refused while its send is pending or delivering")
    func accountRemovalRefusesUnfinishedDelivery() async {
        let fixture = try? Self.makeExecutableScript(
            body: #"""
            : > "${0}.called"
            printf '%s\n' '{"status":"success","data":{}}'
            """#
        )
        guard let fixture else {
            Issue.record("Could not create isolated email-cli fixture")
            return
        }
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let state = AppState(cli: EmailCLI(binaryPath: fixture.executable.path))
        let snapshot = Self.pendingSend(from: "busy@example.com")

        state.pendingSend = snapshot
        var pendingWasRejected = false
        do {
            try await state.removeMailAccount("busy@example.com")
        } catch {
            pendingWasRejected = true
        }

        state.pendingSend = nil
        state.deliveringSend = snapshot
        var deliveringWasRejected = false
        do {
            try await state.removeMailAccount("busy@example.com")
        } catch {
            deliveringWasRejected = true
        }

        #expect(pendingWasRejected)
        #expect(deliveringWasRejected)
        #expect(FileManager.default.fileExists(atPath: fixture.executable.path + ".called") == false)
    }

    @Test("Successful account removal clears mute state and refreshes the mailbox")
    func accountRemovalClearsMuteAndRefreshesMailbox() async throws {
        let fixture = try Self.makeExecutableScript(
            body: #"""
            args=" $* "
            case "$args" in
              *" account remove removed@example.com "*)
                printf '%s\n' '{"status":"success","data":{}}'
                ;;
              *" account list "*)
                printf '%s\n' '{"status":"success","data":[{"email":"remaining@example.com","profile_name":"work","is_default":true}]}'
                ;;
              *" inbox list "*)
                case "$args" in
                  *" --archived "*|*" --snoozed "*)
                    printf '%s\n' '{"status":"success","data":{"messages":[],"has_more":false,"next_cursor":null}}'
                    ;;
                  *)
                    printf '%s\n' '{"status":"success","data":{"messages":[{"id":909,"direction":"received","account_email":"remaining@example.com","from_addr":"fresh@example.com","subject":"Fresh mailbox","created_at":"2026-09-16T12:00:00Z"}],"has_more":false,"next_cursor":null}}'
                    ;;
                esac
                ;;
              *" inbox stats "*)
                printf '%s\n' '{"status":"success","data":{"unread":1}}'
                ;;
              *)
                printf '%s\n' 'unexpected command' >&2
                exit 4
                ;;
            esac
            """#
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let email = "removed@example.com"
        let muteKey = SettingsKey.muteKey(for: email)
        UserDefaults.standard.set(true, forKey: muteKey)
        defer { UserDefaults.standard.removeObject(forKey: muteKey) }

        let state = AppState(cli: EmailCLI(binaryPath: fixture.executable.path))
        let removed = Self.account(email: email)
        state.session.accounts = [removed, Self.account(email: "remaining@example.com")]
        state.session.currentAccount = removed
        state.inbox.messages = [Self.message(
            id: 1,
            account: email,
            subject: "Stale mailbox",
            createdAt: "2026-09-15T10:00:00Z"
        )]
        state.inbox.selection = [1]
        state.reader.loaded = state.inbox.messages.first

        try await state.removeMailAccount(email)

        #expect(UserDefaults.standard.object(forKey: muteKey) == nil)
        #expect(state.session.accounts.map(\.email) == ["remaining@example.com"])
        #expect(state.session.currentAccount == nil)
        #expect(state.inbox.messages.map(\.id) == [909])
        #expect(state.inbox.messages.first?.account_email == "remaining@example.com")
        #expect(state.inbox.selection.isEmpty)
        #expect(state.reader.loaded == nil)
    }

    @Test("Changing the default sender preserves the Unified mailbox")
    func settingDefaultAccountPreservesUnifiedMailbox() async throws {
        let fixture = try Self.makeExecutableScript(
            body: #"""
            args=" $* "
            case "$args" in
              *" account use second@example.com "*)
                printf '%s\n' '{"status":"success","data":{}}'
                ;;
              *" account list "*)
                printf '%s\n' '{"status":"success","data":[{"email":"first@example.com","profile_name":"work","is_default":false},{"email":"second@example.com","profile_name":"work","is_default":true}]}'
                ;;
              *)
                printf '%s\n' 'unexpected command' >&2
                exit 4
                ;;
            esac
            """#
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let preferredKey = "minimail.preferredAccount"
        let previousPreference = UserDefaults.standard.object(forKey: preferredKey)
        UserDefaults.standard.set("__all__", forKey: preferredKey)
        defer {
            if let previousPreference {
                UserDefaults.standard.set(previousPreference, forKey: preferredKey)
            } else {
                UserDefaults.standard.removeObject(forKey: preferredKey)
            }
        }
        let state = AppState(cli: EmailCLI(binaryPath: fixture.executable.path))
        state.session.accounts = [Self.account(email: "first@example.com")]
        state.session.currentAccount = nil

        try await state.setDefaultMailAccount("second@example.com")

        #expect(state.session.accounts.first(where: { $0.email == "second@example.com" })?.is_default == true)
        #expect(state.session.currentAccount == nil)
    }

    @Test("Repeated autosaves adopt each durable attachment snapshot")
    func autosaveAdoptsRepeatedAttachmentSnapshots() async throws {
        let fixture = try Self.makeExecutableScript(
            body: #"""
            attach=""
            while [ "$#" -gt 0 ]; do
              case "$1" in
                --attach) attach="$2"; shift 2 ;;
                *) shift ;;
              esac
            done
            if [ -z "$attach" ]; then
              printf '%s\n' 'missing --attach' >&2
              exit 3
            fi

            count_file="${0}.count"
            count=0
            if [ -f "$count_file" ]; then count=$(sed -n '1p' "$count_file"); fi
            count=$((count + 1))
            printf '%s\n' "$count" > "$count_file"

            snapshot="${0}.snapshot-${count}"
            cp "$attach" "$snapshot"

            previous_file="${0}.previous"
            if [ -f "$previous_file" ]; then
              previous=$(sed -n '1p' "$previous_file")
              if [ -n "$previous" ] && [ "$previous" != "$snapshot" ]; then
                rm -f "$previous"
              fi
            fi
            printf '%s\n' "$snapshot" > "$previous_file"
            printf '{"status":"success","data":{"id":"snapshot-draft","attachment_paths":["%s"]}}\n' "$snapshot"
            """#
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let original = fixture.directory.appendingPathComponent("original.txt")
        let expectedBytes = Data("attachment survives repeated saves".utf8)
        try expectedBytes.write(to: original)

        let state = AppState(cli: EmailCLI(binaryPath: fixture.executable.path))
        let sendingAccount = Self.account(email: "sender@example.com")
        state.session.accounts = [sendingAccount]
        state.session.currentAccount = sendingAccount
        state.compose.body = "Draft with attachment"
        state.compose.attachments = [original]

        await state.flushAutosave()
        let firstSnapshot = try #require(state.compose.attachments.first)
        #expect(state.compose.error == nil)
        #expect(firstSnapshot != original)
        #expect(FileManager.default.fileExists(atPath: firstSnapshot.path))

        await state.flushAutosave()
        let secondSnapshot = try #require(state.compose.attachments.first)

        #expect(state.compose.error == nil)
        #expect(secondSnapshot != firstSnapshot)
        #expect(FileManager.default.fileExists(atPath: firstSnapshot.path) == false)
        #expect(FileManager.default.fileExists(atPath: secondSnapshot.path))
        #expect(try Data(contentsOf: secondSnapshot) == expectedBytes)
        #expect(FileManager.default.fileExists(atPath: original.path))
    }

    @Test("Undo Send timer completes delivery without cancelling its own CLI process", .timeLimit(.minutes(1)))
    func undoSendTimerCompletesDelivery() async throws {
        let fixture = try Self.makeExecutableScript(
            body: #"""
            args=" $* "
            case "$args" in
              *" draft create "*)
                printf '%s\n' '{"status":"success","data":{"id":"timer-draft","attachment_paths":[]}}'
                ;;
              *" send "*)
                sleep 0.1
                : > "${0}.sent"
                printf '%s\n' '{"status":"success","data":{}}'
                ;;
              *" draft delete "*)
                printf '%s\n' '{"status":"success","data":{}}'
                ;;
              *" inbox list "*)
                printf '%s\n' '{"status":"success","data":{"messages":[],"has_more":false,"next_cursor":null}}'
                ;;
              *" inbox stats "*)
                printf '%s\n' '{"status":"success","data":{"unread":0}}'
                ;;
              *" draft list "*)
                printf '%s\n' '{"status":"success","data":[]}'
                ;;
              *)
                printf '%s\n' '{"status":"success","data":{}}'
                ;;
            esac
            """#
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let state = AppState(cli: EmailCLI(binaryPath: fixture.executable.path))
        let sendingAccount = Self.account(email: "sender@example.com")
        state.session.accounts = [sendingAccount]
        state.session.currentAccount = sendingAccount
        state.compose.to = "recipient@example.com"
        state.compose.subject = "Timer regression"
        state.compose.body = "This must reach the fake CLI after the undo window."

        let queued = await state.send()
        #expect(queued)
        #expect(state.pendingSend != nil)

        // Exercise the production ten-second undo timer. One bounded wait is
        // intentional here: shortening or manually flushing it would miss the
        // self-cancellation regression this test protects.
        try await Task.sleep(for: .seconds(11))

        #expect(state.pendingSend == nil)
        #expect(state.deliveringSend == nil)
        #expect(FileManager.default.fileExists(atPath: fixture.executable.path + ".sent"))
    }

    @Test("Waiting for delivery returns only after an in-flight send finishes")
    func waitForDeliveryDrainsInFlightSend() async throws {
        let fixture = try Self.makeExecutableScript(
            body: #"""
            case "$1" in
              send)
                : > "${0}.started"
                sleep 0.5
                : > "${0}.sent"
                printf '%s\n' '{"status":"success","data":{}}'
                ;;
              *)
                printf '%s\n' 'unexpected command' >&2
                exit 4
                ;;
            esac
            """#
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let state = AppState(cli: EmailCLI(binaryPath: fixture.executable.path))
        state.pendingSend = PendingSend(
            from: "sender@example.com",
            to: ["recipient@example.com"],
            cc: [],
            bcc: [],
            replyTo: [],
            subject: "Quit while sending",
            text: "The app must drain this delivery.",
            html: nil,
            attachments: [],
            replyToMessageID: nil,
            scheduledAt: nil,
            originalDraftID: nil,
            queuedAt: Date(),
            deadline: Date().addingTimeInterval(10)
        )

        let flush = Task { @MainActor in await state.flushPendingSendNow() }
        // Give the flush task one bounded scheduling window to enter the fake
        // CLI's deliberately delayed send, then exercise the quit-time waiter.
        try await Task.sleep(for: .milliseconds(100))
        #expect(state.deliveringSend != nil)
        #expect(FileManager.default.fileExists(atPath: fixture.executable.path + ".sent") == false)

        await state.waitForDelivery()

        #expect(FileManager.default.fileExists(atPath: fixture.executable.path + ".sent"))
        #expect(state.deliveringSend == nil)
        await flush.value
    }

    @Test("Mark All as Read traverses older, archived, and snoozed pages")
    func markAllReadTraversesMailbox() async throws {
        let fixture = try Self.makeExecutableScript(body: #"""
        args=" $* "
        case "$args" in
          *" inbox list "*)
            case "$args" in
              *" --archived"*" --snoozed "*) id=40; more=false ;;
              *" --archived "*) id=30; more=false ;;
              *" --snoozed "*) id=20; more=false ;;
              *" --after "*) id=11; more=false ;;
              *) id=10; more=true ;;
            esac
            printf '{"status":"success","data":{"messages":[{"id":%s,"direction":"received","account_email":"a@example.com","from_addr":"person@example.com","is_read":false}],"has_more":%s,"next_cursor":%s}}\n' "$id" "$more" "$id"
            ;;
          *" inbox mark "*)
            printf '%s\n' "$*" >> "${0}.marks"
            printf '%s\n' '{"status":"success","data":{}}'
            ;;
          *" inbox stats "*) printf '%s\n' '{"status":"success","data":{"unread":0}}' ;;
          *) exit 3 ;;
        esac
        """#)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let state = AppState(cli: EmailCLI(binaryPath: fixture.executable.path))
        state.session.accounts = [Self.account(email: "a@example.com")]
        state.session.currentAccount = state.session.accounts.first
        await state.markAllRead()
        let marks = try String(contentsOfFile: fixture.executable.path + ".marks", encoding: .utf8)
        for id in [10, 11, 20, 30, 40] {
            #expect(marks.contains("--read \(id) --json"))
        }
        #expect(state.inbox.error == nil)
    }

    @Test("Starred includes snoozed messages without duplicates")
    func starredIncludesSnoozed() {
        let inbox = InboxState()
        var message = Self.message(id: 7, account: "me@example.com", subject: "Star", createdAt: "2026-09-16T10:00:00Z")
        message.starred = true
        inbox.messages = [message]
        inbox.snoozedMessages = [message]
        inbox.currentFolder = .starred
        #expect(inbox.visible().map(\.id) == [7])
        inbox.messages = []
        #expect(inbox.visible().map(\.id) == [7])
    }

    private static let accountScopedScript = #"""
    args=" $* "
    account="b@example.com"
    case "$args" in
      *" --account a@example.com "*) account="a@example.com"; sleep 0.25 ;;
    esac

    case "$args" in
      *" inbox list "*)
        case "$args" in
          *" --archived "*|*" --snoozed "*)
            printf '%s\n' '{"status":"success","data":{"messages":[],"has_more":false,"next_cursor":null}}'
            ;;
          *)
            if [ "$account" = "a@example.com" ]; then id=101; else id=202; fi
            printf '{"status":"success","data":{"messages":[{"id":%s,"direction":"received","account_email":"%s","from_addr":"person@example.com","subject":"Inbox","created_at":"2026-09-16T10:00:00Z"}],"has_more":false,"next_cursor":null}}\n' "$id" "$account"
            ;;
        esac
        ;;
      *" inbox stats "*)
        printf '%s\n' '{"status":"success","data":{"unread":1}}'
        ;;
      *" draft list "*)
        printf '%s\n' '{"status":"success","data":[]}'
        ;;
      *" inbox search "*)
        if [ "$account" = "a@example.com" ]; then id=111; else id=222; fi
        printf '{"status":"success","data":[{"id":%s,"direction":"received","account_email":"%s","from_addr":"search@example.com","subject":"Needle","created_at":"2026-09-16T11:00:00Z"}]}\n' "$id" "$account"
        ;;
      *)
        printf '%s\n' '{"status":"success","data":{}}'
        ;;
    esac
    """#

    private static func makeExecutableScript(body: String) throws -> (
        directory: URL,
        executable: URL,
        arguments: URL
    ) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MinimailClientTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("email-cli-fixture")
        let source = "#!/bin/sh\nset -eu\n\(body)\n"
        try source.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return (directory, executable, URL(fileURLWithPath: executable.path + ".args"))
    }

    private static func adjacentValue(for flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), args.indices.contains(index + 1) else { return nil }
        return args[index + 1]
    }

    private static func recordedArguments(from url: URL) throws -> [String] {
        var arguments = try String(contentsOf: url, encoding: .utf8)
            .components(separatedBy: .newlines)
        // The fixture writes one trailing newline. Remove only that terminator
        // while preserving an intentional empty argument such as
        // `--reply-to ""` in the middle of the invocation.
        if arguments.last == "" { arguments.removeLast() }
        return arguments
    }

    private static func account(email: String) -> Account {
        Account(
            email: email,
            profile_name: "local",
            display_name: nil,
            is_default: false,
            signature: ""
        )
    }

    private static func pendingSend(from: String) -> PendingSend {
        PendingSend(
            from: from,
            to: ["recipient@example.com"],
            cc: [],
            bcc: [],
            replyTo: [],
            subject: "Unfinished delivery",
            text: "Body",
            html: nil,
            attachments: [],
            replyToMessageID: nil,
            scheduledAt: nil,
            originalDraftID: nil,
            queuedAt: Date(),
            deadline: Date().addingTimeInterval(10)
        )
    }

    private static func message(
        id: Int64,
        account: String,
        subject: String,
        createdAt: String
    ) -> Message {
        Message(
            id: id,
            remote_id: nil,
            direction: "received",
            account_email: account,
            from_addr: "person@example.com",
            to: [account],
            cc: [],
            bcc: [],
            reply_to: [],
            subject: subject,
            text_body: nil,
            html_body: nil,
            rfc_message_id: nil,
            in_reply_to: nil,
            references: [],
            last_event: "received",
            is_read: false,
            created_at: createdAt,
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
