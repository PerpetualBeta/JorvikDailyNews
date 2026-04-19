import Foundation

/// Parses an OPML subscription list into candidate feed entries. Supports
/// nested `<outline>` categorisation: an outline without `xmlUrl` is treated
/// as a section whose title becomes the `section` of each feed entry
/// nested beneath it.
struct OPMLEntry {
    let url: URL
    let title: String?
    let section: String
}

final class OPMLImporter {
    func parse(data: Data) -> [OPMLEntry] {
        let parser = XMLParser(data: data)
        let delegate = OPMLDelegate()
        parser.delegate = delegate
        guard parser.parse() else { return delegate.entries }
        return delegate.entries
    }
}

private final class OPMLDelegate: NSObject, XMLParserDelegate {
    var entries: [OPMLEntry] = []
    private var sectionStack: [String] = []
    // Parallel stack: true if the matching outline was a category (pushed
    // onto sectionStack), false if it was a feed (nothing to pop).
    private var wasCategory: [Bool] = []

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard elementName.lowercased() == "outline" else { return }

        let xmlUrl = attributeDict["xmlUrl"] ?? attributeDict["xmlurl"] ?? attributeDict["xmlURL"]
        let text = (attributeDict["text"] ?? attributeDict["title"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let urlString = xmlUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
           let url = URL(string: urlString),
           let scheme = url.scheme, scheme == "http" || scheme == "https" {
            let section = sectionStack.last ?? "Imported"
            entries.append(OPMLEntry(url: url, title: text, section: section))
            wasCategory.append(false)
        } else {
            let name = (text?.isEmpty == false ? text! : "Imported")
            sectionStack.append(name)
            wasCategory.append(true)
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard elementName.lowercased() == "outline" else { return }
        guard let wasCat = wasCategory.popLast() else { return }
        if wasCat { _ = sectionStack.popLast() }
    }
}
