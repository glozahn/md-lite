import Foundation
import Markdown

/// Converts swift-markdown line/column locations (UTF-8 columns) into UTF-16 offsets.
struct SourceMap {
    private let bytes: [UInt8]
    private let lineStarts8: [Int]
    private let lineStarts16: [Int]
    let length: Int

    init(_ string: String) {
        bytes = Array(string.utf8)
        var starts8 = [0], starts16 = [0], units = 0
        for (index, byte) in bytes.enumerated() {
            units += SourceMap.width(byte)
            if byte == 0x0A { starts8.append(index + 1); starts16.append(units) }
        }
        lineStarts8 = starts8
        lineStarts16 = starts16
        length = units
    }

    private static func width(_ byte: UInt8) -> Int { byte & 0xC0 == 0x80 ? 0 : (byte >= 0xF0 ? 2 : 1) }

    func offset(_ location: SourceLocation) -> Int {
        guard location.line >= 1 else { return 0 }
        guard location.line <= lineStarts8.count else { return length }
        let start = lineStarts8[location.line - 1]
        var units = lineStarts16[location.line - 1]
        let end = min(bytes.count, start + max(0, location.column - 1))
        var index = start
        while index < end { units += SourceMap.width(bytes[index]); index += 1 }
        return units
    }

    func range(_ range: SourceRange?) -> NSRange? {
        guard let range else { return nil }
        let start = offset(range.lowerBound), end = offset(range.upperBound)
        guard end >= start else { return nil }
        return NSRange(location: start, length: end - start)
    }
}

enum HTMLToken: Equatable {
    case open(name: String, attributes: [String: String], selfClosing: Bool, range: Range<String.Index>)
    case close(name: String)
    case text(String)
    case comment
}

enum HTML {
    static let voidElements: Set<String> = ["img", "br", "hr", "source", "input", "meta", "link", "wbr", "col", "area", "base", "embed", "param", "track"]
    /// GFM "disallowed raw HTML" plus elements that never render as text.
    static let hiddenElements: Set<String> = ["script", "style", "title", "textarea", "xmp", "iframe", "noembed", "noframes",
                                              "plaintext", "template", "head", "object", "select", "button", "canvas"]
    static let blockElements: Set<String> = ["p", "div", "center", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "pre", "ul", "ol",
                                             "li", "table", "thead", "tbody", "tfoot", "tr", "td", "th", "details", "summary", "section",
                                             "article", "header", "footer", "figure", "figcaption", "nav", "main", "aside", "dl", "dt",
                                             "dd", "hr", "address", "picture", "caption"]

    private static let tagPattern = try! NSRegularExpression(
        pattern: #"<!--[\s\S]*?(?:-->|$)|<![^>]*>|<\?[\s\S]*?\?>|<(/?)([A-Za-z][A-Za-z0-9-]*)((?:\s+[^\s"'>/=]+(?:\s*=\s*(?:"[^"]*"|'[^']*'|[^\s"'=<>`]+))?)*)\s*(/?)>"#)
    private static let attributePattern = try! NSRegularExpression(
        pattern: #"([^\s"'>/=]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+)))?"#)

    static func tokenize(_ html: String) -> [HTMLToken] {
        var tokens: [HTMLToken] = []
        var cursor = html.startIndex
        let whole = NSRange(html.startIndex..., in: html)
        for match in tagPattern.matches(in: html, range: whole) {
            guard let range = Range(match.range, in: html) else { continue }
            if cursor < range.lowerBound { tokens.append(.text(String(html[cursor..<range.lowerBound]))) }
            cursor = range.upperBound
            guard let nameRange = Range(match.range(at: 2), in: html) else { tokens.append(.comment); continue }
            let name = html[nameRange].lowercased()
            if let slash = Range(match.range(at: 1), in: html), !html[slash].isEmpty {
                tokens.append(.close(name: name))
            } else {
                let attributeText = Range(match.range(at: 3), in: html).map { String(html[$0]) } ?? ""
                let selfClosing = Range(match.range(at: 4), in: html).map { !html[$0].isEmpty } ?? false
                tokens.append(.open(name: name, attributes: attributes(attributeText), selfClosing: selfClosing || voidElements.contains(name), range: range))
            }
        }
        if cursor < html.endIndex { tokens.append(.text(String(html[cursor...]))) }
        return tokens
    }

    static func attributes(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for match in attributePattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let nameRange = Range(match.range(at: 1), in: text) else { continue }
            var value = ""
            for group in 2...4 { if let r = Range(match.range(at: group), in: text) { value = String(text[r]); break } }
            result[text[nameRange].lowercased()] = decodeEntities(value)
        }
        return result
    }

    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}", "copy": "©", "reg": "®",
        "trade": "™", "hellip": "…", "mdash": "—", "ndash": "–", "laquo": "«", "raquo": "»", "middot": "·", "bull": "•",
        "rarr": "→", "larr": "←", "uarr": "↑", "darr": "↓", "harr": "↔", "times": "×", "divide": "÷", "deg": "°",
        "plusmn": "±", "para": "¶", "sect": "§", "euro": "€", "pound": "£", "yen": "¥", "cent": "¢", "check": "✓",
        "ensp": "\u{2002}", "emsp": "\u{2003}", "thinsp": "\u{2009}", "zwj": "\u{200D}", "zwnj": "\u{200C}",
        "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "iexcl": "¡", "iquest": "¿", "hearts": "♥", "star": "☆"
    ]
    private static let entityPattern = try! NSRegularExpression(pattern: "&(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[A-Za-z][A-Za-z0-9]{1,31});")

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let ns = text as NSString
        var result = ""
        var last = 0
        for match in entityPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let body = ns.substring(with: match.range(at: 1))
            var replacement: String?
            if body.hasPrefix("#x") || body.hasPrefix("#X") {
                replacement = UInt32(body.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else if body.hasPrefix("#") {
                replacement = UInt32(body.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else {
                replacement = named[body] ?? named[body.lowercased()]
            }
            guard let replacement else { continue }
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last)) + replacement
            last = NSMaxRange(match.range)
        }
        return result + ns.substring(from: last)
    }
}

enum GFM {
    /// GitHub heading anchor: lowercase, punctuation removed, spaces become hyphens.
    static func slug(_ title: String) -> String {
        var out = ""
        for scalar in title.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" { out.unicodeScalars.append(scalar) }
            else if scalar == " " { out.append("-") }
        }
        return out
    }

    private static let autolinkPattern = try! NSRegularExpression(
        pattern: #"(?:(?:https?|ftp)://|www\.)[^\s<]+|[A-Za-z0-9._+\-]+@[A-Za-z0-9\-_]+(?:\.[A-Za-z0-9\-_]+)+"#, options: [.caseInsensitive])

    /// GFM extended autolinks (www., http(s)://, ftp:// and e-mail addresses) found in plain text.
    static func autolinks(in text: String) -> [(NSRange, URL)] {
        guard text.contains(".") else { return [] }
        let ns = text as NSString
        var links: [(NSRange, URL)] = []
        for match in autolinkPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if match.range.location > 0 {
                let before = ns.character(at: match.range.location - 1)
                guard let scalar = Unicode.Scalar(before),
                      CharacterSet.whitespacesAndNewlines.contains(scalar) || "*_~(\"'".unicodeScalars.contains(scalar) else { continue }
            }
            var candidate = ns.substring(with: match.range)
            let isEmail = candidate.contains("@") && !candidate.contains("://") && !candidate.lowercased().hasPrefix("www.")
            if isEmail {
                while let last = candidate.last, ".".contains(last) { candidate.removeLast() }
                guard let last = candidate.last, last != "-", last != "_" else { continue }
                guard let url = URL(string: "mailto:" + candidate) else { continue }
                links.append((NSRange(location: match.range.location, length: (candidate as NSString).length), url))
                continue
            }
            var trimmed = true
            while trimmed {
                trimmed = false
                if let last = candidate.last, "?!.,:*_~'\"".contains(last) { candidate.removeLast(); trimmed = true }
                if candidate.hasSuffix(")"), candidate.filter({ $0 == ")" }).count > candidate.filter({ $0 == "(" }).count {
                    candidate.removeLast(); trimmed = true
                }
                if candidate.hasSuffix(";"), let entity = candidate.range(of: #"&[A-Za-z0-9]+;$"#, options: .regularExpression) {
                    candidate.removeSubrange(entity); trimmed = true
                }
            }
            let host = candidate.replacingOccurrences(of: #"^(?:(?:https?|ftp)://)"#, with: "", options: [.regularExpression, .caseInsensitive])
                .split(whereSeparator: { "/?#".contains($0) }).first.map(String.init) ?? ""
            guard host.contains("."), !host.hasSuffix("."), !host.split(separator: ".").suffix(2).contains(where: { $0.contains("_") }) else { continue }
            let target = candidate.lowercased().hasPrefix("www.") ? "http://" + candidate : candidate
            guard let url = URL(string: target) ?? URL(string: target.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? "") else { continue }
            links.append((NSRange(location: match.range.location, length: (candidate as NSString).length), url))
        }
        return links
    }

    enum Alert: String, CaseIterable {
        case note, tip, important, warning, caution
        var symbol: String {
            switch self {
            case .note: return "info.circle"
            case .tip: return "lightbulb"
            case .important: return "exclamationmark.bubble"
            case .warning: return "exclamationmark.triangle"
            case .caution: return "exclamationmark.octagon"
            }
        }
        var title: String {
            switch self {
            case .note: return "Nota"
            case .tip: return "Consejo"
            case .important: return "Importante"
            case .warning: return "Advertencia"
            case .caution: return "Precaución"
            }
        }
    }

    /// Detects GitHub alert syntax (`> [!NOTE]`) in the first line of a block quote.
    static func alert(in quote: BlockQuote) -> Alert? {
        guard let paragraph = quote.child(at: 0) as? Paragraph else { return nil }
        var marker = ""
        for child in paragraph.children {
            if child is SoftBreak || child is LineBreak { break }
            guard let text = child as? Markdown.Text else { return nil }
            marker += text.string
        }
        let trimmed = marker.trimmingCharacters(in: .whitespaces).uppercased()
        guard trimmed.hasPrefix("[!"), trimmed.hasSuffix("]") else { return nil }
        return Alert(rawValue: String(trimmed.dropFirst(2).dropLast()).lowercased())
    }

    /// Replaces YAML front matter with blank lines so line numbers stay valid for the parser.
    static func frontMatter(in source: String) -> (yaml: String, masked: String)? {
        guard source.hasPrefix("---\n") || source.hasPrefix("---\r\n") else { return nil }
        let lines = source.components(separatedBy: "\n")
        guard lines.count > 2, let end = lines.dropFirst().firstIndex(where: {
            let line = $0.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            return line == "---" || line == "..."
        }) else { return nil }
        let yaml = lines[1..<end].joined(separator: "\n")
        let masked = Array(repeating: "", count: end + 1) + lines[(end + 1)...]
        return (yaml, masked.joined(separator: "\n"))
    }
}
