//! GitHub Flavored Markdown details that the CommonMark parser leaves to us.

use regex::Regex;
use std::sync::LazyLock;

/// GitHub heading anchor: lowercase, punctuation removed, spaces become hyphens.
pub fn slug(title: &str) -> String {
    let mut out = String::new();
    for c in title.to_lowercase().chars() {
        if c.is_alphanumeric() || c == '-' || c == '_' {
            out.push(c);
        } else if c == ' ' {
            out.push('-');
        }
    }
    out
}

static AUTOLINK: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)(?:(?:https?|ftp)://|www\.)[^\s<]+|[A-Za-z0-9._+\-]+@[A-Za-z0-9\-_]+(?:\.[A-Za-z0-9\-_]+)+").unwrap()
});
static TRAILING_ENTITY: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"&[A-Za-z0-9]+;$").unwrap());

/// GFM extended autolinks (www., http(s)://, ftp:// and e-mail addresses) found in plain text.
/// Ranges are byte ranges into `text`.
pub fn autolinks(text: &str) -> Vec<(std::ops::Range<usize>, String)> {
    if !text.contains('.') {
        return Vec::new();
    }
    let mut links = Vec::new();
    for found in AUTOLINK.find_iter(text) {
        if let Some(before) = text[..found.start()].chars().last() {
            if !(before.is_whitespace() || "*_~(\"'".contains(before)) {
                continue;
            }
        }
        let mut candidate = found.as_str().to_string();
        let lower = candidate.to_lowercase();
        let is_email = candidate.contains('@') && !candidate.contains("://") && !lower.starts_with("www.");
        if is_email {
            while candidate.ends_with('.') {
                candidate.pop();
            }
            match candidate.chars().last() {
                Some('-') | Some('_') | None => continue,
                _ => {}
            }
            links.push((found.start()..found.start() + candidate.len(), format!("mailto:{candidate}")));
            continue;
        }
        loop {
            let mut trimmed = false;
            if let Some(last) = candidate.chars().last() {
                if "?!.,:*_~'\"".contains(last) {
                    candidate.pop();
                    trimmed = true;
                }
            }
            if candidate.ends_with(')') && candidate.matches(')').count() > candidate.matches('(').count() {
                candidate.pop();
                trimmed = true;
            }
            if candidate.ends_with(';') {
                if let Some(m) = TRAILING_ENTITY.find(&candidate) {
                    candidate.truncate(m.start());
                    trimmed = true;
                }
            }
            if !trimmed {
                break;
            }
        }
        let lower = candidate.to_lowercase();
        let without_scheme = ["https://", "http://", "ftp://"]
            .iter()
            .find_map(|scheme| lower.starts_with(scheme).then(|| &candidate[scheme.len()..]))
            .unwrap_or(&candidate);
        let host = without_scheme.split(['/', '?', '#']).next().unwrap_or("");
        let labels: Vec<&str> = host.split('.').collect();
        let underscore = labels.iter().rev().take(2).any(|l| l.contains('_'));
        if !host.contains('.') || host.ends_with('.') || underscore {
            continue;
        }
        let target = if lower.starts_with("www.") { format!("http://{candidate}") } else { candidate.clone() };
        links.push((found.start()..found.start() + candidate.len(), target));
    }
    links
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Alert {
    Note,
    Tip,
    Important,
    Warning,
    Caution,
}

impl Alert {
    /// Spanish key, translated through `i18n::t`.
    pub fn title(self) -> &'static str {
        match self {
            Alert::Note => "Nota",
            Alert::Tip => "Consejo",
            Alert::Important => "Importante",
            Alert::Warning => "Advertencia",
            Alert::Caution => "Precaución",
        }
    }

    pub fn icon(self) -> &'static str {
        match self {
            Alert::Note => "dialog-information-symbolic",
            Alert::Tip => "starred-symbolic",
            Alert::Important => "emblem-important-symbolic",
            Alert::Warning => "dialog-warning-symbolic",
            Alert::Caution => "dialog-error-symbolic",
        }
    }

    pub fn from_kind(kind: pulldown_cmark::BlockQuoteKind) -> Alert {
        use pulldown_cmark::BlockQuoteKind as K;
        match kind {
            K::Note => Alert::Note,
            K::Tip => Alert::Tip,
            K::Important => Alert::Important,
            K::Warning => Alert::Warning,
            K::Caution => Alert::Caution,
        }
    }

    pub fn from_marker(marker: &str) -> Option<Alert> {
        let trimmed = marker.trim().to_uppercase();
        let inner = trimmed.strip_prefix("[!")?.strip_suffix(']')?;
        Some(match inner {
            "NOTE" => Alert::Note,
            "TIP" => Alert::Tip,
            "IMPORTANT" => Alert::Important,
            "WARNING" => Alert::Warning,
            "CAUTION" => Alert::Caution,
            _ => return None,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn slugs() {
        assert_eq!(slug("My Title"), "my-title");
        assert_eq!(slug("Título ¿uno?"), "título-uno");
    }

    #[test]
    fn extended_autolinks() {
        let text = "Visit www.example.com. Mail me@example.org, or https://a.b/c_(d)).";
        let links = autolinks(text);
        assert_eq!(&text[links[0].0.clone()], "www.example.com");
        assert_eq!(links[0].1, "http://www.example.com");
        assert_eq!(links[1].1, "mailto:me@example.org");
        assert_eq!(&text[links[2].0.clone()], "https://a.b/c_(d)");
    }
}
