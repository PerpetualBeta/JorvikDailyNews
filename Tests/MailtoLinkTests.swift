import Foundation

/// `mailto:` is the one non-web scheme an article may use, and the one that
/// carries fields the reader cannot see. A feed chooses every character of it.
enum MailtoLinkTests {

    private static func parse(_ s: String) -> MailtoLink? {
        guard let url = URL(string: s) else { return nil }
        return MailtoLink(url)
    }

    static func run() {
        T.suite("Mailto: the ordinary cases") {
            T.equal(parse("mailto:desk@paper.example")?.recipients, "desk@paper.example", "bare address")
            T.equal(parse("mailto:a@x.example,b@y.example")?.to.count, 2, "two recipients")
            T.equal(parse("mailto:desk@paper.example?subject=A%20correction")?.subject,
                    "A correction", "a subject is kept and decoded")
            T.equal(parse("mailto:desk@paper.example")?.discarded, [], "nothing dropped")
        }

        T.suite("Mailto: hidden fields are dropped and named") {
            // The reason the sheet exists. A bcc address means the message the
            // reader sends goes somewhere the composer may not show them.
            let bcc = parse("mailto:desk@paper.example?bcc=harvest@attacker.example")
            T.equal(bcc?.discarded, ["bcc"], "bcc is dropped")
            T.equal(bcc?.safeURL?.absoluteString, "mailto:desk@paper.example",
                    "and does not survive into the rebuilt link")

            let everything = parse("mailto:desk@paper.example"
                                   + "?cc=a@x.example&bcc=b@y.example&body=Please%20send%20money"
                                   + "&subject=Hello&from=spoofed@z.example")
            T.equal(everything?.subject, "Hello", "the subject survives")
            T.expect(everything?.discarded.contains("cc") == true, "cc named")
            T.expect(everything?.discarded.contains("bcc") == true, "bcc named")
            T.expect(everything?.discarded.contains("body") == true, "body named")
            T.expect(everything?.discarded.contains("from") == true, "an unknown field named too")
            T.equal(everything?.safeURL?.absoluteString,
                    "mailto:desk@paper.example?subject=Hello",
                    "the rebuilt link carries only what the sheet shows")
        }

        T.suite("Mailto: header injection in a subject") {
            // A newline in a subject is a second header in the composer.
            let injected = parse("mailto:desk@paper.example?subject=Hi%0D%0Abcc:%20harvest@attacker.example")
            T.expect(injected?.subject?.contains("\r") == false, "no carriage return")
            T.expect(injected?.subject?.contains("\n") == false, "no newline")
            T.expect(injected?.safeURL?.absoluteString.contains("%0D") == false,
                     "and none re-encoded into the rebuilt link")
            T.expect(injected?.safeURL?.absoluteString.contains("%0A") == false, "either form")
        }

        T.suite("Mailto: the sheet sees what the article wrote, not the cleaned copy") {
            // The rendered link attribute used to carry `safeURL`, so by the
            // time the sheet re-parsed it the bcc was already gone and it
            // reported nothing dropped. Round-trip the way the renderer does.
            let hostile = "mailto:desk@paper.example?bcc=harvest@attacker.example&body=Send%20money"
            guard let first = parse(hostile) else { T.expect(false, "parses"); return }
            T.equal(first.discarded.sorted(), ["bcc", "body"], "both fields seen")
            // What the renderer puts in the attribute, re-parsed as `open(_:)` does.
            guard let again = MailtoLink(first.original) else {
                T.expect(false, "the carried URL re-parses"); return
            }
            T.equal(again.discarded.sorted(), ["bcc", "body"],
                    "and they are STILL visible after the round trip")
            // Whereas the rebuilt link is exactly what Mail should receive.
            T.equal(first.safeURL?.absoluteString, "mailto:desk@paper.example",
                    "nothing hidden reaches Mail")
        }

        T.suite("Mailto: what is not an address") {
            T.expect(parse("mailto:") == nil, "no address at all")
            T.expect(parse("mailto:notanaddress") == nil, "no @")
            T.expect(parse("mailto:a@nodot") == nil, "no dot in the domain")
            T.expect(parse("mailto:@x.example") == nil, "no local part")
            T.expect(parse("mailto:a b@x.example") == nil, "a space")
            T.expect(parse("mailto:a@.example") == nil, "a leading dot")
            T.expect(parse("https://example.com") == nil, "not a mailto")
            let long = String(repeating: "a", count: 300) + "@x.example"
            T.expect(parse("mailto:" + long) == nil, "absurdly long")
        }

        T.suite("Mailto: a run routes to the sheet, not to the system") {
            let base = URL(string: "https://example.com/story")!
            func target(_ href: String) -> ReaderBlock.Run.Target? {
                ReaderBlock.Run(text: "write in", bold: false, italic: false,
                                code: false, href: href).target(relativeTo: base)
            }
            // Still a link, so it is still drawn and still clickable.
            guard case .email(let mail)? = target("mailto:desk@paper.example") else {
                T.expect(false, "a mailto is an email target")
                return
            }
            T.equal(mail.recipients, "desk@paper.example", "with the address parsed")
            // And it must NOT come back as something openable directly.
            T.expect(ReaderBlock.Run(text: "x", bold: false, italic: false, code: false,
                                     href: "mailto:desk@paper.example")
                        .destination(relativeTo: base) == nil,
                     "destination() still refuses it, so nothing opens it by accident")
            guard case .web? = target("https://real.example/page") else {
                T.expect(false, "a web link is a web target")
                return
            }
            T.expect(target("file:///etc/passwd") == nil, "and file:// is neither")
        }
    }
}
