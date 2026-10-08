//! Turns pulldown-cmark's event stream into a small owned tree with byte ranges.

use super::gfm::Alert;
use super::Align;
use pulldown_cmark::{Event, LinkType, Options, Parser, Tag, TagEnd};
use std::ops::Range;

#[derive(Debug, Clone, PartialEq)]
pub enum Kind {
    Document,
    Paragraph,
    Heading(u8),
    BlockQuote(Option<Alert>),
    CodeBlock { info: Option<String>, fenced: bool },
    HtmlBlock,
    List(Option<u64>),
    Item,
    Table(Vec<Align>),
    TableHead,
    TableRow,
    TableCell,
    FootnoteDefinition(String),
    Metadata,
    Emphasis,
    Strong,
    Strikethrough,
    Superscript,
    Subscript,
    Link { dest: String, title: String, autolink: bool },
    Image { dest: String, title: String },
    Text(String),
    Code(String),
    Html(String),
    InlineHtml(String),
    FootnoteRef(String),
    SoftBreak,
    HardBreak,
    Rule,
    TaskMarker(bool),
}

#[derive(Debug, Clone)]
pub struct Node {
    pub kind: Kind,
    pub range: Range<usize>,
    pub children: Vec<Node>,
}

impl Node {
    pub fn is_inline(&self) -> bool {
        matches!(
            self.kind,
            Kind::Emphasis
                | Kind::Strong
                | Kind::Strikethrough
                | Kind::Superscript
                | Kind::Subscript
                | Kind::Link { .. }
                | Kind::Image { .. }
                | Kind::Text(_)
                | Kind::Code(_)
                | Kind::InlineHtml(_)
                | Kind::FootnoteRef(_)
                | Kind::SoftBreak
                | Kind::HardBreak
                | Kind::TaskMarker(_)
                | Kind::Html(_)
        )
    }

    /// Text content without markup, as used for heading titles and image alt text.
    pub fn plain_text(&self) -> String {
        let mut out = String::new();
        self.collect_text(&mut out);
        out
    }

    fn collect_text(&self, out: &mut String) {
        match &self.kind {
            Kind::Text(t) | Kind::Code(t) => out.push_str(t),
            Kind::SoftBreak | Kind::HardBreak => out.push(' '),
            _ => {
                for child in &self.children {
                    child.collect_text(out);
                }
            }
        }
    }

    /// Concatenated raw HTML of an HTML block.
    pub fn raw_html(&self) -> String {
        self.children
            .iter()
            .map(|c| match &c.kind {
                Kind::Html(t) | Kind::Text(t) | Kind::InlineHtml(t) => t.as_str(),
                _ => "",
            })
            .collect()
    }

    /// Code block contents.
    pub fn code(&self) -> String {
        self.children
            .iter()
            .map(|c| match &c.kind {
                Kind::Text(t) => t.as_str(),
                _ => "",
            })
            .collect()
    }
}

pub fn options() -> Options {
    Options::ENABLE_TABLES
        | Options::ENABLE_FOOTNOTES
        | Options::ENABLE_STRIKETHROUGH
        | Options::ENABLE_TASKLISTS
        | Options::ENABLE_YAML_STYLE_METADATA_BLOCKS
        | Options::ENABLE_GFM
}

fn kind_of(tag: Tag) -> Kind {
    match tag {
        Tag::Paragraph => Kind::Paragraph,
        Tag::Heading { level, .. } => Kind::Heading(level as u8),
        Tag::BlockQuote(kind) => Kind::BlockQuote(kind.map(Alert::from_kind)),
        Tag::CodeBlock(kind) => match kind {
            pulldown_cmark::CodeBlockKind::Fenced(info) => {
                let info = info.trim().to_string();
                Kind::CodeBlock { info: (!info.is_empty()).then_some(info), fenced: true }
            }
            pulldown_cmark::CodeBlockKind::Indented => Kind::CodeBlock { info: None, fenced: false },
        },
        Tag::HtmlBlock => Kind::HtmlBlock,
        Tag::List(start) => Kind::List(start),
        Tag::Item => Kind::Item,
        Tag::Table(alignments) => Kind::Table(
            alignments
                .into_iter()
                .map(|a| match a {
                    pulldown_cmark::Alignment::Left => Align::Left,
                    pulldown_cmark::Alignment::Center => Align::Center,
                    pulldown_cmark::Alignment::Right => Align::Right,
                    pulldown_cmark::Alignment::None => Align::Natural,
                })
                .collect(),
        ),
        Tag::TableHead => Kind::TableHead,
        Tag::TableRow => Kind::TableRow,
        Tag::TableCell => Kind::TableCell,
        Tag::FootnoteDefinition(label) => Kind::FootnoteDefinition(label.to_string()),
        Tag::MetadataBlock(_) => Kind::Metadata,
        Tag::Emphasis => Kind::Emphasis,
        Tag::Strong => Kind::Strong,
        Tag::Strikethrough => Kind::Strikethrough,
        Tag::Superscript => Kind::Superscript,
        Tag::Subscript => Kind::Subscript,
        Tag::Link { link_type, dest_url, title, .. } => Kind::Link {
            dest: dest_url.to_string(),
            title: title.to_string(),
            autolink: matches!(link_type, LinkType::Autolink | LinkType::Email),
        },
        Tag::Image { dest_url, title, .. } => Kind::Image { dest: dest_url.to_string(), title: title.to_string() },
        // Definition lists and other extensions are not enabled.
        _ => Kind::Paragraph,
    }
}

pub fn parse(text: &str) -> Node {
    let mut stack: Vec<Node> = vec![Node { kind: Kind::Document, range: 0..text.len(), children: Vec::new() }];
    for (event, range) in Parser::new_ext(text, options()).into_offset_iter() {
        let leaf = |kind: Kind| Node { kind, range: range.clone(), children: Vec::new() };
        match event {
            Event::Start(tag) => stack.push(Node { kind: kind_of(tag), range: range.clone(), children: Vec::new() }),
            Event::End(end) => {
                if matches!(end, TagEnd::Paragraph) && stack.len() == 1 {
                    continue;
                }
                if stack.len() > 1 {
                    let node = stack.pop().unwrap();
                    stack.last_mut().unwrap().children.push(node);
                }
            }
            Event::Text(t) => {
                let parent = stack.last_mut().unwrap();
                // Merge split text runs so autolinks and highlighting see whole strings.
                if let Some(last) = parent.children.last_mut() {
                    if let Kind::Text(existing) = &mut last.kind {
                        if last.range.end == range.start || matches!(parent.kind, Kind::CodeBlock { .. } | Kind::Metadata) {
                            existing.push_str(&t);
                            last.range.end = last.range.end.max(range.end);
                            continue;
                        }
                    }
                }
                parent.children.push(leaf(Kind::Text(t.to_string())));
            }
            Event::Code(t) => stack.last_mut().unwrap().children.push(leaf(Kind::Code(t.to_string()))),
            Event::Html(t) => stack.last_mut().unwrap().children.push(leaf(Kind::Html(t.to_string()))),
            Event::InlineHtml(t) => stack.last_mut().unwrap().children.push(leaf(Kind::InlineHtml(t.to_string()))),
            Event::FootnoteReference(label) => {
                stack.last_mut().unwrap().children.push(leaf(Kind::FootnoteRef(label.to_string())))
            }
            Event::SoftBreak => stack.last_mut().unwrap().children.push(leaf(Kind::SoftBreak)),
            Event::HardBreak => stack.last_mut().unwrap().children.push(leaf(Kind::HardBreak)),
            Event::Rule => stack.last_mut().unwrap().children.push(leaf(Kind::Rule)),
            Event::TaskListMarker(checked) => stack.last_mut().unwrap().children.push(leaf(Kind::TaskMarker(checked))),
            Event::InlineMath(t) | Event::DisplayMath(t) => {
                stack.last_mut().unwrap().children.push(leaf(Kind::Code(t.to_string())))
            }
        }
    }
    while stack.len() > 1 {
        let node = stack.pop().unwrap();
        stack.last_mut().unwrap().children.push(node);
    }
    stack.pop().unwrap()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn builds_tree_with_alerts_and_tasks() {
        let doc = parse("> [!NOTE]\n> Shared.\n\n- [x] done\n");
        assert_eq!(doc.children[0].kind, Kind::BlockQuote(Some(Alert::Note)));
        let item = &doc.children[1].children[0];
        assert_eq!(item.kind, Kind::Item);
        assert_eq!(item.children[0].kind, Kind::TaskMarker(true));
    }
}
