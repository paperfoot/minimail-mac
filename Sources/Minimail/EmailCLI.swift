import Foundation

/// Thin wrapper around the `email-cli` binary. Everything goes through here.
actor EmailCLI {
    static let shared = EmailCLI()

    enum CLIError: Error, LocalizedError {
        case notFound
        case nonZeroExit(code: Int32, stderr: String)
        case decode(Error)
        case envelopeError(String)

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
            }
        }
    }

    private var binaryPath: String?

    /// Called once at startup. Resolves the binary path; nil means not installed.
    func locate() async -> String? {
        if let cached = binaryPath { return cached }
        // Common install locations, in order of likelihood.
        let candidates = [
            "/opt/homebrew/bin/email-cli",
            "/usr/local/bin/email-cli",
            "\(NSHomeDirectory())/.cargo/bin/email-cli",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            binaryPath = path
            return path
        }
        // Fallback: `which email-cli` via env.
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

    func listInbox(account: String?, limit: Int = 50) async throws -> [Message] {
        var args = ["inbox", "list", "--json", "--limit", String(limit)]
        if let account { args += ["--account", account] }
        // The inbox list endpoint returns either a bare array or a paginated
        // { messages, has_more, next_cursor } shape depending on flags.
        let data = try await runRaw(args: args)
        let decoder = JSONDecoder()
        // Try envelope-with-paginated first, then envelope-with-array.
        if let paginated = try? decoder.decode(Envelope<InboxListResponse>.self, from: data),
           paginated.status == "success",
           let msgs = paginated.data?.messages {
            return msgs
        }
        if let arr = try? decoder.decode(Envelope<[Message]>.self, from: data),
           arr.status == "success",
           let msgs = arr.data {
            return msgs
        }
        throw CLIError.envelopeError("unexpected inbox list shape")
    }

    func readMessage(id: Int64) async throws -> Message {
        try await runJSON(args: ["inbox", "read", String(id), "--json", "--no-mark-read"], as: Message.self)
    }

    func markRead(ids: [Int64]) async throws {
        var args = ["inbox", "mark", "--read"]
        args += ids.map(String.init)
        _ = try await runRaw(args: args + ["--json"])
    }

    func stats(account: String?) async throws -> Stats {
        var args = ["inbox", "stats", "--json"]
        if let account { args += ["--account", account] }
        return try await runJSON(args: args, as: Stats.self)
    }

    func send(from: String?, to: [String], cc: [String], bcc: [String], subject: String, text: String?, html: String?) async throws {
        var args = ["send", "--json"]
        if let from { args += ["--from", from] }
        for t in to { args += ["--to", t] }
        for c in cc { args += ["--cc", c] }
        for b in bcc { args += ["--bcc", b] }
        args += ["--subject", subject]
        if let text { args += ["--text", text] }
        if let html { args += ["--html", html] }
        _ = try await runRaw(args: args)
    }

    func sync(account: String?) async throws {
        var args = ["sync", "--json"]
        if let account { args += ["--account", account] }
        _ = try await runRaw(args: args)
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

    private func runRaw(args: [String]) async throws -> Data {
        guard let bin = await locate() else { throw CLIError.notFound }
        return try await runPlainData(bin, args)
    }

    /// Launches a subprocess, collects stdout, returns Data. Uses Process under
    /// the hood (Subprocess is still maturing). Cancellation sends SIGTERM.
    private func runPlainData(_ binary: String, _ args: [String]) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = args
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            process.terminationHandler = { proc in
                let stdout = (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data()
                let stderr = String(
                    data: (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data(),
                    encoding: .utf8
                ) ?? ""
                if proc.terminationStatus == 0 {
                    cont.resume(returning: stdout)
                } else {
                    cont.resume(throwing: CLIError.nonZeroExit(code: proc.terminationStatus, stderr: stderr))
                }
            }

            do {
                try process.run()
            } catch {
                cont.resume(throwing: error)
            }
        }
    }

    private func runPlain(_ binary: String, _ args: [String]) async throws -> String {
        let data = try await runPlainData(binary, args)
        return String(data: data, encoding: .utf8) ?? ""
    }
}
