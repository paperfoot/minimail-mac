import SwiftUI
import QuickLook

/// Files stay near their message header, even in a long conversation.
struct AttachmentShelf: View {
    @Environment(AppState.self) private var state
    let messageID: Int64
    let attachments: [Attachment]
    @State private var previewURL: URL?
    @State private var error: String?
    @State private var savingAll = false
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if attachments.count > 1 {
                HStack {
                    Button { isExpanded.toggle() } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "paperclip")
                            Text("\(attachments.count) attachments")
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        }
                    }.buttonStyle(.plain)
                    Spacer()
                    Button(savingAll ? "Saving…" : "Save All…", action: saveAll)
                        .disabled(savingAll || isDownloading)
                }.font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ForEach(isExpanded || attachments.count == 1 ? attachments : []) { attachment in
                HStack(spacing: 8) {
                    Image(systemName: attachment.symbol).foregroundStyle(.secondary).frame(width: 20)
                    Button { preview(attachment) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(attachment.safeFilename).font(.system(size: 12, weight: .medium))
                                .lineLimit(1).truncationMode(.middle)
                            if let bytes = attachment.size {
                                Text(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).help("Quick Look: \(attachment.safeFilename)")
                    .accessibilityLabel("Preview \(attachment.safeFilename)")
                    if state.reader.attachmentDownloads.contains("\(messageID):\(attachment.id)") {
                        ProgressView().controlSize(.small)
                    }
                    Button { save(attachment) } label: { Image(systemName: "arrow.down.to.line") }
                        .buttonStyle(.borderless).help("Save \(attachment.safeFilename)…")
                        .accessibilityLabel("Save \(attachment.safeFilename)")
                }
                .padding(8)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .disabled(state.reader.attachmentDownloads.contains("\(messageID):\(attachment.id)") || savingAll)
                .contextMenu {
                    Button("Quick Look") { preview(attachment) }
                    Button("Save As…") { save(attachment) }
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .quickLookPreview($previewURL)
    }

    private var isDownloading: Bool {
        state.reader.attachmentDownloads.contains { $0.hasPrefix("\(messageID):") }
    }

    private func preview(_ attachment: Attachment) {
        error = nil
        Task {
            do {
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Minimail-Preview-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let url = folder.appendingPathComponent(attachment.safeFilename)
                try await state.exportAttachment(attachment, messageID: messageID, to: url)
                previewURL = url
            } catch { self.error = ActionableError.classify(error).message }
        }
    }

    private func save(_ attachment: Attachment) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = attachment.safeFilename
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        error = nil
        Task {
            do {
                try await state.exportAttachment(attachment, messageID: messageID, to: url)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch { self.error = ActionableError.classify(error).message }
        }
    }

    private func saveAll() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Save Attachments"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        savingAll = true
        error = nil
        let batch = state.beginAttachmentExportBatch()
        Task {
            defer { savingAll = false; state.endAttachmentExportBatch(batch) }
            var saved: [URL] = []
            var failures = 0
            for attachment in attachments {
                // Reserve a new name without overwriting another file, including
                // same-name attachments within this message.
                let url: URL
                do {
                    url = try AttachmentExport.reserveURL(filename: attachment.safeFilename, in: folder)
                } catch {
                    failures += 1; continue
                }
                do {
                    try await state.exportAttachment(attachment, messageID: messageID, to: url)
                    saved.append(url)
                } catch {
                    try? FileManager.default.removeItem(at: url)
                    failures += 1
                }
            }
            if failures > 0 { error = "Saved \(saved.count) of \(attachments.count) files. Try saving the remaining files individually." }
            if !saved.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(saved) }
        }
    }
}

enum AttachmentExport {
    static func reserveURL(filename: String, in folder: URL) throws -> URL {
        let base = folder.appendingPathComponent(filename)
        var candidate = base
        var number = 2
        while true {
            do {
                try Data().write(to: candidate, options: .withoutOverwriting)
                return candidate
            } catch CocoaError.fileWriteFileExists {
                // Retry only name collisions; permission/disk errors propagate.
            }
            let stem = base.deletingPathExtension().lastPathComponent
            let suffix = base.pathExtension.isEmpty ? "" : "." + base.pathExtension
            candidate = folder.appendingPathComponent("\(stem) (\(number))\(suffix)")
            number += 1
        }
    }
}

extension Attachment {
    var safeFilename: String {
        let leaf = ((filename ?? "") as NSString).lastPathComponent
        if leaf.isEmpty || leaf.hasPrefix(".") { return "attachment" }
        return leaf.replacingOccurrences(of: ":", with: "-")
    }

    var symbol: String {
        let type = content_type ?? ""
        if type.hasPrefix("image/") { return "photo" }
        if type.hasPrefix("video/") { return "video" }
        if type.hasPrefix("audio/") { return "waveform" }
        if type.contains("pdf") { return "doc.richtext" }
        return "doc"
    }
}
