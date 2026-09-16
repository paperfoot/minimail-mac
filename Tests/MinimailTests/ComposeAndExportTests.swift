import AppKit
import Foundation
import Testing
@testable import Minimail

@MainActor
@Suite("Compose formatting and attachment exports")
struct ComposeAndExportTests {
    @Test("Default compose typography remains plain text")
    func defaultTypographyDoesNotEmitHTML() {
        let compose = ComposeState()
        compose.bodyAttributed = NSAttributedString(
            string: "Plain message",
            attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.labelColor,
            ]
        )

        #expect(compose.bodyHTML == nil)
    }

    @Test("Foreground color is retained in compose HTML")
    func foregroundColorEmitsHTML() throws {
        let compose = ComposeState()
        compose.bodyAttributed = NSAttributedString(
            string: "Red message",
            attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1),
            ]
        )

        let html = try #require(compose.bodyHTML?.lowercased())
        #expect(html.contains("color: #"))
        #expect(html.contains("color: #000000") == false)
    }

    @Test("A nondefault font and size are retained in compose HTML")
    func customFontEmitsHTML() throws {
        let font = try #require(NSFont(name: "Menlo", size: 18))
        let compose = ComposeState()
        compose.bodyAttributed = NSAttributedString(
            string: "Code sample",
            attributes: [
                .font: font,
                .foregroundColor: NSColor.labelColor,
            ]
        )

        let html = try #require(compose.bodyHTML?.lowercased())
        #expect(html.contains("menlo"))
        #expect(html.contains("18"))
    }

    @Test("Paragraph alignment is retained in compose HTML")
    func paragraphAlignmentEmitsHTML() throws {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let compose = ComposeState()
        compose.bodyAttributed = NSAttributedString(
            string: "Centered message",
            attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph,
            ]
        )

        let html = try #require(compose.bodyHTML?.lowercased())
        #expect(html.contains("text-align: center"))
    }

    @Test("Strikethrough is retained in compose HTML")
    func strikethroughEmitsHTML() throws {
        let compose = ComposeState()
        compose.bodyAttributed = NSAttributedString(
            string: "Old price",
            attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.labelColor,
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
            ]
        )

        let html = try #require(compose.bodyHTML?.lowercased())
        #expect(html.contains("line-through") || html.contains("<strike"))
    }

    @Test("Links are retained in compose HTML")
    func linkEmitsHTML() throws {
        let compose = ComposeState()
        compose.bodyAttributed = NSAttributedString(
            string: "Open documentation",
            attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.labelColor,
                .link: try #require(URL(string: "https://example.com/docs")),
            ]
        )

        let html = try #require(compose.bodyHTML?.lowercased())
        #expect(html.contains("href=\"https://example.com/docs\""))
    }

    @Test("Attachment export state and quit waiter last until the CLI finishes")
    func attachmentExportWaitsAndRejectsDuplicate() async throws {
        let fixture = try Self.makeAttachmentFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let state = AppState(cli: EmailCLI(binaryPath: fixture.executable.path))
        let attachment = Self.attachment(id: "same-file")
        let destination = fixture.directory.appendingPathComponent("first-export.bin")
        let key = "44:\(attachment.id)"

        let export = Task { @MainActor in
            try await state.exportAttachment(attachment, messageID: 44, to: destination)
        }
        await Task.yield()
        #expect(state.reader.attachmentDownloads.contains(key))

        do {
            try await state.exportAttachment(attachment, messageID: 44, to: destination)
            Issue.record("A duplicate attachment export should have been rejected.")
        } catch EmailCLI.CLIError.badInput(let message) {
            #expect(message.contains("already downloading"))
        } catch {
            Issue.record("Expected duplicate-download input error, received \(error).")
        }

        var waiterFinished = false
        let waiter = Task { @MainActor in
            await state.waitForAttachmentDownloads()
            waiterFinished = true
        }
        await Task.yield()
        #expect(waiterFinished == false)

        try await export.value
        await waiter.value

        #expect(waiterFinished)
        #expect(state.reader.attachmentDownloads.contains(key) == false)
        #expect(try Data(contentsOf: destination) == Data("downloaded".utf8))
    }

    @Test("An export batch keeps the waiter blocked between sequential downloads")
    func attachmentBatchWaitsThroughSequentialExports() async throws {
        let fixture = try Self.makeAttachmentFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let state = AppState(cli: EmailCLI(binaryPath: fixture.executable.path))
        let token = state.beginAttachmentExportBatch()
        defer { state.endAttachmentExportBatch(token) }

        var waiterFinished = false
        let waiter = Task { @MainActor in
            await state.waitForAttachmentDownloads()
            waiterFinished = true
        }
        await Task.yield()
        #expect(waiterFinished == false)

        let first = Self.attachment(id: "first")
        try await state.exportAttachment(
            first,
            messageID: 55,
            to: fixture.directory.appendingPathComponent("first.bin")
        )
        await Task.yield()
        #expect(waiterFinished == false)

        let second = Self.attachment(id: "second")
        try await state.exportAttachment(
            second,
            messageID: 55,
            to: fixture.directory.appendingPathComponent("second.bin")
        )
        await Task.yield()
        #expect(waiterFinished == false)

        state.endAttachmentExportBatch(token)
        await waiter.value
        #expect(waiterFinished)
    }

    private static func attachment(id: String) -> Minimail.Attachment {
        Minimail.Attachment(
            id: id,
            filename: "\(id).bin",
            content_type: "application/octet-stream",
            size: nil,
            downloaded: false
        )
    }

    private static func makeAttachmentFixture() throws -> (directory: URL, executable: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MinimailAttachmentTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let executable = directory.appendingPathComponent("email-cli-fixture")
        let source = #"""
        #!/bin/sh
        set -eu
        case " $* " in
          *" attachments get "*) ;;
          *) printf '%s\n' 'unexpected command' >&2; exit 4 ;;
        esac
        output=""
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --output-file) output="$2"; shift 2 ;;
            *) shift ;;
          esac
        done
        [ -n "$output" ]
        sleep 0.2
        printf '%s' 'downloaded' > "$output"
        printf '%s\n' '{"status":"success","data":{}}'
        """#
        try source.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return (directory, executable)
    }
}
