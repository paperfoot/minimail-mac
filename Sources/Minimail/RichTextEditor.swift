import AppKit
import SwiftUI

/// Shared handle so ComposeView's toolbar can reach the live NSTextView
/// without prop-drilling bindings through SwiftUI. Set during makeNSView,
/// cleared automatically when the scroll view deallocates.
@MainActor
final class RichTextEditorHandle {
    weak var textView: NSTextView?
}

/// NSTextView wrapped for SwiftUI with rich-text editing enabled. All the
/// macOS text-handling shortcuts work out of the box because this is a real
/// NSTextView: ⌘C/⌘V/⌘A/⌘Z/⌘⇧Z plus the font-panel bindings ⌘B / ⌘I / ⌘U for
/// bold / italic / underline. Paste preserves formatting from Word, Pages,
/// Google Docs, Notes, etc.
///
/// The binding is an NSAttributedString so the compose state owns the full
/// typed representation; `ComposeView` asks for a plain-text copy (via
/// `.string`) for autosave + draft persistence and an HTML copy (via
/// `data(from:documentAttributes:)`) at send time.
struct RichTextEditor: NSViewRepresentable {
    @Binding var attributedText: NSAttributedString
    /// Called after each edit so the parent can schedule autosave without
    /// needing to observe the binding directly.
    var onEdit: (() -> Void)?
    /// Optional handle that stores a weak pointer to the NSTextView so a
    /// sibling toolbar can dispatch formatting actions to it.
    var handle: RichTextEditorHandle?

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.delegate = context.coordinator
        textView.isRichText = true
        textView.allowsUndo = true
        textView.allowsImageEditing = false
        textView.importsGraphics = false
        textView.usesFontPanel = false
        textView.usesInspectorBar = false
        textView.isAutomaticLinkDetectionEnabled = true
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.isGrammarCheckingEnabled = false
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 13)
        textView.textColor = .labelColor
        textView.linkTextAttributes = [
            .foregroundColor: NSColor(red: 0.04, green: 0.52, blue: 1.0, alpha: 1.0),
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        textView.textContainerInset = NSSize(width: 10, height: 10)
        if let storage = textView.textStorage {
            storage.setAttributedString(attributedText)
        }
        context.coordinator.textView = textView
        handle?.textView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView,
              let storage = textView.textStorage else { return }
        // Skip the update we just triggered ourselves — otherwise the round-
        // trip from delegate → binding → updateNSView → textStorage.set…
        // would clobber the user's cursor position every keystroke.
        if context.coordinator.suppressNextUpdate {
            context.coordinator.suppressNextUpdate = false
            return
        }
        if !storage.isEqual(to: attributedText) {
            let selection = textView.selectedRanges
            storage.setAttributedString(attributedText)
            textView.selectedRanges = selection
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichTextEditor
        weak var textView: NSTextView?
        var suppressNextUpdate = false

        init(_ parent: RichTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView,
                  let storage = textView.textStorage else { return }
            suppressNextUpdate = true
            parent.attributedText = NSAttributedString(attributedString: storage)
            parent.onEdit?()
        }
    }
}

/// Toolbar hover/click targets for the rich-text compose editor. Each button
/// dispatches a standard Cocoa action through the responder chain so the
/// currently-focused NSTextView performs the transformation, exactly as if
/// the user had hit the corresponding menu item.
struct RichTextToolbar: View {
    /// Parent supplies a ref to the live text view so toolbar buttons can
    /// manipulate it directly when a stock responder action doesn't exist
    /// (e.g. our custom bullet/numbered insertions).
    let textViewProvider: () -> NSTextView?

    var body: some View {
        HStack(spacing: 2) {
            toolButton(symbol: "bold", help: "Bold (⌘B)") {
                NSApp.sendAction(#selector(NSFontManager.addFontTrait(_:)), to: nil, from: BoldTrigger())
            }
            toolButton(symbol: "italic", help: "Italic (⌘I)") {
                NSApp.sendAction(#selector(NSFontManager.addFontTrait(_:)), to: nil, from: ItalicTrigger())
            }
            toolButton(symbol: "underline", help: "Underline (⌘U)") {
                NSApp.sendAction(#selector(NSText.underline(_:)), to: nil, from: nil)
            }
            divider
            toolButton(symbol: "list.bullet", help: "Bullet list") { insertListMarker("•  ") }
            toolButton(symbol: "list.number", help: "Numbered list") { insertListMarker("1. ") }
            divider
            toolButton(symbol: "link", help: "Add link (⌘K)") { promptForLink() }
            toolButton(symbol: "eraser", help: "Clear formatting") { clearFormatting() }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.03))
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.1))
            .frame(width: 1, height: 14)
            .padding(.horizontal, 4)
    }

    private func toolButton(symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 24, height: 22)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }

    /// Prepend a simple list marker to each selected line. Keeps the HTML
    /// export readable even without real `<ul>` output — recipients see "•"
    /// or "1." bullets preserved inline.
    private func insertListMarker(_ marker: String) {
        guard let textView = textViewProvider(),
              let storage = textView.textStorage else { return }
        let selection = textView.selectedRange()
        let ns = storage.string as NSString
        let lineRange = ns.lineRange(for: selection)
        let lineText = ns.substring(with: lineRange)
        // Don't double-prefix if the line already starts with the marker.
        if lineText.hasPrefix(marker) { return }
        let replacement = marker + lineText
        if textView.shouldChangeText(in: lineRange, replacementString: replacement) {
            storage.replaceCharacters(in: lineRange, with: replacement)
            textView.didChangeText()
        }
    }

    private func clearFormatting() {
        guard let textView = textViewProvider(),
              let storage = textView.textStorage else { return }
        let range = textView.selectedRange().length > 0
            ? textView.selectedRange()
            : NSRange(location: 0, length: storage.length)
        let plain: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor,
        ]
        if textView.shouldChangeText(in: range, replacementString: nil) {
            storage.setAttributes(plain, range: range)
            textView.didChangeText()
        }
    }

    private func promptForLink() {
        guard let textView = textViewProvider(),
              let storage = textView.textStorage else { return }
        let selected = textView.selectedRange()
        let alert = NSAlert()
        alert.messageText = "Insert link"
        alert.informativeText = "Paste the URL below."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.placeholderString = "https://…"
        alert.accessoryView = input
        guard alert.runModal() == .alertFirstButtonReturn,
              let url = URL(string: input.stringValue), input.stringValue.contains("://") else { return }
        let displayText = selected.length > 0
            ? (storage.string as NSString).substring(with: selected)
            : input.stringValue
        let attrString = NSAttributedString(string: displayText, attributes: [
            .link: url,
            .foregroundColor: NSColor(red: 0.04, green: 0.52, blue: 1.0, alpha: 1.0),
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ])
        if textView.shouldChangeText(in: selected, replacementString: displayText) {
            storage.replaceCharacters(in: selected, with: attrString)
            textView.didChangeText()
        }
    }
}

/// Senders for `NSFontManager.addFontTrait(_:)` — the font panel looks at
/// `tag()` on the sender to decide which trait to toggle. This is the
/// documented way to trigger bold / italic from custom toolbar buttons.
private final class BoldTrigger: NSObject {
    @objc func tag() -> Int { Int(NSFontTraitMask.boldFontMask.rawValue) }
}
private final class ItalicTrigger: NSObject {
    @objc func tag() -> Int { Int(NSFontTraitMask.italicFontMask.rawValue) }
}
