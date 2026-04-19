import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        ZStack {
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
                    SettingsStubView()
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                case .needsInstall:
                    NeedsInstallView()
                case .onboarding:
                    OnboardingView()
                }
            }
        }
        .frame(width: 420, height: 580)
        .clipped()
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: state.router.currentView)
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

struct SettingsStubView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button { state.router.currentView = .inbox } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(IconButtonStyle())
                Text("Settings").font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider().opacity(0.25)

            VStack(spacing: 10) {
                Image(systemName: "gearshape.2")
                    .font(.system(size: 32))
                    .opacity(0.4)
                Text("Settings coming in v0.2")
                    .font(.system(size: 13, weight: .semibold))
                Text("Account management, signatures, sync interval, and keyboard customization.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
