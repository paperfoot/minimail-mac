import SwiftUI

/// Pill chip showing an attachment; tap = save-as.
struct AttachmentChip: View {
    let attachment: Attachment
    let onTap: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 5) {
                Image(systemName: iconName)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(attachment.filename ?? "attachment")
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                if let size = attachment.size {
                    Text(formatSize(size))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(hovered ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(HierarchicalShapeStyle.tertiary))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.regularMaterial, in: Capsule())
            .overlay(
                Capsule().strokeBorder(Color.primary.opacity(hovered ? 0.18 : 0.1), lineWidth: 0.5)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("Save \(attachment.filename ?? "attachment")")
    }

    private var iconName: String {
        guard let ct = attachment.content_type else { return "doc" }
        if ct.hasPrefix("image/") { return "photo" }
        if ct.hasPrefix("video/") { return "video" }
        if ct.hasPrefix("audio/") { return "waveform" }
        if ct.contains("pdf") { return "doc.richtext" }
        if ct.hasPrefix("text/") { return "doc.text" }
        return "doc"
    }

    private func formatSize(_ bytes: Int) -> String {
        let mb = Double(bytes) / 1_048_576
        let kb = Double(bytes) / 1024
        if mb >= 1 { return String(format: "%.1f MB", mb) }
        if kb >= 1 { return String(format: "%.0f KB", kb) }
        return "\(bytes) B"
    }
}

/// Chip representing a local file attached to the composer; tap X to remove.
struct ComposeAttachmentChip: View {
    let url: URL
    let onRemove: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "paperclip")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(url.lastPathComponent)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
        .overlay(
            Capsule().strokeBorder(Color.primary.opacity(hovered ? 0.18 : 0.1), lineWidth: 0.5)
        )
        .onHover { hovered = $0 }
    }
}

/// Simple flowing HStack — wraps children to new rows when width is exceeded.
/// Good enough for attachment pills and similar.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if rowWidth + size.width > maxWidth, rowWidth > 0 {
                totalHeight += rowHeight + spacing
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += size.width + (rowWidth > 0 ? spacing : 0)
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        return CGSize(width: maxWidth == .infinity ? rowWidth : maxWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            s.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Row for the Drafts folder. Drafts are outgoing work-in-progress, so the
/// styling deliberately diverges from inbox rows: recipient prefixed with
/// "To:", italicized subject (reads as "not yet sent"), and a relative
/// "Edited" timestamp instead of the inbox "received at" format.
struct DraftRow: View {
    let draft: Draft
    @State private var hovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "pencil.line")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text("To:")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                    Text(recipients)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Spacer()
                    Text(editedLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                Text(displaySubject)
                    .font(.system(size: 12))
                    .italic()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(hovered ? Color.primary.opacity(0.05) : Color.clear)
        .onHover { hovered = $0 }
    }

    private var recipients: String {
        let list = draft.to ?? []
        if list.isEmpty { return "(no recipient)" }
        return list.joined(separator: ", ")
    }
    private var displaySubject: String {
        let s = draft.subject ?? ""
        if s.isEmpty {
            let body = draft.text_body ?? ""
            return body.isEmpty ? "(empty)" : String(body.prefix(80))
        }
        return s
    }
    private var editedLabel: String {
        guard let date = DateFormat.parse(draft.updated_at ?? draft.created_at) else { return "" }
        let delta = Date().timeIntervalSince(date)
        if delta < 60 { return "Edited just now" }
        if delta < 3600 { return "Edited \(Int(delta / 60))m ago" }
        if delta < 86400 { return "Edited \(Int(delta / 3600))h ago" }
        return "Edited " + DateFormat.inboxList(draft.updated_at ?? draft.created_at)
    }
}
