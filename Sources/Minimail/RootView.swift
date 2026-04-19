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
            } else if state.transientStatus == .sent {
                SentFlashToast()
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
        // Global `?` shortcut → show the keyboard help sheet. `shift+/` covers
        // keyboards that can't type `?` without shift. Escape closes it.
        .background(
            Button("") { state.showKeyboardHelp = true }
                .keyboardShortcut("?", modifiers: [])
                .opacity(0)
                .allowsHitTesting(false)
        )
        .background(
            Button("") { state.showKeyboardHelp = true }
                .keyboardShortcut("/", modifiers: [.shift])
                .opacity(0)
                .allowsHitTesting(false)
        )
        .sheet(isPresented: $bound.showKeyboardHelp) {
            KeyboardHelpView(isPresented: $bound.showKeyboardHelp)
        }
    }

    @ViewBuilder
    private var backgroundLayer: some View {
        if #available(macOS 26, *) {
            Color.clear.containerBackground(.thinMaterial, for: .window)
        } else {
            Rectangle().fill(.ultraThinMaterial)
        }
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
    @State private var copied: String?

    private let step1 = "email-cli profile add default --api-key-env RESEND_API_KEY"
    private let step2 = "email-cli account add you@yourdomain.com --profile default --default"

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "envelope.open.fill")
                .font(.system(size: 44))
                .foregroundStyle(Color.accentColor)
            Text("Welcome to Minimail").font(.headline)
            Text("Minimail uses your Resend API key. Paste these into Terminal to set up your first account:")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                copyableCode(step1, index: 1)
                copyableCode(step2, index: 2)
            }
            .padding(.horizontal, 16)

            Button("Try again") {
                Task { await state.bootstrap() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func copyableCode(_ text: String, index: Int) -> some View {
        HStack(spacing: 6) {
            Text("\(index).").font(.system(size: 11)).foregroundStyle(.tertiary)
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = text
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    if copied == text { copied = nil }
                }
            } label: {
                Image(systemName: copied == text ? "checkmark" : "doc.on.clipboard")
                    .font(.system(size: 11))
                    .foregroundStyle(copied == text ? .green : .secondary)
            }
            .buttonStyle(.plain)
            .help("Copy to clipboard")
        }
        .padding(8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Dark capsule toast shown at the bottom of the popover while a send is
/// queued behind the undo window. Live countdown + Undo button. Tapping
/// "Send now" skips the remaining delay.
struct UndoSendToast: View {
    @Environment(AppState.self) private var state

    var body: some View {
        if let pending = state.pendingSend {
            HStack(spacing: 10) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.9))
                TimelineView(.periodic(from: .now, by: 0.25)) { context in
                    let remaining = max(0, Int(pending.deadline.timeIntervalSince(context.date).rounded(.up)))
                    Text("Sending in \(remaining)s")
                        .font(.system(size: 12))
                        .foregroundStyle(.white)
                }
                Spacer()
                Button("Undo") { state.undoPendingSend() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.15), in: Capsule())
                Button {
                    Task { await state.flushPendingSendNow() }
                } label: {
                    Text("Send now")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.75))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.82), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
        }
    }
}

/// Brief confirmation flash after a queued send finishes transmitting.
struct SentFlashToast: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text("Sent")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.82), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
    }
}
