import Foundation

/// Thin wrapper around the `email-cli` binary. Everything goes through here.
actor EmailCLI {
    static let shared = EmailCLI()

    enum CLIError: Error, LocalizedError {
        case notFound
        case nonZeroExit(code: Int32, stderr: String)
        case decode(Error)
        case envelopeError(String)
        case rateLimited(String)
        case configError(String)
        case badInput(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .notFound:
                return "email-cli not found in PATH. Install via: brew install paperfoot/tap/email-cli"
            case .nonZeroExit(let code, let stderr):
                return "email-cli exited with \(code): \(stderr.prefix(400))"
            case .decode(let err):
                return "failed to decode email-cli output: \(err.localizedDescription)"
            case .envelopeError(let msg):
                return msg
            case .rateLimited(let msg):
                return "Rate limited: \(msg)"
            case .configError(let msg):
                return "Configuration error: \(msg)"
            case .badInput(let msg):
                return "Bad input: \(msg)"
            case .cancelled:
                return "Cancelled"
            }
        }
    }

    /// Map email-cli's semantic exit codes (agent-info documents them).
    private static func mapExit(_ code: Int32, stderr: String) -> CLIError {
        switch code {
        case 2: return .configError(stderr)
        case 3: return .badInput(stderr)
        case 4: return .rateLimited(stderr)
        default: return .nonZeroExit(code: code, stderr: stderr)
        }
    }

    private var binaryPath: String?

    /// Called once at startup. Resolves the binary path; nil means not installed.
    /// Priority: bundled inside the .app, then Homebrew, then Cargo, then PATH.
    func locate() async -> String? {
        if let cached = binaryPath { return cached }

        // 1) Bundled helper — shipped inside Minimail.app/Contents/MacOS
        // (Apple Bundle Programming Guide: auxiliary executables live in
        // Contents/MacOS, not Contents/Resources, and url(forAuxiliaryExecutable:)
        // is the matching lookup API).
        if let bundleURL = Bundle.main.url(forAuxiliaryExecutable: "email-cli"),
           FileManager.default.isExecutableFile(atPath: bundleURL.path) {
            binaryPath = bundleURL.path
            return bundleURL.path
        }

        // 2) Common system install locations.
        let candidates = [
            "/opt/homebrew/bin/email-cli",
            "/usr/local/bin/email-cli",
            "\(NSHomeDirectory())/.cargo/bin/email-cli",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            binaryPath = path
            return path
        }

        // 3) `which email-cli` via env.
        if let resolved = try? await runPlain("/usr/bin/which", ["email-cli"]),
           !resolved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let path = resolved.trimmingCharacters(in: .whitespacesAndNewlines)
            binaryPath = path
            return path
        }
        return nil
    }

    // ── High-level calls ───────────────────────────────────────────────────

    func listAccounts() async throws -> [Account] {
        try await runJSON(args: ["account", "list", "--json"], as: [Account].self)
    }

    /// Create a profile (Resend API key container) via the CLI.
    ///
    /// The API key is passed through the child process's environment, not
    /// via argv. `ps aux` and the `/proc`/kernel audit trail on many UNIX
    /// systems make argv world-readable, so putting the Resend key there
    /// leaked it to every other user on the machine (and to tools like
    /// `lsof -p` that snapshot command lines). The CLI's `--api-key-env`
    /// flag reads the key from whatever variable name we pass; the key
    /// itself lives only in the child's environment block, which macOS
    /// restricts to the same user's processes.
    func addProfile(name: String, apiKey: String) async throws {
        let envName = "MINIMAIL_RESEND_API_KEY"
        let args = ["profile", "add", name, "--api-key-env", envName, "--json"]
        _ = try await runRaw(args: args, env: [envName: apiKey])
    }

    /// Register a mailbox (email + profile) with optional default flag.
    func addAccount(email: String, profile: String, makeDefault: Bool = false) async throws {
        var args = ["account", "add", email, "--profile", profile, "--json"]
        if makeDefault { args += ["--default"] }
        _ = try await runRaw(args: args)
    }

    func listInbox(
        account: String?,
        archived: Bool = false,
        starred: Bool = false,
        snoozed: Bool = false,
        limit: Int = 50
    ) async throws -> [Message] {
        var args = ["inbox", "list", "--json", "--limit", String(limit)]
        if let account { args += ["--account", account] }
        if archived { args += ["--archived"] }
        if starred { args += ["--starred"] }
        if snoozed { args += ["--snoozed"] }
        let resp = try await runJSON(args: args, as: InboxListResponse.self)
        return resp.messages ?? []
    }

    func readMessage(id: Int64, markRead: Bool = false) async throws -> Message {
        let args = ["inbox", "read", String(id), "--json", "--mark-read", markRead ? "true" : "false"]
        return try await runJSON(args: args, as: Message.self)
    }

    /// Fetch every message that shares a thread with the given seed. CLI
    /// walks `rfc_message_id` / `in_reply_to` / `references` on its end; we
    /// just render the chronological list. Returns `[seed]` if no relatives.
    func readThread(id: Int64) async throws -> [Message] {
        let args = ["inbox", "thread", String(id), "--json"]
        return try await runJSON(args: args, as: [Message].self)
    }

    func markRead(ids: [Int64]) async throws {
        var args = ["inbox", "mark", "--read"]
        args += ids.map(String.init)
        _ = try await runRaw(args: args + ["--json"])
    }

    func archive(ids: [Int64]) async throws {
        var args = ["inbox", "archive"]
        args += ids.map(String.init)
        _ = try await runRaw(args: args + ["--json"])
    }

    func unarchive(ids: [Int64]) async throws {
        var args = ["inbox", "unarchive"]
        args += ids.map(String.init)
        _ = try await runRaw(args: args + ["--json"])
    }

    func stats(account: String?) async throws -> Stats {
        var args = ["inbox", "stats", "--json"]
        if let account { args += ["--account", account] }
        return try await runJSON(args: args, as: Stats.self)
    }

    func send(
        from: String?,
        to: [String],
        cc: [String],
        bcc: [String],
        subject: String,
        text: String?,
        html: String?,
        attachments: [URL] = [],
        replyToMessageID: Int64? = nil
    ) async throws {
        var args = ["send", "--json"]
        if let from { args += ["--from", from] }
        for t in to { args += ["--to", t] }
        for c in cc { args += ["--cc", c] }
        for b in bcc { args += ["--bcc", b] }
        args += ["--subject", subject]
        if let text { args += ["--text", text] }
        if let html { args += ["--html", html] }
        for url in attachments { args += ["--attach", url.path] }
        if let replyToMessageID { args += ["--reply-to-msg", String(replyToMessageID)] }
        _ = try await runRaw(args: args)
    }

    // ── New actions wired for future features ─────────────────────────────

    func reply(
        to id: Int64,
        all: Bool,
        from: String?,
        cc: [String],
        bcc: [String],
        text: String?,
        html: String?
    ) async throws {
        var args = ["reply", String(id), "--json"]
        if let from { args += ["--from", from] }
        if all { args += ["--all"] }
        for c in cc { args += ["--cc", c] }
        for b in bcc { args += ["--bcc", b] }
        if let text { args += ["--text", text] }
        if let html { args += ["--html", html] }
        _ = try await runRaw(args: args)
    }

    func forward(
        _ id: Int64,
        from: String?,
        to: [String],
        cc: [String],
        text: String?
    ) async throws {
        var args = ["forward", String(id), "--json"]
        if let from { args += ["--from", from] }
        for t in to { args += ["--to", t] }
        for c in cc { args += ["--cc", c] }
        if let text { args += ["--text", text] }
        _ = try await runRaw(args: args)
    }

    func markUnread(ids: [Int64]) async throws {
        var args = ["inbox", "mark", "--unread"]
        args += ids.map(String.init)
        _ = try await runRaw(args: args + ["--json"])
    }

    func delete(ids: [Int64]) async throws {
        var args = ["inbox", "delete"]
        args += ids.map(String.init)
        _ = try await runRaw(args: args + ["--json"])
    }

    func listAttachments(messageID: Int64) async throws -> [Attachment] {
        try await runJSON(args: ["attachments", "list", String(messageID), "--json"], as: [Attachment].self)
    }

    func downloadAttachment(messageID: Int64, attachmentID: String, to path: URL) async throws {
        let args = ["attachments", "get", String(messageID), attachmentID, "--output", path.path, "--json"]
        _ = try await runRaw(args: args)
    }

    /// Eagerly download bytes for every attachment that doesn't yet have a
    /// local copy. Resend's signed URLs expire and sometimes arrive as null
    /// in the webhook payload — without this, attachments can silently become
    /// unretrievable. Fire-and-forget after every sync.
    func prefetchAttachments(account: String?) async throws {
        var args = ["attachments", "prefetch", "--json"]
        if let account { args += ["--account", account] }
        _ = try await runRaw(args: args)
    }

    func listDrafts(account: String?) async throws -> [Draft] {
        var args = ["draft", "list", "--json"]
        if let account { args += ["--account", account] }
        return try await runJSON(args: args, as: [Draft].self)
    }

    func createDraft(account: String?, to: [String], cc: [String], bcc: [String], subject: String, text: String?, html: String? = nil, attachments: [URL] = [], replyToMessageID: Int64? = nil) async throws -> Draft {
        var args = ["draft", "create", "--json"]
        if let account { args += ["--account", account] }
        for t in to { args += ["--to", t] }
        for c in cc { args += ["--cc", c] }
        for b in bcc { args += ["--bcc", b] }
        args += ["--subject", subject]
        if let text { args += ["--text", text] }
        if let html { args += ["--html", html] }
        for url in attachments { args += ["--attach", url.path] }
        if let replyToMessageID { args += ["--reply-to-msg", String(replyToMessageID)] }
        return try await runJSON(args: args, as: Draft.self)
    }

    /// Edit a draft row by id. The Rust `draft edit` command's attachment
    /// semantics are three-state:
    ///   - any `--attach <path>` arguments REPLACE the stored list wholesale
    ///     (Rust re-snapshots each path into the draft sandbox)
    ///   - `--clear-attachments` drops every attachment without adding any
    ///   - omitting both leaves the stored list untouched
    /// We map `attachments == nil` to "don't touch" (omit both flags) and
    /// `attachments == []` to "clear" (pass `--clear-attachments`). A non-empty
    /// array always replaces. This preserves the Rust contract.
    func editDraft(
        id: String,
        to: [String]?,
        cc: [String]?,
        bcc: [String]?,
        subject: String?,
        text: String?,
        html: String? = nil,
        attachments: [URL]? = nil
    ) async throws {
        var args = ["draft", "edit", id, "--json"]
        if let subject { args += ["--subject", subject] }
        if let text { args += ["--text", text] }
        if let html { args += ["--html", html] }
        if let to { for t in to { args += ["--to", t] } }
        if let cc { for c in cc { args += ["--cc", c] } }
        if let bcc { for b in bcc { args += ["--bcc", b] } }
        if let attachments {
            if attachments.isEmpty {
                args += ["--clear-attachments"]
            } else {
                for url in attachments { args += ["--attach", url.path] }
            }
        }
        _ = try await runRaw(args: args)
    }

    func deleteDraft(id: String) async throws {
        _ = try await runRaw(args: ["draft", "delete", id, "--json"])
    }

    func signature(for account: String) async throws -> String? {
        let raw = try await runRaw(args: ["signature", "show", account, "--json"])
        let env = try JSONDecoder().decode(Envelope<SignatureResponse>.self, from: raw)
        return env.data?.signature
    }

    func setSignature(_ text: String, for account: String) async throws {
        _ = try await runRaw(args: ["signature", "set", account, "--text", text, "--json"])
    }

    func setDefaultAccount(_ email: String) async throws {
        _ = try await runRaw(args: ["account", "use", email, "--json"])
    }

    func sync(account: String?) async throws {
        var args = ["sync", "--json"]
        if let account { args += ["--account", account] }
        _ = try await runRaw(args: args)
    }

    func star(ids: [Int64]) async throws {
        var args = ["inbox", "star"]; args += ids.map(String.init)
        _ = try await runRaw(args: args + ["--json"])
    }

    func unstar(ids: [Int64]) async throws {
        var args = ["inbox", "unstar"]; args += ids.map(String.init)
        _ = try await runRaw(args: args + ["--json"])
    }

    /// Snooze one or more messages until the given wake time. `until` accepts
    /// the CLI's keyword grammar ("tomorrow", "4h", "next-week") or an ISO
    /// timestamp — documented in `email-cli inbox snooze --help`.
    func snooze(ids: [Int64], until: String) async throws {
        var args = ["inbox", "snooze"]; args += ids.map(String.init)
        args += ["--until", until, "--json"]
        _ = try await runRaw(args: args)
    }

    func unsnooze(ids: [Int64]) async throws {
        var args = ["inbox", "unsnooze"]; args += ids.map(String.init)
        _ = try await runRaw(args: args + ["--json"])
    }

    /// Resolve the List-Unsubscribe header on a message into a URL (or
    /// mailto:) the UI can open in the user's browser.
    func unsubscribeURL(messageID: Int64) async throws -> String {
        let raw = try await runRaw(args: ["inbox", "unsubscribe", String(messageID), "--json"])
        let env = try JSONDecoder().decode(Envelope<UnsubscribeResponse>.self, from: raw)
        guard let payload = env.data else {
            throw CLIError.envelopeError("no unsubscribe link on message \(messageID)")
        }
        return payload.url
    }

    /// Gmail-style search with optional filters. `query` is the free-text
    /// part; the rest map to named flags on `inbox search`.
    func search(
        query: String,
        account: String?,
        from: String? = nil,
        to: String? = nil,
        subject: String? = nil,
        hasAttachment: Bool = false,
        unread: Bool = false,
        starred: Bool = false,
        limit: Int = 50
    ) async throws -> [Message] {
        var args = ["inbox", "search", query, "--json", "--limit", String(limit)]
        if let account { args += ["--account", account] }
        if let from { args += ["--from", from] }
        if let to { args += ["--to", to] }
        if let subject { args += ["--subject", subject] }
        if hasAttachment { args += ["--has-attachment"] }
        if unread { args += ["--unread"] }
        if starred { args += ["--starred"] }
        return try await runJSON(args: args, as: [Message].self)
    }

    // ── Process plumbing ───────────────────────────────────────────────────

    private func runJSON<T: Decodable & Sendable>(args: [String], as type: T.Type) async throws -> T {
        let raw = try await runRaw(args: args)
        let decoder = JSONDecoder()
        do {
            let envelope = try decoder.decode(Envelope<T>.self, from: raw)
            if envelope.status == "success", let payload = envelope.data {
                return payload
            }
            if let err = envelope.error {
                throw CLIError.envelopeError(err.message ?? "email-cli error (\(err.code ?? "?"))")
            }
            throw CLIError.envelopeError("empty envelope")
        } catch let decodeError where !(decodeError is CLIError) {
            throw CLIError.decode(decodeError)
        }
    }

    private func runRaw(args: [String], env: [String: String]? = nil) async throws -> Data {
        guard let bin = await locate() else { throw CLIError.notFound }
        return try await runPlainData(bin, args, env: env)
    }

    /// Launches a subprocess, drains stdout + stderr *while the child runs* so
    /// large payloads can't deadlock on pipe buffer exhaustion. Cancellation
    /// from Swift Task cancel sends SIGTERM to the child.
    ///
    /// `env` values are *added to* the parent's environment — not replacing
    /// it — so the child still sees $PATH, $HOME, etc. We merge rather than
    /// overwrite so the Resend API key can be passed via env (keeping it out
    /// of argv) without breaking everything else the CLI expects from its
    /// ambient environment.
    private func runPlainData(_ binary: String, _ args: [String], env: [String: String]? = nil) async throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = args
        if let env, !env.isEmpty {
            var merged = ProcessInfo.processInfo.environment
            for (k, v) in env { merged[k] = v }
            process.environment = merged
        }
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutCollector = AsyncDataCollector(pipe: stdoutPipe)
        let stderrCollector = AsyncDataCollector(pipe: stderrPipe)

        try process.run()

        return try await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                process.terminationHandler = { _ in cont.resume() }
            }
            let stdoutData = await stdoutCollector.finish()
            let stderrData = await stderrCollector.finish()
            let code = process.terminationStatus
            if code == 0 {
                return stdoutData
            }
            let stderr = String(data: stderrData, encoding: .utf8) ?? ""
            throw Self.mapExit(code, stderr: stderr)
        } onCancel: {
            // Task cancelled — terminate the child cleanly.
            if process.isRunning {
                process.terminate()
            }
        }
    }

    /// Streams one pipe's bytes in the background while the child runs. Keeping
    /// the pipe drained prevents SIGPIPE / deadlock on bodies >64KB.
    private final class AsyncDataCollector: @unchecked Sendable {
        private let pipe: Pipe
        private let queue = DispatchQueue(label: "minimail.pipe-drain")
        private var buffer = Data()
        private var done = false
        private var waiter: CheckedContinuation<Data, Never>?

        init(pipe: Pipe) {
            self.pipe = pipe
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                guard let self else { return }
                let chunk = handle.availableData
                if chunk.isEmpty {
                    // EOF
                    handle.readabilityHandler = nil
                    self.queue.async {
                        self.done = true
                        self.waiter?.resume(returning: self.buffer)
                        self.waiter = nil
                    }
                } else {
                    self.queue.async {
                        self.buffer.append(chunk)
                    }
                }
            }
        }

        func finish() async -> Data {
            await withCheckedContinuation { (cont: CheckedContinuation<Data, Never>) in
                queue.async {
                    if self.done {
                        cont.resume(returning: self.buffer)
                    } else {
                        self.waiter = cont
                    }
                }
            }
        }
    }

    private func runPlain(_ binary: String, _ args: [String]) async throws -> String {
        let data = try await runPlainData(binary, args)
        return String(data: data, encoding: .utf8) ?? ""
    }
}
