import AppKit

/// Small regex highlighter for fenced code. Covers common languages without extra dependencies.
enum SyntaxHighlighter {
    private struct Grammar {
        let regex: NSRegularExpression
        let colors: [NSColor]   // one color per capture group
    }

    private static var cache: [String: Grammar?] = [:]

    private static let aliases: [String: String] = [
        "js": "javascript", "jsx": "javascript", "mjs": "javascript", "cjs": "javascript", "ts": "typescript", "tsx": "typescript",
        "py": "python", "rb": "ruby", "sh": "shell", "bash": "shell", "zsh": "shell", "console": "shell", "shellscript": "shell",
        "fish": "shell", "yml": "yaml", "kt": "kotlin", "kts": "kotlin", "rs": "rust", "golang": "go", "cs": "csharp", "c#": "csharp",
        "c++": "cpp", "cc": "cpp", "h": "c", "hpp": "cpp", "objc": "objectivec", "objective-c": "objectivec", "m": "objectivec",
        "htm": "html", "xhtml": "html", "svg": "xml", "plist": "xml", "vue": "html", "jsonc": "json", "json5": "json",
        "patch": "diff", "docker": "dockerfile", "scss": "css", "less": "css", "sass": "css", "psql": "sql", "mysql": "sql",
        "postgres": "sql", "toml": "ini", "conf": "ini", "env": "ini", "md": "markdown", "gql": "graphql"
    ]

    private static let cFamily: Set<String> = ["swift", "javascript", "typescript", "java", "kotlin", "c", "cpp", "csharp", "go",
                                               "rust", "dart", "scala", "php", "objectivec", "groovy", "graphql", "zig"]
    private static let hashFamily: Set<String> = ["python", "ruby", "shell", "perl", "r", "elixir", "powershell", "makefile", "nix", "julia"]

    private static let keywords: [String: String] = [
        "swift": "actor any as associatedtype async await break case catch class continue default defer deinit do else enum extension fallthrough false fileprivate final for func guard if import in init inout internal is lazy let mutating nil nonisolated open operator override private protocol public repeat rethrows return self Self some static struct subscript super switch throw throws true try typealias var weak where while",
        "javascript": "as async await break case catch class const continue debugger default delete do else export extends false finally for from function get if import in instanceof let new null of return set static super switch this throw true try typeof undefined var void while with yield",
        "typescript": "abstract any as asserts async await boolean break case catch class const constructor continue declare default delete do else enum export extends false finally for from function get if implements import in infer instanceof interface is keyof let module namespace never new null number object of private protected public readonly return satisfies set static string super switch symbol this throw true try type typeof undefined unique unknown var void while yield",
        "java": "abstract assert boolean break byte case catch char class const continue default do double else enum extends false final finally float for goto if implements import instanceof int interface long native new null package private protected public record return short static super switch synchronized this throw throws true try var void volatile while",
        "kotlin": "as break class companion const continue data do else enum false for fun if import in interface internal is lateinit null object open override package private protected public return sealed super suspend this throw true try typealias val var when while",
        "c": "auto break case char const continue default do double else enum extern float for goto if inline int long NULL register return short signed sizeof static struct switch typedef union unsigned void volatile while #include #define #ifdef #ifndef #endif #if #else #pragma",
        "cpp": "auto bool break case catch char class const constexpr continue default delete do double else enum explicit extern false float for friend if inline int long namespace new noexcept nullptr operator private protected public return short signed sizeof static struct switch template this throw true try typedef typename union unsigned using virtual void volatile while #include #define #ifdef #ifndef #endif #if #else #pragma",
        "csharp": "abstract as async await base bool break case catch char class const continue decimal default delegate do double else enum event explicit false finally float for foreach get if implicit in int interface internal is lock long namespace new null object operator out override params private protected public readonly record ref return sealed set short static string struct switch this throw true try typeof uint using var virtual void while",
        "go": "break case chan const continue default defer else fallthrough false for func go goto if import interface iota map nil package range return select struct switch true type var",
        "rust": "as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait true type unsafe use where while",
        "dart": "abstract as async await break case catch class const continue default do else enum extends false final finally for if implements import in is late new null required return static super switch this throw true try var void while with yield",
        "scala": "abstract case catch class def do else extends false final finally for if implicit import lazy match new null object override package private protected return sealed super this throw trait true try type val var while with yield",
        "php": "abstract and array as break case catch class clone const continue declare default do echo else elseif empty enum extends false final finally fn for foreach function global if implements include instanceof interface isset list match namespace new null or print private protected public readonly require return static switch this throw trait true try unset use var while yield",
        "objectivec": "@interface @implementation @end @property @synthesize @protocol @class @selector @import BOOL NO YES nil self super id if else for while return void int float double char const static struct typedef #import #include",
        "groovy": "def class if else for while return new null true false import package",
        "graphql": "query mutation subscription fragment on type input enum interface union scalar schema extend implements directive true false null",
        "zig": "const var fn pub if else while for return try catch defer errdefer struct enum union comptime true false null undefined",
        "python": "and as assert async await break case class continue def del elif else except False finally for from global if import in is lambda match None nonlocal not or pass raise return self True try while with yield",
        "ruby": "alias and begin break case class def defined? do else elsif end ensure false for if in module next nil not or redo rescue retry return self super then true undef unless until when while yield require attr_accessor",
        "shell": "if then else elif fi for while until do done case esac function in return export local readonly declare echo exit set unset source alias cd sudo",
        "perl": "my our local sub if elsif else unless while until for foreach return use package",
        "r": "if else repeat while function for in next break TRUE FALSE NULL Inf NaN NA",
        "elixir": "def defp defmodule do end if else unless case cond fn when true false nil import alias use require",
        "powershell": "begin break catch continue data do dynamicparam else elseif end exit filter finally for foreach from function if in param process return switch throw trap try until while",
        "makefile": "ifeq ifneq ifdef ifndef else endif include define endef export",
        "nix": "let in with rec inherit if then else import true false null",
        "julia": "function end if elseif else for while return module using import struct mutable true false nothing begin let",
        "sql": "add all alter and as asc begin between by case check column commit constraint create cross database default delete desc distinct drop else end exists false foreign from full group having if in index inner insert into is join key left like limit not null offset on or order outer primary references returning right rollback select set table then transaction true truncate union unique update using values view when where with",
        "yaml": "true false null yes no on off",
        "json": "true false null",
        "ini": "true false",
        "dockerfile": "FROM RUN CMD LABEL EXPOSE ENV ADD COPY ENTRYPOINT VOLUME USER WORKDIR ARG ONBUILD STOPSIGNAL HEALTHCHECK SHELL AS",
        "css": "important"
    ]

    static func canonical(_ language: String?) -> String? {
        guard let raw = language?.lowercased().trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        return aliases[raw] ?? raw
    }

    private static func words(_ list: String) -> String {
        list.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "|")
    }

    private static func grammar(for language: String) -> Grammar? {
        if let cached = cache[language] { return cached }
        let string = #""(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*'"#
        var parts: [(String, NSColor)] = []
        let kw = keywords[language].map(words)
        switch language {
        case _ where cFamily.contains(language):
            parts.append((#"//[^\n]*|/\*[\s\S]*?\*/"#, MDColors.comment))
            let extra = ["javascript", "typescript", "go", "kotlin", "groovy", "dart", "scala"].contains(language) ? #"|`(?:[^`\\]|\\.)*`"# : ""
            parts.append((language == "swift" ? #""""[\s\S]*?"""|"# + string : string + extra, MDColors.string))
            parts.append((#"(?:@|#)[A-Za-z_]\w*"#, MDColors.attribute))
            if let kw { parts.append(("\\b(?:" + kw + ")\\b", MDColors.keyword)) }
            parts.append((#"\b(?:0[xX][0-9a-fA-F_]+|\d[\d_]*(?:\.\d[\d_]*)?(?:[eE][+-]?\d+)?)\b"#, MDColors.number))
            parts.append((#"\b[A-Z][A-Za-z0-9_]*\b"#, MDColors.type))
            parts.append((#"\b[a-z_][A-Za-z0-9_]*(?=\s*\()"#, MDColors.function))
        case _ where hashFamily.contains(language):
            parts.append((#"#[^\n]*"#, MDColors.comment))
            let triple = language == "python" ? #""""[\s\S]*?"""|'''[\s\S]*?'''|"# : ""
            parts.append((triple + string + (language == "shell" ? #"|`[^`\n]*`"# : ""), MDColors.string))
            if language == "shell" { parts.append((#"\$\{?[A-Za-z_][A-Za-z0-9_]*\}?|\$[0-9@#?*!-]"#, MDColors.attribute)) }
            if language == "python" { parts.append((#"@[A-Za-z_][\w.]*"#, MDColors.attribute)) }
            if let kw { parts.append(("\\b(?:" + kw + ")\\b", MDColors.keyword)) }
            parts.append((#"\b\d[\d_]*(?:\.\d+)?\b"#, MDColors.number))
            parts.append((#"\b[a-z_][A-Za-z0-9_]*(?=\()"#, MDColors.function))
        case "sql":
            parts.append((#"--[^\n]*|/\*[\s\S]*?\*/"#, MDColors.comment))
            parts.append((string, MDColors.string))
            if let kw { parts.append(("(?i)\\b(?:" + kw + ")\\b", MDColors.keyword)) }
            parts.append((#"\b\d+(?:\.\d+)?\b"#, MDColors.number))
        case "json":
            parts.append((#""(?:[^"\\\n]|\\.)*"(?=\s*:)"#, MDColors.type))
            parts.append((#""(?:[^"\\\n]|\\.)*""#, MDColors.string))
            parts.append((#"\b(?:true|false|null)\b"#, MDColors.keyword))
            parts.append((#"-?\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b"#, MDColors.number))
        case "yaml", "ini":
            parts.append((#"(?m)(?:^|\s)[#;][^\n]*"#, MDColors.comment))
            parts.append((#"(?m)^\s*\[[^\]\n]+\]"#, MDColors.keyword))
            parts.append((#"(?m)^[ \t-]*[A-Za-z0-9_.$@-]+(?=\s*[:=])"#, MDColors.type))
            parts.append((string, MDColors.string))
            if let kw { parts.append(("\\b(?:" + kw + ")\\b", MDColors.keyword)) }
            parts.append((#"\b\d+(?:\.\d+)?\b"#, MDColors.number))
        case "html", "xml":
            parts.append((#"<!--[\s\S]*?-->"#, MDColors.comment))
            parts.append((#"</?[A-Za-z][\w:.-]*|/?>"#, MDColors.keyword))
            parts.append((#"\b[A-Za-z_:][\w:.-]*(?==)"#, MDColors.attribute))
            parts.append((string, MDColors.string))
        case "css":
            parts.append((#"/\*[\s\S]*?\*/"#, MDColors.comment))
            parts.append((string, MDColors.string))
            parts.append((#"@[A-Za-z-]+"#, MDColors.keyword))
            parts.append((#"[A-Za-z-]+(?=\s*:[^;{]*;)"#, MDColors.attribute))
            parts.append((#"#[0-9a-fA-F]{3,8}\b|-?\b\d+(?:\.\d+)?(?:px|em|rem|%|vh|vw|s|ms|deg|fr)?\b"#, MDColors.number))
            parts.append((#"[.#][A-Za-z_-][\w-]*"#, MDColors.type))
        case "diff":
            parts.append((#"(?m)^(?:\+\+\+|---)[^\n]*"#, MDColors.meta))
            parts.append((#"(?m)^@@[^\n]*"#, MDColors.meta))
            parts.append((#"(?m)^\+[^\n]*"#, MDColors.added))
            parts.append((#"(?m)^-[^\n]*"#, MDColors.removed))
        case "dockerfile":
            parts.append((#"(?m)#[^\n]*"#, MDColors.comment))
            parts.append((string, MDColors.string))
            if let kw { parts.append(("(?m)^\\s*(?:" + kw + ")\\b", MDColors.keyword)) }
            parts.append((#"\$\{?[A-Za-z_][A-Za-z0-9_]*\}?"#, MDColors.attribute))
        case "markdown":
            parts.append((#"(?m)^#{1,6} [^\n]*"#, MDColors.keyword))
            parts.append((#"`[^`\n]+`"#, MDColors.string))
            parts.append((#"\*\*[^*\n]+\*\*|__[^_\n]+__"#, MDColors.type))
            parts.append((#"\[[^\]\n]*\]\([^)\n]*\)"#, MDColors.function))
        default:
            cache[language] = .some(nil)
            return nil
        }
        let pattern = parts.map { "(" + $0.0 + ")" }.joined(separator: "|")
        let result = (try? NSRegularExpression(pattern: pattern)).map { Grammar(regex: $0, colors: parts.map(\.1)) }
        cache[language] = .some(result)
        return result
    }

    /// Colored token ranges for the code found in `range` of `string`.
    static func tokens(in string: String, range: NSRange, language: String?) -> [(NSRange, NSColor)] {
        guard let language = canonical(language), let grammar = grammar(for: language), range.length > 0,
              range.length < 300_000 else { return [] }
        var result: [(NSRange, NSColor)] = []
        for match in grammar.regex.matches(in: string, range: range) {
            for group in 1...grammar.colors.count where match.range(at: group).location != NSNotFound {
                result.append((match.range(at: group), grammar.colors[group - 1]))
                break
            }
        }
        return result
    }

    /// Applies syntax colors to `range` of `text`, which must contain only the code.
    static func highlight(_ text: NSMutableAttributedString, range: NSRange, language: String?) {
        for (range, color) in tokens(in: text.string, range: range, language: language) {
            text.addAttribute(.foregroundColor, value: color, range: range)
        }
    }
}
