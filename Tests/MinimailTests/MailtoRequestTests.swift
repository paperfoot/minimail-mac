import Foundation
import Testing
@testable import Minimail

@Suite("Mailto request parsing")
struct MailtoRequestTests {
    @Test("Percent-decodes Unicode while preserving literal plus signs")
    func decodesUnicodeAndPreservesPlus() throws {
        let url = try #require(URL(string: "mailto:jos%C3%A9+tag@example.com?subject=Caf%C3%A9+notes&body=Ol%C3%A1%20Mundo"))
        let request = try #require(MailtoRequest(url: url))

        #expect(request.to == "josé+tag@example.com")
        #expect(request.subject == "Café+notes")
        #expect(request.body == "Olá Mundo")
    }

    @Test("Collects repeated To, Cc, and Bcc recipients")
    func collectsRepeatedRecipients() throws {
        let url = try #require(URL(string: "mailto:first@example.com?to=second@example.com&to=third@example.com&cc=copy1@example.com&cc=copy2@example.com&bcc=blind1@example.com&bcc=blind2@example.com"))
        let request = try #require(MailtoRequest(url: url))

        #expect(request.to == "first@example.com, second@example.com, third@example.com")
        #expect(request.cc == "copy1@example.com, copy2@example.com")
        #expect(request.bcc == "blind1@example.com, blind2@example.com")
    }

    @Test("Removes header line breaks while preserving body line breaks")
    func sanitizesHeadersOnly() throws {
        let url = try #require(URL(string: "mailto:person@example.com?subject=First%0D%0ASecond&cc=copy@example.com%0Ainjected&body=First%0D%0ASecond"))
        let request = try #require(MailtoRequest(url: url))

        #expect(request.subject == "First  Second")
        #expect(request.cc == "copy@example.com injected")
        #expect(!request.subject.contains("\r"))
        #expect(!request.subject.contains("\n"))
        #expect(request.body == "First\r\nSecond")
    }

    @Test("Ignores unrecognized sender and attachment fields")
    func ignoresUnrecognizedFields() throws {
        let url = try #require(URL(string: "mailto:person@example.com?from=attacker@example.com&attachment=file:///tmp/secret.txt"))
        let request = try #require(MailtoRequest(url: url))

        #expect(request.to == "person@example.com")
        #expect(request.cc.isEmpty)
        #expect(request.bcc.isEmpty)
        #expect(request.subject.isEmpty)
        #expect(request.body.isEmpty)
    }

    @Test("Rejects non-mailto URLs")
    func rejectsOtherSchemes() throws {
        let url = try #require(URL(string: "https://example.com/?to=person@example.com"))

        #expect(MailtoRequest(url: url) == nil)
    }
}
