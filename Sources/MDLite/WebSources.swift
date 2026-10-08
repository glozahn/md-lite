import Foundation

/// Reading from the web: Markdown (and other text) behind a link, and RSS or Atom feeds shown as a document.
/// One HTTPS request per open, no cookies, nothing kept.
enum WebSources {
    struct Page {
        /// Text to show: the file itself, or Markdown built from a feed.
        let text: String
        /// Where the text really came from, after redirects and GitHub rewriting.
        let source: URL
        let isFeed: Bool
    }

    enum Failure: Error {
        case notWeb, status(Int), tooLarge, notText
    }

    static let limit = 5_000_000

    static func isWeb(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "https" || scheme == "http"
    }

    /// A pasted string that is a single web link, if any.
    static func link(in text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isWhitespace), let url = URL(string: trimmed), isWeb(url), url.host != nil else { return nil }
        return url
    }

    /// GitHub pages for files and gists show HTML around the file; their raw versions are the file.
    static func rawURL(for url: URL) -> URL {
        guard let host = url.host?.lowercased() else { return url }
        let parts = url.path.split(separator: "/").map(String.init)
        if host == "github.com" || host == "www.github.com" {
            // github.com/owner/repo/blob/branch/path → raw.githubusercontent.com/owner/repo/branch/path
            if parts.count >= 5, parts[2] == "blob" || parts[2] == "raw" {
                let path = ([parts[0], parts[1]] + parts[3...]).joined(separator: "/")
                return URL(string: "https://raw.githubusercontent.com/" + path) ?? url
            }
            // github.com/owner/repo → the repository's README
            if parts.count == 2 {
                return URL(string: "https://raw.githubusercontent.com/\(parts[0])/\(parts[1])/HEAD/README.md") ?? url
            }
        }
        if host == "gist.github.com", parts.count >= 2 {
            return URL(string: "https://gist.githubusercontent.com/\(parts[0])/\(parts[1])/raw") ?? url
        }
        return url
    }

    static func fetch(_ url: URL) async throws -> Page {
        guard isWeb(url) else { throw Failure.notWeb }
        let target = rawURL(for: url)
        var request = URLRequest(url: target, timeoutInterval: 20)
        request.setValue("text/markdown, text/plain, application/rss+xml, application/atom+xml, application/xml;q=0.9, */*;q=0.5",
                         forHTTPHeaderField: "Accept")
        let session = URLSession(configuration: .ephemeral)
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw Failure.status(http.statusCode) }
        guard data.count <= limit else { throw Failure.tooLarge }
        let source = response.url ?? target
        let type = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        if looksLikeFeed(data, contentType: type), let markdown = FeedReader.markdown(from: data, source: source) {
            return Page(text: markdown, source: source, isFeed: true)
        }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
              !text.contains("\u{0}") else { throw Failure.notText }
        return Page(text: text, source: source, isFeed: false)
    }

    private static func looksLikeFeed(_ data: Data, contentType: String) -> Bool {
        if contentType.contains("rss") || contentType.contains("atom") { return true }
        let head = String(decoding: data.prefix(1500), as: UTF8.self).lowercased()
        return head.contains("<rss") || (head.contains("<feed") && head.contains("atom"))
    }
}

/// RSS 2.0 and Atom, turned into Markdown: the feed's title, then each entry with its date, summary and link.
final class FeedReader: NSObject, XMLParserDelegate {
    private struct Entry { var title = "", link = "", date = "", summary = "" }

    private var feedTitle = ""
    private var feedSummary = ""
    private var entries: [Entry] = []
    private var current: Entry?
    private var text = ""
    private var insideEntry = false

    static func markdown(from data: Data, source: URL, limit: Int = 40) -> String? {
        let reader = FeedReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.shouldResolveExternalEntities = false
        guard parser.parse() || !reader.entries.isEmpty, !reader.entries.isEmpty || !reader.feedTitle.isEmpty else { return nil }
        var lines = ["# " + (reader.feedTitle.isEmpty ? (source.host ?? "Feed") : literal(reader.feedTitle)), ""]
        if !reader.feedSummary.isEmpty { lines += ["*" + literal(reader.feedSummary) + "*", ""] }
        for entry in reader.entries.prefix(limit) {
            let title = literal(entry.title).isEmpty ? "—" : literal(entry.title)
            let link = entry.link.trimmingCharacters(in: .whitespacesAndNewlines)
            lines.append("## " + (link.isEmpty ? title : "[\(title)](\(link))"))
            if !entry.date.isEmpty { lines += ["", "<sub>" + clean(entry.date) + "</sub>"] }
            let summary = literal(stripTags(entry.summary))
            if !summary.isEmpty { lines += ["", summary.count > 420 ? String(summary.prefix(420)) + "…" : summary] }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        let element = name.lowercased()
        text = ""
        if element == "item" || element == "entry" {
            insideEntry = true
            current = Entry()
        } else if element == "link", insideEntry, let href = attributes["href"],
                  attributes["rel"] == nil || attributes["rel"] == "alternate" {
            current?.link = href   // Atom keeps the link in an attribute
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, foundCDATA block: Data) { text += String(decoding: block, as: UTF8.self) }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let element = name.lowercased()
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if insideEntry, current != nil {
            switch element {
            case "title": current?.title = value
            case "link": if !value.isEmpty { current?.link = value }
            case "pubdate", "published", "updated", "dc:date": if current?.date.isEmpty == true { current?.date = value }
            case "description", "summary", "content", "content:encoded":
                if current?.summary.isEmpty == true || element == "description" { current?.summary = value }
            case "item", "entry":
                if let current { entries.append(current) }
                current = nil
                insideEntry = false
            default: break
            }
        } else {
            switch element {
            case "title": if feedTitle.isEmpty { feedTitle = value }
            case "description", "subtitle": if feedSummary.isEmpty { feedSummary = value }
            default: break
            }
        }
        text = ""
    }

    /// Feed text shown as text: no HTML and no link syntax sneaks in from someone else's feed.
    static func literal(_ value: String) -> String {
        clean(value).replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
    }

    static func stripTags(_ html: String) -> String {
        html.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
    }

    /// Decodes the common entities and folds whitespace; Markdown punctuation stays as text.
    static func clean(_ value: String) -> String {
        var result = value
        for (entity, character) in [("&nbsp;", " "), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
                                    ("&lt;", "<"), ("&gt;", ">"), ("&amp;", "&")] {
            result = result.replacingOccurrences(of: entity, with: character)
        }
        result = result.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
