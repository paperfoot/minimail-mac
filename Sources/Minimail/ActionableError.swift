import Foundation

/// A CLI or network error, classified into something the UI can act on.
///
/// The generic `other` case preserves the original message for the final
/// fallback banner. The specific cases drive different UI affordances:
/// a Retry button for `network`, an "Open Settings" button for
/// `invalidAPIKey`, a countdown for `rateLimited`.
enum ActionableError: Equatable, Sendable {
    /// Connection / DNS / TLS failure. The CLI couldn't reach Resend.
    case network(String)

    /// Resend returned 401/403. The user's API key is wrong or revoked.
    case invalidAPIKey(profile: String?, detail: String)

    /// Resend returned 429. Offer a countdown + retry.
    case rateLimited(detail: String, retryAfter: TimeInterval?)

    /// email-cli binary isn't installed / not in PATH.
    case cliMissing

    /// Destination volume is full. Common on the attachment-download path
    /// when the user picks a save location on an external drive that's out
    /// of space.
    case diskFull

    /// Referenced file isn't on disk. Surfaces from attachment-download
    /// (destination parent missing) and draft autosave (user added a file
    /// that later got trashed or the volume ejected).
    case fileNotFound

    /// macOS denied write/read to the path. Often the user picked a
    /// sandboxed location (iCloud Drive page with upload-in-progress,
    /// another app's container) or a read-only mount.
    case permissionDenied

    /// Any other unclassified error. Show the message verbatim.
    case other(String)

    var message: String {
        switch self {
        case .network(let s): return s
        case .invalidAPIKey(_, let s): return s
        case .rateLimited(let s, _): return s
        case .cliMissing: return "email-cli not found."
        case .diskFull: return "The destination disk is full. Pick a different save location and retry."
        case .fileNotFound: return "The file is no longer at its original location."
        case .permissionDenied: return "Can't write to that location. Pick a folder you own."
        case .other(let s): return s
        }
    }
}

extension ActionableError {
    /// Best-effort classifier from any Error, including EmailCLI.CLIError.
    /// Looks at the typed case first, then falls back to substring matches
    /// on stderr / message content. Intentionally permissive — false
    /// positives only degrade UX to the generic banner.
    static func classify(_ error: Error) -> ActionableError {
        if let cli = error as? EmailCLI.CLIError {
            return classifyCLI(cli)
        }
        let msg = error.localizedDescription
        return classifyByMessage(msg) ?? .other(msg)
    }

    private static func classifyCLI(_ error: EmailCLI.CLIError) -> ActionableError {
        switch error {
        case .notFound:
            return .cliMissing
        case .rateLimited(let msg):
            return .rateLimited(detail: msg, retryAfter: parseRetryAfter(msg))
        case .configError(let msg), .badInput(let msg):
            // ConfigError covers "profile not found" / "no api key". Check
            // text for specific auth signals before falling through.
            if let sub = classifyByMessage(msg) { return sub }
            return .other(msg)
        case .envelopeError(let msg):
            if let sub = classifyByMessage(msg) { return sub }
            return .other(msg)
        case .nonZeroExit(_, let stderr):
            if let sub = classifyByMessage(stderr) { return sub }
            return .other(error.errorDescription ?? String(describing: error))
        default:
            return .other(error.errorDescription ?? String(describing: error))
        }
    }

    /// Substring heuristics for messages we see from Resend / reqwest / the
    /// CLI. Order matters: check more-specific tokens before broad ones.
    private static func classifyByMessage(_ raw: String) -> ActionableError? {
        let s = raw.lowercased()

        // Auth — before "401" alone since that's in many logs.
        if s.contains("invalid api key")
            || s.contains("unauthorized")
            || s.contains("invalid_api_key")
            || s.contains(" 401 ")
            || s.contains("401 unauthorized")
            || s.contains("403 forbidden")
            || s.contains("missing_api_key") {
            return .invalidAPIKey(profile: nil, detail: raw)
        }

        if s.contains("429") || s.contains("rate limit") || s.contains("too many requests") {
            return .rateLimited(detail: raw, retryAfter: parseRetryAfter(raw))
        }

        if s.contains("dns error")
            || s.contains("could not resolve")
            || s.contains("connection refused")
            || s.contains("connection reset")
            || s.contains("connect error")
            || s.contains("network is unreachable")
            || s.contains("no such host")
            || s.contains("certificate verify failed")
            || s.contains("tls")
            || s.contains("timed out") {
            return .network(raw)
        }

        // Local filesystem errors — most common on the attachment download
        // path. Surface a human-readable version instead of the raw errno
        // string (which leaks the absolute save-path the user chose).
        if s.contains("no space left on device")
            || s.contains("disk is full")
            || s.contains("enospc") {
            return .diskFull
        }
        if s.contains("no such file or directory")
            || s.contains("file doesn't exist")
            || s.contains("file does not exist")
            || s.contains("enoent") {
            return .fileNotFound
        }
        if s.contains("permission denied")
            || s.contains("operation not permitted")
            || s.contains("eacces") {
            return .permissionDenied
        }

        return nil
    }

    /// Parse `retry-after` seconds from the Resend error body, if present.
    /// Falls back to nil so the UI picks a sane default (e.g. 30s).
    private static func parseRetryAfter(_ raw: String) -> TimeInterval? {
        let patterns = [
            #"retry[- ]after[:=\s]+(\d+)"#,
            #"retry in (\d+)"#,
        ]
        for p in patterns {
            guard let regex = try? NSRegularExpression(pattern: p, options: .caseInsensitive)
            else { continue }
            let ns = raw as NSString
            if let m = regex.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)),
               m.numberOfRanges >= 2,
               let n = Int(ns.substring(with: m.range(at: 1))) {
                return TimeInterval(n)
            }
        }
        return nil
    }
}
