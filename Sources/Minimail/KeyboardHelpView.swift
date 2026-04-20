import SwiftUI

/// Sheet listing every keyboard shortcut Minimail responds to. Invoked by
/// pressing `?` anywhere (handled on RootView). The list is grouped into the
/// three contexts users think about: moving around, reading, composing.
struct KeyboardHelpView: View {
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Keyboard Shortcuts")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button { isPresented = false } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider().opacity(0.25)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    section("Navigation", rows: [
                        ("↑ / k", "Previous message"),
                        ("↓ / j", "Next message"),
                        ("↩", "Open selected message"),
                        ("⎋", "Back to inbox / close sheet"),
                        ("⌘ ,", "Settings"),
                        ("⌘ /", "This help"),
                    ])
                    section("Inbox", rows: [
                        ("⌘ N", "New message"),
                        ("⌘ R", "Refresh / reply in reader"),
                        ("⌘ ⇧ R", "Reply all"),
                        ("⌘ ⇧ F", "Forward"),
                        ("⌘ ⌫", "Archive"),
                    ])
                    section("Compose", rows: [
                        ("⌘ ⏎", "Send"),
                        ("⌘ ⇧ K", "Attach files"),
                        ("⌘ ⇧ V", "Paste as attachment (images)"),
                        ("⎋", "Close & save draft"),
                    ])
                    section("Formatting", rows: [
                        ("⌘ B", "Bold"),
                        ("⌘ I", "Italic"),
                        ("⌘ U", "Underline"),
                        ("⌘ C / V / A", "Copy / Paste / Select all"),
                        ("⌘ Z / ⌘ ⇧ Z", "Undo / Redo"),
                    ])
                    section("Reader", rows: [
                        ("S", "Star / unstar"),
                    ])
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
        }
        .frame(width: 360, height: 440)
    }

    private func section(_ title: String, rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            VStack(spacing: 4) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 12) {
                        Text(row.0)
                            .font(.system(.caption, design: .monospaced))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
                            .frame(minWidth: 70, alignment: .leading)
                        Text(row.1)
                            .font(.system(size: 12))
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                }
            }
        }
    }
}
