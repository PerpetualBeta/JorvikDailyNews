import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Serialises the user's feed list into an OPML 2.0 subscription document.
/// Sections become parent `<outline>` elements, with feeds nested beneath —
/// round-trippable with `OPMLImporter`.
enum OPMLExporter {
    static func export(feeds: [Feed]) -> String {
        let bySection = Dictionary(grouping: feeds) { $0.section }
        let orderedSections = bySection.keys.sorted { $0.lowercased() < $1.lowercased() }

        var xml = ""
        xml += "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        xml += "<opml version=\"2.0\">\n"
        xml += "  <head>\n"
        xml += "    <title>Jorvik Daily News subscriptions</title>\n"
        xml += "    <dateCreated>\(isoDate(Date()))</dateCreated>\n"
        xml += "  </head>\n"
        xml += "  <body>\n"

        for section in orderedSections {
            xml += "    <outline text=\"\(escape(section))\" title=\"\(escape(section))\">\n"
            let feedsInSection = (bySection[section] ?? [])
                .sorted { ($0.title ?? $0.url.absoluteString).lowercased() < ($1.title ?? $1.url.absoluteString).lowercased() }
            for feed in feedsInSection {
                let label = feed.title ?? feed.url.host ?? feed.url.absoluteString
                xml += "      <outline type=\"rss\" text=\"\(escape(label))\" title=\"\(escape(label))\" xmlUrl=\"\(escape(feed.url.absoluteString))\"/>\n"
            }
            xml += "    </outline>\n"
        }

        xml += "  </body>\n"
        xml += "</opml>\n"
        return xml
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func isoDate(_ d: Date) -> String {
        ISO8601DateFormatter().string(from: d)
    }
}

/// FileDocument wrapper so SwiftUI's `.fileExporter` can write the OPML.
struct OPMLDocument: FileDocument {
    static var readableContentTypes: [UTType] {
        var types: [UTType] = [.xml]
        if let opml = UTType(filenameExtension: "opml") { types.insert(opml, at: 0) }
        return types
    }

    static var writableContentTypes: [UTType] { readableContentTypes }

    let text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.featureUnsupported)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
