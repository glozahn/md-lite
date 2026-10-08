//! Small regex highlighter for fenced code. Covers common languages without extra dependencies.

use super::Color;
use fancy_regex::Regex;
use std::collections::HashMap;
use std::ops::Range;
use std::sync::{Arc, LazyLock, Mutex};

struct Grammar {
    regex: Regex,
    colors: Vec<Color>,
}

static CACHE: LazyLock<Mutex<HashMap<String, Option<Arc<Grammar>>>>> = LazyLock::new(|| Mutex::new(HashMap::new()));

fn alias(raw: &str) -> &str {
    match raw {
        "js" | "jsx" | "mjs" | "cjs" => "javascript",
        "ts" | "tsx" => "typescript",
        "py" => "python",
        "rb" => "ruby",
        "sh" | "bash" | "zsh" | "console" | "shellscript" | "fish" => "shell",
        "yml" => "yaml",
        "kt" | "kts" => "kotlin",
        "rs" => "rust",
        "golang" => "go",
        "cs" | "c#" => "csharp",
        "c++" | "cc" | "hpp" => "cpp",
        "h" => "c",
        "objc" | "objective-c" | "m" => "objectivec",
        "htm" | "xhtml" | "vue" => "html",
        "svg" | "plist" => "xml",
        "jsonc" | "json5" => "json",
        "patch" => "diff",
        "docker" => "dockerfile",
        "scss" | "less" | "sass" => "css",
        "psql" | "mysql" | "postgres" => "sql",
        "toml" | "conf" | "env" => "ini",
        "md" => "markdown",
        "gql" => "graphql",
        other => other,
    }
}

const C_FAMILY: &[&str] = &[
    "swift", "javascript", "typescript", "java", "kotlin", "c", "cpp", "csharp", "go", "rust", "dart", "scala", "php",
    "objectivec", "groovy", "graphql", "zig",
];
const HASH_FAMILY: &[&str] = &["python", "ruby", "shell", "perl", "r", "elixir", "powershell", "makefile", "nix", "julia"];

fn keywords(language: &str) -> Option<&'static str> {
    Some(match language {
        "swift" => "actor any as associatedtype async await break case catch class continue default defer deinit do else enum extension fallthrough false fileprivate final for func guard if import in init inout internal is lazy let mutating nil nonisolated open operator override private protocol public repeat rethrows return self Self some static struct subscript super switch throw throws true try typealias var weak where while",
        "javascript" => "as async await break case catch class const continue debugger default delete do else export extends false finally for from function get if import in instanceof let new null of return set static super switch this throw true try typeof undefined var void while with yield",
        "typescript" => "abstract any as asserts async await boolean break case catch class const constructor continue declare default delete do else enum export extends false finally for from function get if implements import in infer instanceof interface is keyof let module namespace never new null number object of private protected public readonly return satisfies set static string super switch symbol this throw true try type typeof undefined unique unknown var void while yield",
        "java" => "abstract assert boolean break byte case catch char class const continue default do double else enum extends false final finally float for goto if implements import instanceof int interface long native new null package private protected public record return short static super switch synchronized this throw throws true try var void volatile while",
        "kotlin" => "as break class companion const continue data do else enum false for fun if import in interface internal is lateinit null object open override package private protected public return sealed super suspend this throw true try typealias val var when while",
        "c" => "auto break case char const continue default do double else enum extern float for goto if inline int long NULL register return short signed sizeof static struct switch typedef union unsigned void volatile while #include #define #ifdef #ifndef #endif #if #else #pragma",
        "cpp" => "auto bool break case catch char class const constexpr continue default delete do double else enum explicit extern false float for friend if inline int long namespace new noexcept nullptr operator private protected public return short signed sizeof static struct switch template this throw true try typedef typename union unsigned using virtual void volatile while #include #define #ifdef #ifndef #endif #if #else #pragma",
        "csharp" => "abstract as async await base bool break case catch char class const continue decimal default delegate do double else enum event explicit false finally float for foreach get if implicit in int interface internal is lock long namespace new null object operator out override params private protected public readonly record ref return sealed set short static string struct switch this throw true try typeof uint using var virtual void while",
        "go" => "break case chan const continue default defer else fallthrough false for func go goto if import interface iota map nil package range return select struct switch true type var",
        "rust" => "as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait true type unsafe use where while",
        "dart" => "abstract as async await break case catch class const continue default do else enum extends false final finally for if implements import in is late new null required return static super switch this throw true try var void while with yield",
        "scala" => "abstract case catch class def do else extends false final finally for if implicit import lazy match new null object override package private protected return sealed super this throw trait true try type val var while with yield",
        "php" => "abstract and array as break case catch class clone const continue declare default do echo else elseif empty enum extends false final finally fn for foreach function global if implements include instanceof interface isset list match namespace new null or print private protected public readonly require return static switch this throw trait true try unset use var while yield",
        "objectivec" => "@interface @implementation @end @property @synthesize @protocol @class @selector @import BOOL NO YES nil self super id if else for while return void int float double char const static struct typedef #import #include",
        "groovy" => "def class if else for while return new null true false import package",
        "graphql" => "query mutation subscription fragment on type input enum interface union scalar schema extend implements directive true false null",
        "zig" => "const var fn pub if else while for return try catch defer errdefer struct enum union comptime true false null undefined",
        "python" => "and as assert async await break case class continue def del elif else except False finally for from global if import in is lambda match None nonlocal not or pass raise return self True try while with yield",
        "ruby" => "alias and begin break case class def defined? do else elsif end ensure false for if in module next nil not or redo rescue retry return self super then true undef unless until when while yield require attr_accessor",
        "shell" => "if then else elif fi for while until do done case esac function in return export local readonly declare echo exit set unset source alias cd sudo",
        "perl" => "my our local sub if elsif else unless while until for foreach return use package",
        "r" => "if else repeat while function for in next break TRUE FALSE NULL Inf NaN NA",
        "elixir" => "def defp defmodule do end if else unless case cond fn when true false nil import alias use require",
        "powershell" => "begin break catch continue data do dynamicparam else elseif end exit filter finally for foreach from function if in param process return switch throw trap try until while",
        "makefile" => "ifeq ifneq ifdef ifndef else endif include define endef export",
        "nix" => "let in with rec inherit if then else import true false null",
        "julia" => "function end if elseif else for while return module using import struct mutable true false nothing begin let",
        "sql" => "add all alter and as asc begin between by case check column commit constraint create cross database default delete desc distinct drop else end exists false foreign from full group having if in index inner insert into is join key left like limit not null offset on or order outer primary references returning right rollback select set table then transaction true truncate union unique update using values view when where with",
        "yaml" => "true false null yes no on off",
        "json" => "true false null",
        "ini" => "true false",
        "dockerfile" => "FROM RUN CMD LABEL EXPOSE ENV ADD COPY ENTRYPOINT VOLUME USER WORKDIR ARG ONBUILD STOPSIGNAL HEALTHCHECK SHELL AS",
        "css" => "important",
        _ => return None,
    })
}

pub fn canonical(language: Option<&str>) -> Option<String> {
    let raw = language?.trim().to_lowercase();
    if raw.is_empty() {
        return None;
    }
    Some(alias(&raw).to_string())
}

fn words(list: &str) -> String {
    list.split(' ').map(fancy_regex::escape).collect::<Vec<_>>().join("|")
}

fn grammar(language: &str) -> Option<Arc<Grammar>> {
    if let Some(cached) = CACHE.lock().unwrap().get(language) {
        return cached.clone();
    }
    let string = r#""(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*'"#;
    let kw = keywords(language).map(words);
    let mut parts: Vec<(String, Color)> = Vec::new();
    let mut push = |pattern: &str, color: Color| parts.push((pattern.to_string(), color));
    if C_FAMILY.contains(&language) {
        push(r"//[^\n]*|/\*[\s\S]*?\*/", Color::Comment);
        let extra = if ["javascript", "typescript", "go", "kotlin", "groovy", "dart", "scala"].contains(&language) {
            r"|`(?:[^`\\]|\\.)*`"
        } else {
            ""
        };
        if language == "swift" {
            push(&format!(r#""""[\s\S]*?"""|{string}"#), Color::Str);
        } else {
            push(&format!("{string}{extra}"), Color::Str);
        }
        push(r"(?:@|#)[A-Za-z_]\w*", Color::Attribute);
        if let Some(kw) = &kw {
            push(&format!(r"\b(?:{kw})\b"), Color::Keyword);
        }
        push(r"\b(?:0[xX][0-9a-fA-F_]+|\d[\d_]*(?:\.\d[\d_]*)?(?:[eE][+-]?\d+)?)\b", Color::Number);
        push(r"\b[A-Z][A-Za-z0-9_]*\b", Color::Type);
        push(r"\b[a-z_][A-Za-z0-9_]*(?=\s*\()", Color::Function);
    } else if HASH_FAMILY.contains(&language) {
        push(r"#[^\n]*", Color::Comment);
        let triple = if language == "python" { r#""""[\s\S]*?"""|'''[\s\S]*?'''|"# } else { "" };
        let backtick = if language == "shell" { r"|`[^`\n]*`" } else { "" };
        push(&format!("{triple}{string}{backtick}"), Color::Str);
        if language == "shell" {
            push(r"\$\{?[A-Za-z_][A-Za-z0-9_]*\}?|\$[0-9@#?*!-]", Color::Attribute);
        }
        if language == "python" {
            push(r"@[A-Za-z_][\w.]*", Color::Attribute);
        }
        if let Some(kw) = &kw {
            push(&format!(r"\b(?:{kw})\b"), Color::Keyword);
        }
        push(r"\b\d[\d_]*(?:\.\d+)?\b", Color::Number);
        push(r"\b[a-z_][A-Za-z0-9_]*(?=\()", Color::Function);
    } else {
        match language {
            "sql" => {
                push(r"--[^\n]*|/\*[\s\S]*?\*/", Color::Comment);
                push(string, Color::Str);
                if let Some(kw) = &kw {
                    push(&format!(r"(?i:\b(?:{kw})\b)"), Color::Keyword);
                }
                push(r"\b\d+(?:\.\d+)?\b", Color::Number);
            }
            "json" => {
                push(r#""(?:[^"\\\n]|\\.)*"(?=\s*:)"#, Color::Type);
                push(r#""(?:[^"\\\n]|\\.)*""#, Color::Str);
                push(r"\b(?:true|false|null)\b", Color::Keyword);
                push(r"-?\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b", Color::Number);
            }
            "yaml" | "ini" => {
                push(r"(?m:(?:^|\s)[#;][^\n]*)", Color::Comment);
                push(r"(?m:^\s*\[[^\]\n]+\])", Color::Keyword);
                push(r"(?m:^[ \t-]*[A-Za-z0-9_.$@-]+(?=\s*[:=]))", Color::Type);
                push(string, Color::Str);
                if let Some(kw) = &kw {
                    push(&format!(r"\b(?:{kw})\b"), Color::Keyword);
                }
                push(r"\b\d+(?:\.\d+)?\b", Color::Number);
            }
            "html" | "xml" => {
                push(r"<!--[\s\S]*?-->", Color::Comment);
                push(r"</?[A-Za-z][\w:.-]*|/?>", Color::Keyword);
                push(r"\b[A-Za-z_:][\w:.-]*(?==)", Color::Attribute);
                push(string, Color::Str);
            }
            "css" => {
                push(r"/\*[\s\S]*?\*/", Color::Comment);
                push(string, Color::Str);
                push(r"@[A-Za-z-]+", Color::Keyword);
                push(r"[A-Za-z-]+(?=\s*:[^;{]*;)", Color::Attribute);
                push(r"#[0-9a-fA-F]{3,8}\b|-?\b\d+(?:\.\d+)?(?:px|em|rem|%|vh|vw|s|ms|deg|fr)?\b", Color::Number);
                push(r"[.#][A-Za-z_-][\w-]*", Color::Type);
            }
            "diff" => {
                push(r"(?m:^(?:\+\+\+|---)[^\n]*)", Color::Meta);
                push(r"(?m:^@@[^\n]*)", Color::Meta);
                push(r"(?m:^\+[^\n]*)", Color::Added);
                push(r"(?m:^-[^\n]*)", Color::Removed);
            }
            "dockerfile" => {
                push(r"#[^\n]*", Color::Comment);
                push(string, Color::Str);
                if let Some(kw) = &kw {
                    push(&format!(r"(?m:^\s*(?:{kw})\b)"), Color::Keyword);
                }
                push(r"\$\{?[A-Za-z_][A-Za-z0-9_]*\}?", Color::Attribute);
            }
            "markdown" => {
                push(r"(?m:^#{1,6} [^\n]*)", Color::Keyword);
                push(r"`[^`\n]+`", Color::Str);
                push(r"\*\*[^*\n]+\*\*|__[^_\n]+__", Color::Type);
                push(r"\[[^\]\n]*\]\([^)\n]*\)", Color::Function);
            }
            _ => {
                CACHE.lock().unwrap().insert(language.to_string(), None);
                return None;
            }
        }
    }
    let pattern = parts.iter().map(|(p, _)| format!("({p})")).collect::<Vec<_>>().join("|");
    let grammar = Regex::new(&pattern).ok().map(|regex| Arc::new(Grammar { regex, colors: parts.iter().map(|p| p.1).collect() }));
    CACHE.lock().unwrap().insert(language.to_string(), grammar.clone());
    grammar
}

/// Colored byte ranges for the code in `text`.
pub fn tokens(text: &str, language: Option<&str>) -> Vec<(Range<usize>, Color)> {
    let Some(language) = canonical(language) else { return Vec::new() };
    let Some(grammar) = grammar(&language) else { return Vec::new() };
    if text.is_empty() || text.len() > 300_000 {
        return Vec::new();
    }
    let mut result = Vec::new();
    for caps in grammar.regex.captures_iter(text) {
        let Ok(caps) = caps else { break };
        for (index, color) in grammar.colors.iter().enumerate() {
            if let Some(m) = caps.get(index + 1) {
                if !m.range().is_empty() {
                    result.push((m.range(), *color));
                }
                break;
            }
        }
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn highlights_swift() {
        let code = "let value = \"hi\" // note\nreturn value";
        let found = tokens(code, Some("swift"));
        assert!(found.iter().any(|(r, c)| &code[r.clone()] == "let" && *c == Color::Keyword));
        assert!(found.iter().any(|(r, c)| &code[r.clone()] == "\"hi\"" && *c == Color::Str));
        assert!(found.iter().any(|(r, c)| &code[r.clone()] == "// note" && *c == Color::Comment));
    }

    #[test]
    fn highlights_functions_with_lookahead() {
        let code = "print(x)";
        let found = tokens(code, Some("py"));
        assert!(found.iter().any(|(r, c)| &code[r.clone()] == "print" && *c == Color::Function));
    }
}
