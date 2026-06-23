import AppKit

/// Gate for opening URLs that originate from untrusted email content — rendered
/// HTML link clicks and `List-Unsubscribe` headers. A sender-controlled href
/// such as `file://`, `smb://`, `x-apple.systempreferences:` or any custom
/// scheme is a one-click cross-app / local-file / deep-link launch primitive,
/// so external opens are restricted to the web + mail schemes a mail client
/// legitimately needs. Every untrusted-content open routes through here.
enum ExternalLink {
    static let allowedSchemes: Set<String> = ["http", "https", "mailto"]

    static func isAllowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return allowedSchemes.contains(scheme)
    }

    /// Open `url` in the user's default handler only when its scheme is in the
    /// allowlist. Returns whether it was opened so callers can surface a
    /// "blocked link" message instead of silently doing nothing.
    @discardableResult
    @MainActor
    static func open(_ url: URL) -> Bool {
        guard isAllowed(url) else {
            Log.cli.error("blocked external link with disallowed scheme: \(url.scheme ?? "nil", privacy: .public)")
            return false
        }
        NSWorkspace.shared.open(url)
        return true
    }
}
