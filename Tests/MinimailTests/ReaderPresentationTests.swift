import Foundation
import Testing
import WebKit
@testable import Minimail

@Suite("Reader presentation")
struct ReaderPresentationTests {
    @Test("Ordinary web links do not imply remote message resources")
    func ordinaryLinksAreNotRemoteResources() {
        let html = """
        <p>Read <a href="https://example.com/article">the article</a>.</p>
        <a href='//example.com/another'>Another link</a>
        """

        #expect(EmailHTML.hasRemoteResources(html) == false)
    }

    @Test(
        "Detects remotely loaded message resources",
        arguments: [
            #"<img src="https://example.com/pixel.png">"#,
            #"<IMG SRC='HTTP://EXAMPLE.COM/IMAGE.PNG'>"#,
            #"<img src=https://example.com/image.png>"#,
            #"<img src=//example.com/image.png>"#,
            #"<source srcset="local.png 1x, https://example.com/remote.png 2x">"#,
            #"<div style="background-image: url('https://example.com/background.png')">"#,
            #"<style>@import "https://example.com/mail.css";</style>"#,
            #"<video poster="//example.com/poster.jpg"></video>"#,
            #"<link rel="stylesheet" href="https://example.com/mail.css">"#,
        ]
    )
    func detectsRemoteResources(html: String) {
        #expect(EmailHTML.hasRemoteResources(html))
    }

    @Test(
        "Does not flag inline-only message resources",
        arguments: [
            #"<img src="cid:logo@example.com">"#,
            #"<img src="data:image/png;base64,AAAA">"#,
            #"<source srcset="cid:small 1x, data:image/png;base64,AAAA 2x">"#,
            #"<div style="background-image: url(data:image/png;base64,AAAA)">"#,
        ]
    )
    func inlineResourcesStayPrivate(html: String) {
        #expect(EmailHTML.hasRemoteResources(html) == false)
    }

    @MainActor
    @Test("WebKit accepts the production privacy rule list")
    func privacyRuleListCompiles() async {
        let identifier = "minimail-reader-test-\(UUID().uuidString)"
        let compiled = await withCheckedContinuation { continuation in
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: identifier,
                encodedContentRuleList: EmailHTML.blockRulesJSON
            ) { list, error in
                continuation.resume(returning: list != nil && error == nil)
            }
        }

        #expect(compiled, "The production content blocker JSON must compile before HTML is displayed.")
    }

    @Test("Reserving duplicate names keeps existing files intact")
    func duplicateAttachmentNamesAreReservedWithoutOverwrite() throws {
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let existing = folder.appendingPathComponent("invoice.pdf")
        let original = Data("original invoice".utf8)
        try original.write(to: existing)

        let second = try AttachmentExport.reserveURL(filename: "invoice.pdf", in: folder)
        let third = try AttachmentExport.reserveURL(filename: "invoice.pdf", in: folder)

        #expect(second.lastPathComponent == "invoice (2).pdf")
        #expect(third.lastPathComponent == "invoice (3).pdf")
        #expect(second != third)
        #expect(try Data(contentsOf: existing) == original)
        #expect(FileManager.default.fileExists(atPath: second.path))
        #expect(FileManager.default.fileExists(atPath: third.path))
    }

    @Test("Invalid attachment destinations return an error")
    func invalidAttachmentDestinationThrows() throws {
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let regularFile = folder.appendingPathComponent("not-a-directory")
        try Data("occupied".utf8).write(to: regularFile)

        do {
            _ = try AttachmentExport.reserveURL(filename: "invoice.pdf", in: regularFile)
            Issue.record("Expected reserving a file below a regular file to fail.")
        } catch let error as CocoaError {
            #expect(error.code != .fileWriteFileExists)
        } catch {
            Issue.record("Expected a Cocoa file-system error, received \(error).")
        }
    }

    @Test("Attachment filenames cannot escape their destination folder")
    func attachmentFilenamesAreSafe() {
        #expect(makeAttachment(filename: "../../secret.txt").safeFilename == "secret.txt")
        #expect(makeAttachment(filename: "/tmp/private.pdf").safeFilename == "private.pdf")
        #expect(makeAttachment(filename: ".hidden").safeFilename == "attachment")
        #expect(makeAttachment(filename: "report:final.pdf").safeFilename == "report-final.pdf")
        #expect(makeAttachment(filename: nil).safeFilename == "attachment")
    }

    @Test("Legacy attachment JSON decodes without inline-image metadata")
    func legacyAttachmentMetadataRemainsOptional() throws {
        let json = #"{"id":"legacy","filename":"invoice.pdf","content_type":"application/pdf","size":42,"downloaded":true}"#

        let attachment = try JSONDecoder().decode(Minimail.Attachment.self, from: Data(json.utf8))

        #expect(attachment.id == "legacy")
        #expect(attachment.content_id == nil)
        #expect(attachment.content_disposition == nil)
    }

    @Test("Current attachment JSON decodes inline-image metadata")
    func currentAttachmentMetadataDecodes() throws {
        let json = #"{"id":"inline","filename":"logo.png","content_type":"image/png","size":128,"downloaded":true,"content_id":"<logo@example.com>","content_disposition":"inline"}"#

        let attachment = try JSONDecoder().decode(Minimail.Attachment.self, from: Data(json.utf8))

        #expect(attachment.content_id == "<logo@example.com>")
        #expect(attachment.content_disposition == "inline")
    }

    @Test("CID normalization matches encoded references with bracketed metadata")
    func encodedCIDMatchesBracketedMetadata() {
        let metadataID = "<logo@example.com>"
        let html = #"<img src="cid:logo%40example.com">"#

        #expect(EmailHTML.normalizedContentID(metadataID) == "logo@example.com")
        #expect(EmailHTML.referencesContentID(metadataID, in: html))

        let resolved = EmailHTML.resolvingInlineImages(
            in: html,
            images: [EmailHTML.normalizedContentID(metadataID): "data:image/png;base64,AAAA"]
        )
        #expect(resolved == #"<img src="data:image/png;base64,AAAA">"#)
    }

    @Test("CID resolution replaces every known reference and leaves external URLs intact")
    func resolvesMultipleCIDReferencesOnly() {
        let html = #"<img src="cid:first"><a href="https://example.com"><img src='CID:second'></a><img src="cid:first">"#
        let externalURL = "https://example.com"

        let resolved = EmailHTML.resolvingInlineImages(
            in: html,
            images: [
                "first": "data:image/png;base64,FIRST",
                "second": "data:image/jpeg;base64,SECOND",
            ]
        )

        #expect(resolved.components(separatedBy: "data:image/png;base64,FIRST").count - 1 == 2)
        #expect(resolved.contains("data:image/jpeg;base64,SECOND"))
        #expect(resolved.contains(externalURL))
        #expect(resolved.contains("cid:") == false)
        #expect(resolved.contains("CID:") == false)
    }

    @Test("Unknown CID references remain unresolved and are reported")
    func unknownCIDRemainsUnresolved() {
        let html = #"<p><img src="cid:known"><img src="cid:unknown%40example.com"></p>"#
        let resolved = EmailHTML.resolvingInlineImages(
            in: html,
            images: ["known": "data:image/png;base64,KNOWN"]
        )

        #expect(resolved.contains("data:image/png;base64,KNOWN"))
        #expect(resolved.contains("cid:unknown%40example.com"))
        #expect(EmailHTML.unresolvedContentIDs(in: html, images: ["known": "data:image/png;base64,KNOWN"]) == ["unknown@example.com"])
    }

    private func makeTemporaryDirectory() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MinimailReaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        return folder
    }

    private func makeAttachment(filename: String?) -> Minimail.Attachment {
        Minimail.Attachment(
            id: UUID().uuidString,
            filename: filename,
            content_type: "application/octet-stream",
            size: nil,
            downloaded: false
        )
    }
}
