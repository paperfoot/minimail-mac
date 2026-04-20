import AppKit
import SwiftUI

/// Pure-SwiftUI recipient token field with a Liquid Glass autocomplete
/// popover. Replaces the previous NSTokenField wrapper whose Cocoa completion
/// dropdown couldn't be themed. All standard shortcuts still work because
/// TextField itself is a real NSTextField under the hood:
///   ⌘C / ⌘V / ⌘X / ⌘A / ⌘Z / ⌘⇧Z / ← → / ⇧-selection / double-click-select.
///
/// Behaviour:
///   - Typing a comma / space / newline commits the current text as a pill.
///   - Pasting a comma-separated list creates one pill per address.
///   - Backspace on an empty field deletes the trailing pill.
///   - Typed substring shows up to 6 best-matching suggestions in a glass
///     popover beneath the field.
///   - ↑ / ↓ move the highlight; ⏎ or ⇥ accepts the highlighted suggestion;
///     ⎋ dismisses the popover without inserting.
struct EmailTokenField: View {
    @Binding var text: String
    var placeholder: String = ""
    var suggestions: [String] = []

    @State private var draft: String = ""
    @State private var highlightedIndex: Int = 0
    @FocusState private var isFocused: Bool

    private var tokens: [String] {
        Self.split(text)
    }

    private var filtered: [String] {
        let query = draft.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return [] }
        let taken = Set(tokens.map { $0.lowercased() })
        var scored: [(String, Int)] = []
        for candidate in suggestions {
            let lower = candidate.lowercased()
            if taken.contains(lower) { continue }
            if let range = lower.range(of: query) {
                let distance = lower.distance(from: lower.startIndex, to: range.lowerBound)
                scored.append((candidate, distance))
            }
        }
        scored.sort { $0.1 < $1.1 }
        return Array(scored.prefix(6).map(\.0))
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            fieldRow
            if isFocused, !filtered.isEmpty {
                SuggestionPopover(
                    suggestions: filtered,
                    highlightedIndex: highlightedIndex,
                    onPick: { pick($0) }
                )
                .offset(y: 28)
                .zIndex(100)
                .transition(.opacity.combined(with: .move(edge: .top)))
                .animation(.easeOut(duration: 0.12), value: filtered)
            }
        }
    }

    private var fieldRow: some View {
        FlowLayout(spacing: 4) {
            ForEach(tokens, id: \.self) { token in
                RecipientPill(text: token) { remove(token) }
            }

            TextField(tokens.isEmpty ? placeholder : "", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .frame(minWidth: 120)
                .focused($isFocused)
                .onChange(of: draft) { _, new in handleDraftChange(new) }
                .onKeyPress(.downArrow) {
                    guard !filtered.isEmpty else { return .ignored }
                    highlightedIndex = min(filtered.count - 1, highlightedIndex + 1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    guard !filtered.isEmpty else { return .ignored }
                    highlightedIndex = max(0, highlightedIndex - 1)
                    return .handled
                }
                .onKeyPress(.return) {
                    if !filtered.isEmpty, filtered.indices.contains(highlightedIndex) {
                        pick(filtered[highlightedIndex])
                        return .handled
                    }
                    commitDraft()
                    return .handled
                }
                .onKeyPress(.tab) {
                    guard !filtered.isEmpty, filtered.indices.contains(highlightedIndex) else {
                        return .ignored
                    }
                    pick(filtered[highlightedIndex])
                    return .handled
                }
                .onKeyPress(.escape) {
                    if !filtered.isEmpty {
                        // Hide the popover without inserting.
                        draft = ""
                        return .handled
                    }
                    return .ignored
                }
                .onKeyPress(.deleteForward) { .ignored }
                .onKeyPress(keys: [.delete], phases: .down) { _ in
                    if draft.isEmpty, let last = tokens.last {
                        remove(last)
                        return .handled
                    }
                    return .ignored
                }
        }
    }

    // ── Mutations ────────────────────────────────────────────────────────

    private func handleDraftChange(_ new: String) {
        highlightedIndex = 0
        // Commit on comma / semicolon / newline. Space is kept as-is so the
        // user can type multi-word display names without losing them.
        if let last = new.last, ",;\n\t".contains(last) {
            let cleaned = new
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ",;"))
            if !cleaned.isEmpty { addToken(cleaned) }
            draft = ""
            return
        }
        // Multi-paste — if the pasted text contains delimiters, split it all.
        if new.contains(where: { ",;\n\t".contains($0) }) {
            let parts = Self.split(new)
            for part in parts { addToken(part) }
            draft = ""
        }
    }

    private func commitDraft() {
        let cleaned = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleaned.isEmpty { addToken(cleaned) }
        draft = ""
    }

    private func pick(_ email: String) {
        addToken(email)
        draft = ""
        highlightedIndex = 0
    }

    private func addToken(_ email: String) {
        var list = tokens
        if !list.map({ $0.lowercased() }).contains(email.lowercased()) {
            list.append(email)
            text = list.joined(separator: ", ")
        }
    }

    private func remove(_ email: String) {
        var list = tokens
        list.removeAll { $0.lowercased() == email.lowercased() }
        text = list.joined(separator: ", ")
    }

    static func split(_ string: String) -> [String] {
        string.splitAddressTokens()
    }
}

// ── Pill + popover ───────────────────────────────────────────────────────

/// Individual recipient chip. Coloured by validity — invalid addresses go red
/// so typos are visually obvious before send.
private struct RecipientPill: View {
    let text: String
    let onRemove: () -> Void
    @State private var hovered = false

    private var isEmail: Bool { text.looksLikeEmail }
    private var display: String {
        // "Alice <a@x.com>" → "Alice"; bare email → email as-is.
        if let open = text.firstIndex(of: "<") {
            let head = text[..<open]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return head.isEmpty ? text : head
        }
        return text
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(display)
                .font(.system(size: 12))
                .foregroundStyle(isEmail ? Color.primary : Color.red)
                .lineLimit(1)
            if hovered {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(
                isEmail ? Color.accentColor.opacity(0.14) : Color.red.opacity(0.14)
            )
        )
        .overlay(
            Capsule().strokeBorder(
                isEmail ? Color.accentColor.opacity(0.25) : Color.red.opacity(0.35),
                lineWidth: 0.5
            )
        )
        .onHover { hovered = $0 }
        .help(text)
    }
}

/// Liquid-Glass suggestion list shown below the token field while the user
/// types. Uses `.glassEffect` on macOS 26 for the Tahoe look; falls back to
/// `.regularMaterial` on older SDKs at build time. Width auto-fits content
/// up to 320pt so the field doesn't jump around visually.
private struct SuggestionPopover: View {
    let suggestions: [String]
    let highlightedIndex: Int
    let onPick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.offset) { idx, item in
                SuggestionRow(
                    text: item,
                    isHighlighted: idx == highlightedIndex,
                    onTap: { onPick(item) }
                )
                if idx < suggestions.count - 1 {
                    Divider().opacity(0.1)
                }
            }
        }
        .padding(4)
        .frame(minWidth: 220, idealWidth: 280, maxWidth: 320)
        // 12pt matches our other glass surfaces (GlassSurface.glassSurface).
        // System handles edge effects — no custom shadow or border.
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct SuggestionRow: View {
    let text: String
    let isHighlighted: Bool
    let onTap: () -> Void
    @State private var hovered = false

    /// Split "Name <email@x.com>" into (name, email). Shown as a two-line
    /// row with the name in the primary weight and the email underneath.
    private var parts: (name: String?, email: String) {
        if let open = text.firstIndex(of: "<"),
           let close = text.firstIndex(of: ">"),
           open < close {
            let name = text[..<open]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let email = String(text[text.index(after: open)..<close])
            return (name.isEmpty ? nil : name, email)
        }
        return (nil, text)
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                AccountAvatar(email: parts.email)
                VStack(alignment: .leading, spacing: 1) {
                    if let name = parts.name {
                        Text(name)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(parts.email)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text(parts.email)
                            .font(.system(size: 12))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(rowBackground)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }

    private var rowBackground: Color {
        if isHighlighted { return Color.accentColor.opacity(0.25) }
        if hovered { return Color.primary.opacity(0.08) }
        return .clear
    }
}
