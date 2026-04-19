import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        ZStack {
            backgroundLayer
                .ignoresSafeArea()

            switch state.currentView {
            case .inbox:
                InboxView()
            case .reader(let id):
                ReaderView(messageID: id)
            case .compose:
                ComposeView()
            case .accountSwitcher:
                AccountSwitcherView()
            case .needsInstall:
                NeedsInstallView()
            }
        }
        .frame(width: 420, height: 580)
        .animation(.easeInOut(duration: 0.15), value: state.currentView)
        .animation(.easeInOut(duration: 0.15), value: state.messages.count)
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
