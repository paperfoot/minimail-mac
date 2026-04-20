import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var bound = state
        ZStack(alignment: .bottom) {
            backgroundLayer.ignoresSafeArea()

            Group {
                switch state.router.currentView {
                case .inbox:
                    InboxView()
                        .transition(.asymmetric(
                            insertion: .move(edge: .leading).combined(with: .opacity),
                            removal: .move(edge: .leading).combined(with: .opacity)
                        ))
                case .reader(let id):
                    ReaderView(messageID: id)
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .trailing).combined(with: .opacity)
                        ))
                case .compose:
                    ComposeView()
                        .transition(.asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .move(edge: .bottom).combined(with: .opacity)
                        ))
                case .accountSwitcher:
                    AccountSwitcherView()
                        .transition(.move(edge: .top).combined(with: .opacity))
                case .settings:
                    SettingsView()
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                case .needsInstall:
                    NeedsInstallView()
                case .onboarding:
                    OnboardingView()
                }
            }

            if state.pendingSend != nil {
                UndoSendToast()
                    .padding(.bottom, 12)
                    .padding(.horizontal, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let status = state.transientStatus {
                TransientStatusToast(status: status)
                    .padding(.bottom, 12)
                    .padding(.horizontal, 16)
                    .transition(.opacity)
            }
        }
        .frame(width: 420, height: 580)
        .clipped()
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: state.router.currentView)
        .animation(.spring(response: 0.25, dampingFraction: 0.9), value: state.pendingSend == nil)
        .animation(.easeOut(duration: 0.2), value: state.transientStatus)
        // ⌘/ shows the keyboard help sheet. We require ⌘ because a bare `?`
        // global shortcut would swallow typed `?` / `/` in every text field
        // (search box, compose body, subject, etc.).  ⌘/ matches Gmail's
        // keyboard-help conventions on web too.
        .background(
            Button("") { state.showKeyboardHelp = true }
                .keyboardShortcut("/", modifiers: .command)
                .opacity(0)
                .allowsHitTesting(false)
        )
        .sheet(isPresented: $bound.showKeyboardHelp) {
            KeyboardHelpView(isPresented: $bound.showKeyboardHelp)
        }
        // Account quick-switcher: ⌘1 … ⌘9 activates accounts in display
        // order. Invisible buttons hijack the shortcuts without stealing
        // focus or adding visible UI.
        .background(accountQuickSwitcherShortcuts)
    }

    @ViewBuilder
    private var accountQuickSwitcherShortcuts: some View {
        ZStack {
            ForEach(1...9, id: \.self) { n in
                Button("") {
                    Task { await state.selectAccount(at: n) }
                }
                .keyboardShortcut(KeyEquivalent(Character(String(n))), modifiers: .command)
                .opacity(0)
                .allowsHitTesting(false)
            }
        }
    }

    private var backgroundLayer: some View {
        Color.clear.containerBackground(.thinMaterial, for: .window)
    }
}

struct NeedsInstallView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "terminal.fill").font(.system(size: 40)).opacity(0.5)
            Text("email-cli not found").font(.headline)
            Text("Install the CLI that powers Minimail:")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text("brew install paperfoot/tap/email-cli")
                .font(.system(.callout, design: .monospaced))
                .padding(8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            Text("Then open Minimail again.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct OnboardingView: View {
    @Environment(AppState.self) private var state
    @State private var apiKey: String = ""
    @State private var email: String = ""
    @State private var inFlight: Bool = false
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "envelope.open.fill")
                .font(.system(size: 44))
                .foregroundStyle(Color.accentColor)
            Text("Welcome to Minimail")
                .font(.headline)
            Text("Paste your Resend API key and the email address you'll send from.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                field(label: "API key", hint: "re_...") {
                    SecureField("", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }
                field(label: "From address", hint: "you@yourdomain.com") {
                    TextField("", text: $email)
                        .textFieldStyle(.roundedBorder)
                }
            }
            .padding(.horizontal, 20)

            if let err = errorText {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }

            Button {
                Task { await createAccount() }
            } label: {
                if inFlight {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Text("Create Account")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(inFlight || apiKey.isEmpty || !email.looksLikeEmail)

            Text("You can add more accounts later from Settings.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)

            Link("Need an API key? Create one on Resend →",
                 destination: URL(string: "https://resend.com/api-keys")!)
                .font(.system(size: 11))
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func field<Content: View>(label: String, hint: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content()
            Text(hint)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
    }

    private func createAccount() async {
        inFlight = true
        defer { inFlight = false }
        errorText = nil
        let profileName = "default"
        do {
            // Profile creation is idempotent on the CLI (ON CONFLICT UPDATE).
            try await EmailCLI.shared.addProfile(name: profileName, apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
            try await EmailCLI.shared.addAccount(
                email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                profile: profileName,
                makeDefault: true
            )
            // Bootstrap re-reads accounts and flips the view back to the
            // inbox automatically if at least one account is present now.
            await state.bootstrap()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

/// Liquid-glass capsule toast shown at the bottom of the popover while a
/// send is queued behind the undo window. Live countdown + Undo button.
/// Tapping "Send now" skips the remaining delay.
struct UndoSendToast: View {
    @Environment(AppState.self) private var state

    var body: some View {
        if let pending = state.pendingSend {
            HStack(spacing: 10) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.accentColor)
                TimelineView(.periodic(from: .now, by: 0.25)) { context in
                    let remaining = max(0, Int(pending.deadline.timeIntervalSince(context.date).rounded(.up)))
                    Text("Sending in \(remaining)s")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                }
                Spacer()
                Button("Undo") { state.undoPendingSend() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                Button {
                    Task { await state.flushPendingSendNow() }
                } label: {
                    Text("Send now")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .glassToastBackground()
        }
    }
}

/// Liquid-glass confirmation toast that adapts to whatever just happened.
/// Archive includes an inline Undo button; other actions are status-only.
struct TransientStatusToast: View {
    @Environment(AppState.self) private var state
    let status: TransientStatus

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
            Spacer()
            if case .archived = status {
                Button("Undo") {
                    Task { await state.undoLastArchive() }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(Color.accentColor.opacity(0.15), in: Capsule())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassToastBackground()
    }

    private var iconName: String {
        switch status {
        case .sent: return "checkmark.circle.fill"
        case .archived: return "archivebox.fill"
        case .deleted: return "trash.fill"
        case .info: return "info.circle.fill"
        }
    }
    private var iconColor: Color {
        switch status {
        case .sent: return .green
        case .deleted: return .red
        default: return Color.accentColor
        }
    }
    private var message: String {
        switch status {
        case .sent: return "Sent"
        case .archived(let ids, _): return ids.count == 1 ? "Archived" : "Archived \(ids.count)"
        case .deleted(let count): return count == 1 ? "Deleted" : "Deleted \(count)"
        case .info(let text): return text
        }
    }
}

/// Liquid Glass capsule for in-popover toasts. System handles edge effects,
/// so no custom shadow or stroke border — per Apple's Liquid Glass HIG.
extension View {
    func glassToastBackground() -> some View {
        self.glassEffect(.regular, in: .capsule)
    }
}
