import SwiftUI

/// Inbox error banner. Renders a case-specific icon, message, and CTA
/// for every `ActionableError` variant so the user always has a next
/// step — retry, open settings, or just dismiss.
struct ErrorBanner: View {
    @Environment(AppState.self) private var state
    let error: ActionableError

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            if let action {
                Button(action.title) { action.perform() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(tint.opacity(0.15), in: Capsule())
            }

            Button {
                state.inbox.error = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss error")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(tint.opacity(0.1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(subtitle).")
    }

    // MARK: - Per-case presentation

    private var icon: String {
        switch error {
        case .network: return "wifi.slash"
        case .invalidAPIKey: return "key.fill"
        case .rateLimited: return "hourglass"
        case .cliMissing: return "terminal.fill"
        case .diskFull: return "externaldrive.badge.exclamationmark"
        case .fileNotFound: return "doc.questionmark"
        case .permissionDenied: return "lock.fill"
        case .other: return "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch error {
        case .network: return .gray
        case .invalidAPIKey: return .red
        case .rateLimited: return .yellow
        case .cliMissing: return .blue
        case .diskFull, .permissionDenied: return .red
        case .fileNotFound: return .orange
        case .other: return .orange
        }
    }

    private var title: String {
        switch error {
        case .network: return "Offline"
        case .invalidAPIKey: return "API key isn't working"
        case .rateLimited(_, let retry):
            if let retry, retry > 0 {
                return "Rate-limited. Retrying in \(Int(retry))s"
            }
            return "Rate-limited"
        case .cliMissing: return "email-cli unavailable"
        case .diskFull: return "Disk is full"
        case .fileNotFound: return "File not found"
        case .permissionDenied: return "Permission denied"
        case .other: return "Something went wrong"
        }
    }

    private var subtitle: String {
        switch error {
        case .network:
            return "Showing cached messages. Connection will auto-resume."
        case .invalidAPIKey:
            return "Open Settings to re-enter your Resend key."
        case .rateLimited:
            return "Resend briefly throttled the request. We'll retry automatically."
        case .cliMissing:
            return "Reinstall Minimail or install email-cli manually."
        case .diskFull:
            return "Free up space on the destination drive and retry."
        case .fileNotFound:
            return "The file may have been moved, deleted, or its volume unmounted."
        case .permissionDenied:
            return "Pick a folder you can write to (Desktop, Documents, or Downloads)."
        case .other(let msg):
            return msg
        }
    }

    private struct BannerAction {
        let title: String
        let perform: () -> Void
    }

    private var action: BannerAction? {
        switch error {
        case .network:
            return BannerAction(title: "Retry") {
                Task { await state.refreshInbox() }
            }
        case .invalidAPIKey:
            return BannerAction(title: "Settings") {
                state.router.currentView = .settings
            }
        case .rateLimited:
            return BannerAction(title: "Retry") {
                Task { await state.refreshInbox() }
            }
        // Filesystem + CLI-missing errors: no in-banner retry — the user
        // needs to fix something outside the app first (free disk, pick
        // a different folder, install the CLI).
        case .cliMissing, .diskFull, .fileNotFound, .permissionDenied, .other:
            return nil
        }
    }
}
