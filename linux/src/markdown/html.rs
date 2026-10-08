//! A small HTML tokenizer for the raw HTML that appears in real READMEs.

use regex::Regex;
use std::collections::HashMap;
use std::sync::LazyLock;

#[derive(Debug, Clone, PartialEq)]
pub enum Token {
    /// `end` is the byte offset just past the tag in the tokenized string.
    Open { name: String, attributes: HashMap<String, String>, self_closing: bool, start: usize, end: usize },
    Close { name: String },
    Text(String),
    Comment,
}

pub const VOID_ELEMENTS: &[&str] =
    &["img", "br", "hr", "source", "input", "meta", "link", "wbr", "col", "area", "base", "embed", "param", "track"];

/// GFM "disallowed raw HTML" plus elements that never render as text.
pub const HIDDEN_ELEMENTS: &[&str] = &[
    "script", "style", "title", "textarea", "xmp", "iframe", "noembed", "noframes", "plaintext", "template", "head",
    "object", "select", "button", "canvas",
];

pub const BLOCK_ELEMENTS: &[&str] = &[
    "p", "div", "center", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "pre", "ul", "ol", "li", "table", "thead",
    "tbody", "tfoot", "tr", "td", "th", "details", "summary", "section", "article", "header", "footer", "figure",
    "figcaption", "nav", "main", "aside", "dl", "dt", "dd", "hr", "address", "picture", "caption",
];

pub fn is_void(name: &str) -> bool {
    VOID_ELEMENTS.contains(&name)
}
pub fn is_hidden(name: &str) -> bool {
    HIDDEN_ELEMENTS.contains(&name)
}
pub fn is_block(name: &str) -> bool {
    BLOCK_ELEMENTS.contains(&name)
}

static TAG: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r#"<!--[\s\S]*?(?:-->|$)|<![^>]*>|<\?[\s\S]*?\?>|<(/?)([A-Za-z][A-Za-z0-9-]*)((?:\s+[^\s"'>/=]+(?:\s*=\s*(?:"[^"]*"|'[^']*'|[^\s"'=<>`]+))?)*)\s*(/?)>"#,
    )
    .unwrap()
});
static ATTRIBUTE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r#"([^\s"'>/=]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+)))?"#).unwrap()
});
static ENTITY: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"&(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[A-Za-z][A-Za-z0-9]{1,31});").unwrap());

pub fn tokenize(html: &str) -> Vec<Token> {
    let mut tokens = Vec::new();
    let mut cursor = 0;
    for caps in TAG.captures_iter(html) {
        let whole = caps.get(0).unwrap();
        if cursor < whole.start() {
            tokens.push(Token::Text(html[cursor..whole.start()].to_string()));
        }
        cursor = whole.end();
        let Some(name) = caps.get(2) else {
            tokens.push(Token::Comment);
            continue;
        };
        let name = name.as_str().to_lowercase();
        if caps.get(1).is_some_and(|m| !m.as_str().is_empty()) {
            tokens.push(Token::Close { name });
        } else {
            let attributes = attributes(caps.get(3).map_or("", |m| m.as_str()));
            let slash = caps.get(4).is_some_and(|m| !m.as_str().is_empty());
            let self_closing = slash || is_void(&name);
            tokens.push(Token::Open { name, attributes, self_closing, start: whole.start(), end: whole.end() });
        }
    }
    if cursor < html.len() {
        tokens.push(Token::Text(html[cursor..].to_string()));
    }
    tokens
}

pub fn attributes(text: &str) -> HashMap<String, String> {
    let mut result = HashMap::new();
    for caps in ATTRIBUTE.captures_iter(text) {
        let Some(name) = caps.get(1) else { continue };
        let value = (2..=4).find_map(|i| caps.get(i)).map_or("", |m| m.as_str());
        result.insert(name.as_str().to_lowercase(), decode_entities(value));
    }
    result
}

fn named(name: &str) -> Option<&'static str> {
    Some(match name {
        "amp" => "&",
        "lt" => "<",
        "gt" => ">",
        "quot" => "\"",
        "apos" => "'",
        "nbsp" => "\u{00A0}",
        "copy" => "©",
        "reg" => "®",
        "trade" => "™",
        "hellip" => "…",
        "mdash" => "—",
        "ndash" => "–",
        "laquo" => "«",
        "raquo" => "»",
        "middot" => "·",
        "bull" => "•",
        "rarr" => "→",
        "larr" => "←",
        "uarr" => "↑",
        "darr" => "↓",
        "harr" => "↔",
        "times" => "×",
        "divide" => "÷",
        "deg" => "°",
        "plusmn" => "±",
        "para" => "¶",
        "sect" => "§",
        "euro" => "€",
        "pound" => "£",
        "yen" => "¥",
        "cent" => "¢",
        "check" => "✓",
        "ensp" => "\u{2002}",
        "emsp" => "\u{2003}",
        "thinsp" => "\u{2009}",
        "zwj" => "\u{200D}",
        "zwnj" => "\u{200C}",
        "lsquo" => "‘",
        "rsquo" => "’",
        "ldquo" => "“",
        "rdquo" => "”",
        "iexcl" => "¡",
        "iquest" => "¿",
        "hearts" => "♥",
        "star" => "☆",
        _ => return None,
    })
}

pub fn decode_entities(text: &str) -> String {
    if !text.contains('&') {
        return text.to_string();
    }
    let mut result = String::with_capacity(text.len());
    let mut last = 0;
    for caps in ENTITY.captures_iter(text) {
        let whole = caps.get(0).unwrap();
        let body = &caps[1];
        let replacement: Option<String> = if let Some(hex) = body.strip_prefix("#x").or_else(|| body.strip_prefix("#X")) {
            u32::from_str_radix(hex, 16).ok().and_then(char::from_u32).map(String::from)
        } else if let Some(dec) = body.strip_prefix('#') {
            dec.parse::<u32>().ok().and_then(char::from_u32).map(String::from)
        } else {
            named(body).or_else(|| named(&body.to_lowercase())).map(String::from)
        };
        let Some(replacement) = replacement else { continue };
        result.push_str(&text[last..whole.start()]);
        result.push_str(&replacement);
        last = whole.end();
    }
    result.push_str(&text[last..]);
    result
}

pub fn escape(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for c in text.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            _ => out.push(c),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn entities_decode() {
        assert_eq!(decode_entities("&lt;a&gt; &amp; &#169; &#x1F600; &nbsp;"), "<a> & © 😀 \u{00A0}");
    }

    #[test]
    fn tokenizes_tags() {
        let tokens = tokenize(r#"<p align="center"><img src="a.png" width=80><!-- x --></p>"#);
        assert!(matches!(&tokens[0], Token::Open { name, attributes, .. } if name == "p" && attributes["align"] == "center"));
        assert!(matches!(&tokens[1], Token::Open { name, self_closing: true, .. } if name == "img"));
        assert_eq!(tokens[2], Token::Comment);
        assert_eq!(tokens[3], Token::Close { name: "p".into() });
    }
}
