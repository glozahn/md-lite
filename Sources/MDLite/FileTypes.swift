import Foundation
import UniformTypeIdentifiers

/// How a file is shown. Markdown is rendered; everything else is shown as it is, styled for its kind.
enum DocumentKind: Equatable {
    case markdown
    /// Source code, scripts and configuration, highlighted for `language`.
    case code(language: String?)
    /// Prose in a .txt: kept as written, in the reading font.
    case text
    /// Comma- or tab-separated values, shown as a table.
    case table(separator: Character)
    /// A log: monospaced, read-only, and it follows the end of the file as it grows.
    case log

    var isMarkdown: Bool { self == .markdown }
    var isReadOnly: Bool { self == .log }
    var isMonospaced: Bool {
        switch self {
        case .markdown, .text: return false
        case .code, .table, .log: return true
        }
    }

    /// Highlighting language for the editor and the reader.
    var language: String? {
        switch self {
        case .code(let language): return language
        default: return nil
        }
    }

    /// Short label for the footer, e.g. "SQL" or "CSV".
    var label: String? {
        switch self {
        case .markdown: return nil
        case .code(let language): return (language ?? "text").uppercased()
        case .text: return "TXT"
        case .table(let separator): return separator == "\t" ? "TSV" : "CSV"
        case .log: return "LOG"
        }
    }

    /// SF Symbol shown next to the file in tabs and the sidebar.
    var symbol: String {
        switch self {
        case .markdown: return "doc.text"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .text: return "doc.plaintext"
        case .table: return "tablecells"
        case .log: return "list.bullet.rectangle"
        }
    }
}

enum FileTypes {
    static let markdown: Set<String> = ["md", "markdown", "mdown", "mkd"]

    /// Extension → highlighting language (names understood by SyntaxHighlighter).
    static let code: [String: String] = [
        "sql": "sql", "psql": "sql",
        "sh": "shell", "bash": "shell", "zsh": "shell", "fish": "shell", "command": "shell",
        "json": "json", "jsonc": "json", "geojson": "json",
        "yaml": "yaml", "yml": "yaml",
        "toml": "ini", "ini": "ini", "conf": "ini", "cfg": "ini", "env": "ini", "properties": "ini",
        "xml": "xml", "plist": "xml", "svg": "xml",
        "py": "python", "rb": "ruby", "pl": "perl", "r": "r",
        "js": "javascript", "mjs": "javascript", "cjs": "javascript", "jsx": "javascript",
        "ts": "typescript", "tsx": "typescript",
        "swift": "swift", "go": "go", "rs": "rust", "java": "java", "kt": "kotlin", "kts": "kotlin",
        "c": "c", "h": "c", "cpp": "cpp", "cc": "cpp", "hpp": "cpp", "m": "objectivec", "cs": "csharp",
        "php": "php", "dart": "dart", "scala": "scala", "lua": "lua", "ex": "elixir", "exs": "elixir",
        "css": "css", "scss": "css", "less": "css",
        "html": "html", "htm": "html", "vue": "html",
        "graphql": "graphql", "gql": "graphql",
        "diff": "diff", "patch": "diff",
        "ps1": "powershell", "nix": "nix", "zig": "zig", "jl": "julia"
    ]

    /// Files known by their whole name rather than an extension.
    static let names: [String: String] = [
        "dockerfile": "dockerfile", "containerfile": "dockerfile", "makefile": "makefile", "gnumakefile": "makefile",
        "gemfile": "ruby", "rakefile": "ruby", "podfile": "ruby", "brewfile": "ruby", "procfile": "shell",
        ".env": "ini", ".gitignore": "shell", ".gitattributes": "shell", ".editorconfig": "ini",
        ".zshrc": "shell", ".bashrc": "shell", ".bash_profile": "shell", ".profile": "shell"
    ]

    static let text: Set<String> = ["txt", "text"]
    static let tables: [String: Character] = ["csv": ",", "tsv": "\t"]
    static let logs: Set<String> = ["log"]

    static func kind(of url: URL) -> DocumentKind? {
        let name = url.lastPathComponent.lowercased()
        let ext = url.pathExtension.lowercased()
        if markdown.contains(ext) { return .markdown }
        if let separator = tables[ext] { return .table(separator: separator) }
        if logs.contains(ext) { return .log }
        if text.contains(ext) { return .text }
        if let language = code[ext] { return .code(language: language) }
        if let language = names[name] { return .code(language: language) }
        // ".env.local", "Dockerfile.dev" and friends.
        if name.hasPrefix(".env") { return .code(language: "ini") }
        if name.hasPrefix("dockerfile") { return .code(language: "dockerfile") }
        return nil
    }

    static func isSupported(_ url: URL) -> Bool { kind(of: url) != nil }

    /// Types offered by the Open panel.
    static var contentTypes: [UTType] {
        var types: [UTType] = [.plainText, .sourceCode, .script, .shellScript, .json, .xml, .yaml,
                               .commaSeparatedText, .tabSeparatedText, .log, .propertyList]
        let extensions = markdown.union(text).union(logs).union(tables.keys).union(code.keys)
        types += extensions.compactMap { UTType(filenameExtension: $0) }
        return types
    }

    // MARK: Turning files into something to read

    /// Markdown for a CSV/TSV file: a GitHub table, capped so very large files stay quick.
    static func markdownTable(from text: String, separator: Character, limit: Int = 1000) -> String {
        let rows = parseDelimited(text, separator: separator)
        guard let header = rows.first, !header.isEmpty else { return "" }
        let width = rows.prefix(limit + 1).map(\.count).max() ?? header.count
        func line(_ cells: [String]) -> String {
            let padded = cells + Array(repeating: "", count: max(0, width - cells.count))
            return "| " + padded.map(escapeCell).joined(separator: " | ") + " |"
        }
        var lines = [line(header), "|" + String(repeating: " --- |", count: width)]
        let body = rows.dropFirst()
        lines += body.prefix(limit).map(line)
        var output = lines.joined(separator: "\n")
        if body.count > limit {
            output += "\n\n*\(limit) / \(body.count)*"
        }
        return output
    }

    /// RFC 4180: quoted fields may hold separators, line breaks and doubled quotes.
    static func parseDelimited(_ text: String, separator: Character) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var iterator = text.makeIterator()
        var pending: Character? = nil
        func next() -> Character? {
            if let character = pending { pending = nil; return character }
            return iterator.next()
        }
        while let character = next() {
            if quoted {
                if character == "\"" {
                    if let following = next() {
                        if following == "\"" { field.append("\"") } else { quoted = false; pending = following }
                    } else { quoted = false }
                } else {
                    field.append(character)
                }
            } else if character == "\"" && field.isEmpty {
                quoted = true
            } else if character == separator {
                row.append(field); field = ""
            } else if character == "\n" || character == "\r\n" || character == "\r" {
                row.append(field); field = ""
                rows.append(row); row = []
            } else {
                field.append(character)
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows.filter { !($0.count == 1 && $0[0].isEmpty) }
    }

    private static func escapeCell(_ cell: String) -> String {
        var escaped = ""
        for character in cell.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ") {
            if "\\`*_{}[]<>#|~".contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
        return escaped.trimmingCharacters(in: .whitespaces)
    }

    /// Minified JSON gets line breaks and indentation, keeping every key where it was.
    /// Already formatted or invalid JSON is returned untouched.
    static func prettyJSON(_ text: String) -> String {
        guard text.count > 200, !text.prefix(2000).contains("\n"),
              let data = text.data(using: .utf8), (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil else {
            return text
        }
        var output = ""
        var depth = 0
        var inString = false
        var escaped = false
        func newline() { output.append("\n"); output.append(String(repeating: "  ", count: depth)) }
        for character in text {
            if inString {
                output.append(character)
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { inString = false }
                continue
            }
            switch character {
            case "\"": inString = true; output.append(character)
            case "{", "[": output.append(character); depth += 1; newline()
            case "}", "]": depth = max(0, depth - 1); newline(); output.append(character)
            case ",": output.append(character); newline()
            case ":": output.append(": ")
            case " ", "\n", "\t", "\r": continue
            default: output.append(character)
            }
        }
        // Empty containers read better on one line.
        return output.replacingOccurrences(of: #"\{\s+\}"#, with: "{}", options: .regularExpression)
            .replacingOccurrences(of: #"\[\s+\]"#, with: "[]", options: .regularExpression)
    }
}
