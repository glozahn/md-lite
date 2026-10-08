//! CommonMark + GitHub Flavored Markdown rendered to styled text runs, block ornaments and
//! embedded objects (tables, images, diagrams). The reader view turns this into a text buffer.

use super::gfm::{self, Alert};
use super::html::{self, Token};
use super::parse::{self, Kind, Node};
use super::{highlight, Align, Color, Family, Para, Style};
use crate::i18n::t;
use std::collections::HashMap;
use std::path::{Path, PathBuf};

pub const OBJECT: char = '\u{FFFC}';
pub const LINE_BREAK: char = '\u{2028}';

#[derive(Debug, Clone, PartialEq)]
pub enum MermaidState {
    Ready,
    Pending,
    Failed(String),
}

#[derive(Debug, Clone)]
pub struct CellRun {
    pub text: String,
    pub style: usize,
    pub link: Option<String>,
}

#[derive(Debug, Clone)]
pub struct Cell {
    pub runs: Vec<CellRun>,
    pub header: bool,
    pub align: Align,
}

#[derive(Debug, Clone)]
pub struct Table {
    pub rows: Vec<Vec<Cell>>,
    pub columns: usize,
}

#[derive(Debug, Clone)]
pub enum Embed {
    Image { url: String, alt: String, width: Option<f32>, height: Option<f32>, title: Option<String>, link: Option<String> },
    Svg { data: String, width: Option<f32> },
    Table(Table),
    Diagram { code: String, dark: bool },
    Check { checked: bool, task: Option<usize> },
    AlertIcon(Alert),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DecorationKind {
    Code,
    Diagram,
    Quote,
    Alert,
    Rule,
    HeadingRule,
}

#[derive(Debug, Clone)]
pub struct Decoration {
    pub kind: DecorationKind,
    pub start: usize,
    pub end: usize,
    pub indent: f32,
    pub pad_top: f32,
    pub pad_bottom: f32,
    pub color: Color,
    pub label: Option<String>,
    pub code: Option<String>,
}

impl Decoration {
    fn new(kind: DecorationKind, indent: f32) -> Decoration {
        Decoration {
            kind,
            start: 0,
            end: 0,
            indent,
            pad_top: 0.0,
            pad_bottom: 0.0,
            color: Color::Tertiary,
            label: None,
            code: None,
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct OutlineItem {
    pub id: usize,
    pub title: String,
    pub level: u8,
    /// Character range in the rendered text.
    pub start: usize,
    pub end: usize,
    /// Byte offset of the heading in the Markdown source.
    pub source: usize,
    pub anchor: String,
}

#[derive(Debug, Clone)]
pub struct Link {
    pub start: usize,
    pub end: usize,
    pub url: String,
}

#[derive(Debug, Clone, Default)]
pub struct Run {
    pub start: usize,
    pub end: usize,
    pub style: usize,
}

#[derive(Debug, Clone, Default)]
pub struct Rendered {
    pub text: String,
    pub runs: Vec<Run>,
    pub styles: Vec<Style>,
    pub embeds: Vec<(usize, Embed)>,
    pub decorations: Vec<Decoration>,
    pub outline: Vec<OutlineItem>,
    /// Sorted pairs mapping source byte offsets to rendered character offsets, one per block.
    pub blocks: Vec<(usize, usize)>,
    pub links: Vec<Link>,
    /// Anchor names (headings, footnotes) and their rendered character offsets.
    pub anchors: Vec<(String, usize)>,
    pub remote_images: Vec<String>,
}

impl Rendered {
    pub fn rendered_offset(&self, source: usize) -> usize {
        let mut best = 0;
        for &(s, r) in &self.blocks {
            if s <= source {
                best = r;
            } else {
                break;
            }
        }
        best
    }

    pub fn source_offset(&self, rendered: usize) -> usize {
        let mut best = 0;
        for &(s, r) in &self.blocks {
            if r <= rendered {
                best = s;
            }
        }
        best
    }

    pub fn link_at(&self, offset: usize) -> Option<&Link> {
        self.links.iter().find(|l| l.start <= offset && offset < l.end)
    }

    pub fn anchor(&self, name: &str) -> Option<usize> {
        let name = name.to_lowercase();
        self.anchors.iter().find(|(a, _)| a.to_lowercase() == name).map(|(_, o)| *o)
    }

    pub fn style_at(&self, offset: usize) -> Option<&Style> {
        self.runs.iter().find(|r| r.start <= offset && offset < r.end).map(|r| &self.styles[r.style])
    }
}

#[derive(Clone)]
struct Ctx {
    indent: f32,
    color: Color,
    spacing: Option<f32>,
}

impl Default for Ctx {
    fn default() -> Ctx {
        Ctx { indent: 0.0, color: Color::Text, spacing: None }
    }
}

/// Style plus the link a run points to.
#[derive(Clone)]
struct Attrs {
    style: Style,
    link: Option<String>,
}

#[derive(Default)]
struct Out {
    text: String,
    len: usize,
    runs: Vec<Run>,
    links: Vec<Link>,
    embeds: Vec<(usize, Embed)>,
}

struct HtmlFrame {
    name: String,
    attributes: HashMap<String, String>,
    start: usize,
    start_byte: usize,
    decoration: Option<Decoration>,
    counter: i64,
    saved: Option<Out>,
}

impl HtmlFrame {
    fn new(name: &str, attributes: HashMap<String, String>) -> HtmlFrame {
        HtmlFrame { name: name.to_string(), attributes, start: 0, start_byte: 0, decoration: None, counter: 1, saved: None }
    }
}

#[derive(Default)]
struct HtmlTable {
    rows: Vec<Vec<Cell>>,
    row: Option<Vec<Cell>>,
    in_head: bool,
}

pub struct Renderer<'a> {
    pub size: f32,
    pub base_dir: Option<PathBuf>,
    pub dark: bool,
    pub max_image_width: f32,
    pub mermaid: Option<&'a dyn Fn(&str) -> MermaidState>,

    out: Out,
    styles: Vec<Style>,
    style_ids: HashMap<String, usize>,
    decorations: Vec<Decoration>,
    outline: Vec<OutlineItem>,
    anchors: Vec<(String, usize)>,
    blocks: Vec<(usize, usize)>,
    remote: Vec<String>,
    html: Vec<HtmlFrame>,
    html_tables: Vec<HtmlTable>,
    hidden_depth: usize,
    link_depth: usize,
    list_depth: usize,
    capturing: usize,
    slugs: HashMap<String, usize>,
    current_source: usize,
    picture_source: Option<String>,
    footnotes: Vec<String>,
    footnote_defs: Vec<Node>,
}

impl<'a> Renderer<'a> {
    pub fn new(size: f32, base_dir: Option<&Path>) -> Renderer<'a> {
        Renderer {
            size,
            base_dir: base_dir.map(Path::to_path_buf),
            dark: false,
            max_image_width: 760.0,
            mermaid: None,
            out: Out::default(),
            styles: Vec::new(),
            style_ids: HashMap::new(),
            decorations: Vec::new(),
            outline: Vec::new(),
            anchors: Vec::new(),
            blocks: Vec::new(),
            remote: Vec::new(),
            html: Vec::new(),
            html_tables: Vec::new(),
            hidden_depth: 0,
            link_depth: 0,
            list_depth: 0,
            capturing: 0,
            slugs: HashMap::new(),
            current_source: 0,
            picture_source: None,
            footnotes: Vec::new(),
            footnote_defs: Vec::new(),
        }
    }

    pub fn render(mut self, text: &str) -> Rendered {
        let document = parse::parse(text);
        for child in &document.children {
            self.block(child, &Ctx::default());
        }
        while !self.html.is_empty() {
            self.close_html_frame(&Ctx::default());
        }
        self.render_footnotes();
        self.blocks.sort_by_key(|b| (b.0, b.1));
        let out = std::mem::take(&mut self.out);
        Rendered {
            text: out.text,
            runs: out.runs,
            styles: self.styles,
            embeds: out.embeds,
            decorations: self.decorations,
            outline: self.outline,
            blocks: self.blocks,
            links: out.links,
            anchors: self.anchors,
            remote_images: self.remote,
        }
    }

    // MARK: Output helpers

    fn style_id(&mut self, style: &Style) -> usize {
        let key = style.key();
        if let Some(&id) = self.style_ids.get(&key) {
            return id;
        }
        let id = self.styles.len();
        self.styles.push(style.clone());
        self.style_ids.insert(key, id);
        id
    }

    fn body(&self) -> Style {
        Style::body(self.size)
    }

    fn para(&self, ctx: &Ctx, spacing: Option<f32>) -> Para {
        Para {
            head: ctx.indent,
            first: ctx.indent,
            after: spacing.or(ctx.spacing).unwrap_or(self.size * 0.75),
            line_spacing: self.size * 0.3,
            align: self.html_alignment().unwrap_or_default(),
            ..Para::default()
        }
    }

    fn attrs(&self, ctx: &Ctx) -> Attrs {
        let mut style = self.body();
        style.color = ctx.color;
        style.para = self.para(ctx, None);
        Attrs { style, link: None }
    }

    fn append(&mut self, string: &str, attrs: &Attrs) {
        if string.is_empty() {
            return;
        }
        let id = self.style_id(&attrs.style);
        let count = string.chars().count();
        let start = self.out.len;
        self.out.text.push_str(string);
        self.out.len += count;
        match self.out.runs.last_mut() {
            Some(last) if last.style == id && last.end == start => last.end = start + count,
            _ => self.out.runs.push(Run { start, end: start + count, style: id }),
        }
        if let Some(url) = &attrs.link {
            match self.out.links.last_mut() {
                Some(last) if last.url == *url && last.end == start => last.end = start + count,
                _ => self.out.links.push(Link { start, end: start + count, url: url.clone() }),
            }
        }
    }

    fn append_embed(&mut self, embed: Embed, attrs: &Attrs) {
        let at = self.out.len;
        self.append(&OBJECT.to_string(), attrs);
        self.out.embeds.push((at, embed));
    }

    fn last_char(&self) -> Option<char> {
        self.out.text.chars().next_back()
    }

    fn at_line_start(&self) -> bool {
        self.last_char().is_none_or(|c| c == '\n' || c == LINE_BREAK)
    }

    fn ensure_newline(&mut self, attrs: &Attrs) {
        if self.last_char().is_some_and(|c| c != '\n') {
            self.append("\n", attrs);
        }
    }

    fn mark(&mut self, node: &Node, from: usize) {
        if self.capturing == 0 && self.out.len > from {
            self.blocks.push((node.range.start, from));
        }
    }

    fn push_decoration(&mut self, mut decoration: Decoration, start: usize) {
        if self.capturing > 0 {
            return;
        }
        decoration.start = start;
        decoration.end = self.out.len;
        if decoration.end > decoration.start {
            self.decorations.push(decoration);
        }
    }

    fn capture(&mut self, body: impl FnOnce(&mut Self)) -> Out {
        let saved = std::mem::take(&mut self.out);
        self.capturing += 1;
        body(self);
        self.capturing -= 1;
        std::mem::replace(&mut self.out, saved)
    }

    fn cell_runs(&self, out: &Out) -> Vec<CellRun> {
        let chars: Vec<char> = out.text.chars().collect();
        let mut runs = Vec::new();
        for run in &out.runs {
            let link = out.links.iter().find(|l| l.start <= run.start && run.start < l.end).map(|l| l.url.clone());
            // Split a run where a link starts or ends inside it.
            let mut cuts = vec![run.start, run.end];
            for l in &out.links {
                for p in [l.start, l.end] {
                    if p > run.start && p < run.end {
                        cuts.push(p);
                    }
                }
            }
            cuts.sort();
            cuts.dedup();
            if cuts.len() == 2 {
                let text: String = chars[run.start..run.end].iter().filter(|c| **c != OBJECT).collect();
                runs.push(CellRun { text, style: run.style, link });
            } else {
                for w in cuts.windows(2) {
                    let link = out.links.iter().find(|l| l.start <= w[0] && w[0] < l.end).map(|l| l.url.clone());
                    let text: String = chars[w[0]..w[1]].iter().filter(|c| **c != OBJECT).collect();
                    runs.push(CellRun { text, style: run.style, link });
                }
            }
        }
        // Trailing whitespace and line breaks would add empty lines to the cell.
        while let Some(last) = runs.last_mut() {
            let trimmed = last.text.trim_end_matches(|c: char| c.is_whitespace() || c == LINE_BREAK).to_string();
            if trimmed.is_empty() {
                runs.pop();
            } else {
                last.text = trimmed;
                break;
            }
        }
        runs
    }

    fn add_outline(&mut self, title: &str, level: u8, start: usize, end: usize, source: usize) {
        if self.capturing > 0 {
            return;
        }
        let clean = title.replace(OBJECT, "").trim().to_string();
        if clean.is_empty() {
            return;
        }
        let base = gfm::slug(&clean);
        let count = *self.slugs.get(&base).unwrap_or(&0);
        self.slugs.insert(base.clone(), count + 1);
        let anchor = if count == 0 { base } else { format!("{base}-{count}") };
        self.anchors.push((anchor.clone(), start));
        self.outline.push(OutlineItem { id: self.outline.len(), title: clean, level, start, end, source, anchor });
    }

    /// Raises the spacing after the last paragraph written so far.
    fn set_trailing_spacing(&mut self, spacing: f32) {
        if self.out.len == 0 {
            return;
        }
        let text = &self.out.text;
        let body = text.strip_suffix('\n').unwrap_or(text);
        let line_start_byte = body.rfind('\n').map_or(0, |i| i + 1);
        let line_start = text[..line_start_byte].chars().count();
        let ids: Vec<(usize, usize)> = self
            .out
            .runs
            .iter()
            .enumerate()
            .filter(|(_, r)| r.end > line_start)
            .map(|(i, r)| (i, r.style))
            .collect();
        for (index, id) in ids {
            let mut style = self.styles[id].clone();
            if style.para.after >= spacing {
                continue;
            }
            style.para.after = spacing;
            let new = self.style_id(&style);
            self.out.runs[index].style = new;
        }
    }

    // MARK: Blocks

    fn block(&mut self, node: &Node, ctx: &Ctx) {
        let start = self.out.len;
        match &node.kind {
            Kind::Heading(level) => {
                self.render_heading(node, *level, ctx);
                self.mark(node, start);
            }
            Kind::CodeBlock { info, .. } => {
                self.render_code(&node.code(), info.as_deref(), ctx);
                self.mark(node, start);
            }
            Kind::Metadata => {
                let yaml = node.code();
                self.render_code_box(yaml.trim_end_matches('\n'), Some("yaml"), Some("front matter"), ctx, None, true);
                self.mark(node, start);
            }
            Kind::BlockQuote(alert) => self.render_quote(node, *alert, ctx),
            Kind::List(first) => {
                self.render_list(node, *first, ctx);
            }
            Kind::Rule => {
                self.render_rule(ctx);
                self.mark(node, start);
            }
            Kind::HtmlBlock => {
                self.current_source = node.range.start;
                self.render_html(&node.raw_html(), ctx);
                if self.html_tables.is_empty() {
                    let attrs = self.html_attrs(ctx);
                    self.ensure_newline(&attrs);
                }
                self.mark(node, start);
            }
            Kind::Table(alignments) => {
                self.render_table(node, alignments, ctx);
                self.mark(node, start);
            }
            Kind::Paragraph => {
                self.render_paragraph(&node.children, ctx, None);
                self.mark(node, start);
            }
            Kind::FootnoteDefinition(_) => self.footnote_defs.push(node.clone()),
            _ if node.is_inline() => {
                self.render_paragraph(std::slice::from_ref(node), ctx, None);
            }
            _ => {
                for child in &node.children {
                    self.block(child, ctx);
                }
            }
        }
    }

    fn render_paragraph(&mut self, children: &[Node], ctx: &Ctx, attrs: Option<Attrs>) {
        let attrs = attrs.unwrap_or_else(|| self.attrs(ctx));
        let start = self.out.len;
        let open = self.html.len();
        for child in children {
            self.inline(child, &attrs);
        }
        self.close_inline_frames(open);
        if self.out.len > start {
            self.append("\n", &attrs);
        }
    }

    fn heading_attrs(&self, level: u8, ctx: &Ctx) -> Attrs {
        let scale = [2.0, 1.5, 1.25, 1.08, 0.97, 0.9][(level.clamp(1, 6) - 1) as usize];
        let mut style = self.body();
        style.size = self.size * scale;
        style.weight = if level == 1 { 700 } else { 600 };
        style.color = if level == 6 { Color::Secondary } else { ctx.color };
        let mut para = self.para(ctx, None);
        para.before = if self.out.len == 0 {
            0.0
        } else if level <= 2 {
            self.size * 1.45
        } else {
            self.size * 1.1
        };
        para.after = if level <= 2 { self.size * 1.0 } else { self.size * 0.55 };
        para.line_spacing = 2.0;
        style.para = para;
        Attrs { style, link: None }
    }

    fn render_heading(&mut self, node: &Node, level: u8, ctx: &Ctx) {
        let level = level.clamp(1, 6);
        let attrs = self.heading_attrs(level, ctx);
        let start = self.out.len;
        let open = self.html.len();
        for child in &node.children {
            self.inline(child, &attrs);
        }
        self.close_inline_frames(open);
        self.append("\n", &attrs);
        let end = self.out.len;
        self.add_outline(&node.plain_text(), level, start, end, node.range.start);
        if level <= 2 {
            self.push_decoration(Decoration::new(DecorationKind::HeadingRule, ctx.indent), start);
        }
    }

    fn render_code(&mut self, code: &str, info: Option<&str>, ctx: &Ctx) {
        let language = info.and_then(|i| i.split([' ', '{', ',']).next()).filter(|l| !l.is_empty()).map(str::to_string);
        let text = code.strip_suffix('\n').unwrap_or(code);
        if language.as_deref().map(str::to_lowercase).as_deref() == Some("mermaid") {
            if let Some(mermaid) = self.mermaid {
                match mermaid(text) {
                    MermaidState::Ready => self.render_diagram(text, ctx),
                    MermaidState::Failed(message) => {
                        self.render_code_box(text, None, Some("mermaid"), ctx, Some(&message), true)
                    }
                    MermaidState::Pending => {
                        let label = format!("mermaid · {}", t("dibujando…"));
                        self.render_code_box(text, None, Some(&label), ctx, None, true)
                    }
                }
                return;
            }
        }
        let label = language.as_deref().map(str::to_lowercase);
        self.render_code_box(text, language.as_deref(), label.as_deref(), ctx, None, true);
    }

    fn render_code_box(&mut self, text: &str, language: Option<&str>, label: Option<&str>, ctx: &Ctx, note: Option<&str>, copyable: bool) {
        let mut decoration = Decoration::new(DecorationKind::Code, ctx.indent);
        decoration.pad_top = 34.0;
        decoration.pad_bottom = 15.0;
        decoration.label = label.map(str::to_string);
        decoration.code = copyable.then(|| text.to_string());
        let mut base = self.body();
        base.family = Family::Mono;
        base.size = self.size * 0.8;
        base.color = Color::CodeText;
        let tokens = highlight::tokens(text, language);
        let lines: Vec<&str> = text.split('\n').collect();
        let line_count = lines.len() + usize::from(note.is_some());
        let size = self.size;
        let para_for = |index: usize| -> Para {
            let mut para = Para {
                head: ctx.indent + 18.0,
                first: ctx.indent + 18.0,
                tail: 18.0,
                line_spacing: size * 0.22,
                after: 0.0,
                ..Para::default()
            };
            if index == 0 {
                para.before = decoration.pad_top + size * 0.35;
            }
            if index + 1 == line_count {
                para.after = decoration.pad_bottom + size * 0.95;
            }
            para
        };
        let start = self.out.len;
        let mut offset = 0;
        for (index, line) in lines.iter().enumerate() {
            let mut style = base.clone();
            style.para = para_for(index);
            let line_range = offset..offset + line.len();
            let mut cursor = line_range.start;
            for (range, color) in tokens.iter().filter(|(r, _)| r.end > line_range.start && r.start < line_range.end) {
                let s = range.start.max(line_range.start);
                let e = range.end.min(line_range.end);
                if s > cursor {
                    self.append(&text[cursor..s], &Attrs { style: style.clone(), link: None });
                }
                let mut colored = style.clone();
                colored.color = *color;
                self.append(&text[s..e], &Attrs { style: colored, link: None });
                cursor = e;
            }
            if cursor < line_range.end {
                self.append(&text[cursor..line_range.end], &Attrs { style: style.clone(), link: None });
            }
            self.append("\n", &Attrs { style, link: None });
            offset = line_range.end + 1;
        }
        if let Some(note) = note {
            let mut style = self.body();
            style.size = self.size * 0.72;
            style.weight = 500;
            style.color = Color::Caution;
            style.para = para_for(line_count - 1);
            self.append(&format!("\u{26A0}\u{FE0E} {note}\n"), &Attrs { style, link: None });
        }
        self.push_decoration(decoration, start);
    }

    fn render_diagram(&mut self, code: &str, ctx: &Ctx) {
        let mut decoration = Decoration::new(DecorationKind::Diagram, ctx.indent);
        decoration.pad_top = 20.0;
        decoration.pad_bottom = 20.0;
        let mut style = self.body();
        style.para = Para {
            head: ctx.indent + 20.0,
            first: ctx.indent + 20.0,
            tail: 20.0,
            before: 20.0 + self.size * 0.35,
            after: 20.0 + self.size * 0.95,
            align: Align::Center,
            ..Para::default()
        };
        let attrs = Attrs { style, link: None };
        let start = self.out.len;
        self.append_embed(Embed::Diagram { code: code.to_string(), dark: self.dark }, &attrs);
        self.append("\n", &attrs);
        self.push_decoration(decoration, start);
    }

    fn render_quote(&mut self, node: &Node, alert: Option<Alert>, ctx: &Ctx) {
        let color = match alert {
            Some(Alert::Note) => Color::Note,
            Some(Alert::Tip) => Color::Tip,
            Some(Alert::Important) => Color::Important,
            Some(Alert::Warning) => Color::Warning,
            Some(Alert::Caution) => Color::Caution,
            None => Color::Tertiary,
        };
        let mut decoration = Decoration::new(if alert.is_some() { DecorationKind::Alert } else { DecorationKind::Quote }, ctx.indent);
        decoration.color = color;
        let mut inner = ctx.clone();
        inner.indent += if alert.is_some() { 20.0 } else { 18.0 };
        if alert.is_none() {
            inner.color = Color::Secondary;
        }
        let start = self.out.len;
        if let Some(alert) = alert {
            let mut title = self.attrs(&inner);
            title.style.size = self.size * 0.94;
            title.style.weight = 600;
            title.style.color = color;
            title.style.para.after = self.size * 0.35;
            self.append_embed(Embed::AlertIcon(alert), &title);
            self.append(&format!(" {}\n", t(alert.title())), &title);
            if self.capturing == 0 {
                self.blocks.push((node.range.start, start));
            }
        }
        for child in &node.children {
            self.block(child, &inner);
        }
        self.push_decoration(decoration, start);
    }

    fn render_list(&mut self, node: &Node, first_number: Option<u64>, ctx: &Ctx) {
        let items: Vec<&Node> = node.children.iter().filter(|c| c.kind == Kind::Item).collect();
        let tight = !items.iter().any(|i| i.children.iter().any(|c| c.kind == Kind::Paragraph));
        let ordered = first_number.is_some();
        let start_number = first_number.unwrap_or(1) as usize;
        let bullets = ["•", "◦", "▪"];
        let bullet = bullets[self.list_depth % bullets.len()];
        let size = self.size;
        let marker_width = if ordered {
            let widest = format!("{}.", start_number + items.len().saturating_sub(1));
            (size * 1.05).max(widest.chars().count() as f32 * size * 0.58)
        } else {
            size * 0.85
        };
        let marker_x = ctx.indent + marker_width;
        let text_indent = marker_x + size * 0.5;
        self.list_depth += 1;
        for (index, item) in items.iter().enumerate() {
            let mut line = self.attrs(ctx);
            let mut para = self.para(ctx, Some(if tight { size * 0.3 } else { size * 0.7 }));
            para.first = ctx.indent;
            para.head = text_indent;
            para.tabs = vec![(marker_x, true), (text_indent, false)];
            line.style.para = para;
            let inner = Ctx { indent: text_indent, color: ctx.color, spacing: if tight { Some(size * 0.3) } else { None } };
            let item_start = self.out.len;
            self.append("\t", &line);
            // Task markers come first in the item, or first inside its paragraph in loose lists.
            let task = item.children.first().and_then(|c| match c.kind {
                Kind::TaskMarker(checked) => Some((checked, c.range.start)),
                Kind::Paragraph => c.children.first().and_then(|g| match g.kind {
                    Kind::TaskMarker(checked) => Some((checked, g.range.start)),
                    _ => None,
                }),
                _ => None,
            });
            if let Some((checked, offset)) = task {
                self.append_embed(Embed::Check { checked, task: Some(offset) }, &line);
            } else {
                let mut marker = line.clone();
                marker.style.color = Color::Secondary;
                let label = if ordered { format!("{}.", start_number + index) } else { bullet.to_string() };
                self.append(&label, &marker);
            }
            self.append("\t", &line);
            let mut text_attrs = line.clone();
            if task.is_some_and(|(checked, _)| checked) {
                text_attrs.style.color = Color::Secondary;
            }
            // Leading inline content (tight items) or the first paragraph shares the marker line.
            let children: Vec<&Node> = item.children.iter().filter(|c| !matches!(c.kind, Kind::TaskMarker(_))).collect();
            let inline_count = children.iter().take_while(|c| c.is_inline()).count();
            let mut rest = &children[..];
            if inline_count > 0 {
                let inline: Vec<Node> = children[..inline_count].iter().map(|n| (*n).clone()).collect();
                self.render_paragraph(&inline, &inner, Some(text_attrs.clone()));
                if self.capturing == 0 {
                    self.blocks.push((item.range.start, item_start));
                }
                rest = &children[inline_count..];
            } else if let Some(first) = children.first().filter(|c| c.kind == Kind::Paragraph) {
                let content: Vec<Node> =
                    first.children.iter().filter(|c| !matches!(c.kind, Kind::TaskMarker(_))).cloned().collect();
                self.render_paragraph(&content, &inner, Some(text_attrs.clone()));
                if self.capturing == 0 {
                    self.blocks.push((first.range.start, item_start));
                }
                rest = &children[1..];
            } else {
                self.append("\n", &line);
            }
            for child in rest {
                if child.is_inline() {
                    self.render_paragraph(std::slice::from_ref(*child), &inner, None);
                } else {
                    self.block(child, &inner);
                }
            }
        }
        self.list_depth -= 1;
        if self.list_depth == 0 {
            self.set_trailing_spacing(size * 0.75);
        }
    }

    fn render_rule(&mut self, ctx: &Ctx) {
        let decoration = Decoration::new(DecorationKind::Rule, ctx.indent);
        let mut style = self.body();
        style.size = 3.0;
        let mut para = self.para(ctx, None);
        para.before = self.size * 0.7;
        para.after = self.size * 1.3;
        para.line_spacing = 0.0;
        style.para = para;
        let start = self.out.len;
        self.append(" \n", &Attrs { style, link: None });
        self.push_decoration(decoration, start);
    }

    fn render_table(&mut self, node: &Node, alignments: &[Align], ctx: &Ctx) {
        let mut rows = Vec::new();
        for (row_index, row) in node.children.iter().enumerate() {
            // The head holds its cells directly; body rows are TableRow nodes.
            let cells: Vec<&Node> = match row.kind {
                Kind::TableHead => row.children.iter().filter(|c| c.kind == Kind::TableCell).collect(),
                Kind::TableRow => row.children.iter().collect(),
                _ => continue,
            };
            let mut line = Vec::new();
            for (column, cell) in cells.iter().enumerate() {
                let header = row_index == 0 && row.kind == Kind::TableHead;
                let mut attrs = self.attrs(ctx);
                attrs.style.size = self.size * 0.92;
                if header {
                    attrs.style.weight = 600;
                }
                let captured = self.capture(|r| {
                    let open = r.html.len();
                    for child in &cell.children {
                        r.inline(child, &attrs);
                    }
                    r.close_inline_frames(open);
                });
                let runs = self.cell_runs(&captured);
                line.push(Cell { runs, header, align: alignments.get(column).copied().unwrap_or_default() });
            }
            rows.push(line);
        }
        self.append_table(rows, ctx);
    }

    fn append_table(&mut self, rows: Vec<Vec<Cell>>, ctx: &Ctx) {
        let columns = rows.iter().map(Vec::len).max().unwrap_or(0);
        if columns == 0 {
            return;
        }
        let mut attrs = self.attrs(ctx);
        attrs.style.para.align = Align::Natural;
        attrs.style.para.after = self.size * 0.95;
        attrs.style.para.before = self.size * 0.2;
        self.append_embed(Embed::Table(Table { rows, columns }), &attrs);
        self.append("\n", &attrs);
    }

    // MARK: Footnotes

    fn footnote_number(&mut self, label: &str) -> usize {
        if let Some(i) = self.footnotes.iter().position(|l| l == label) {
            return i + 1;
        }
        self.footnotes.push(label.to_string());
        self.footnotes.len()
    }

    fn render_footnotes(&mut self) {
        if self.footnote_defs.is_empty() {
            return;
        }
        let defs = std::mem::take(&mut self.footnote_defs);
        let ctx = Ctx::default();
        self.ensure_newline(&self.attrs(&ctx));
        self.render_rule(&ctx);
        let mut ordered: Vec<(usize, Node)> = defs
            .into_iter()
            .map(|d| {
                let label = match &d.kind {
                    Kind::FootnoteDefinition(l) => l.clone(),
                    _ => String::new(),
                };
                (self.footnote_number(&label), d)
            })
            .collect();
        ordered.sort_by_key(|(n, _)| *n);
        let small = Ctx { indent: 0.0, color: Color::Secondary, spacing: Some(self.size * 0.4) };
        for (number, def) in ordered {
            let label = match &def.kind {
                Kind::FootnoteDefinition(l) => l.clone(),
                _ => String::new(),
            };
            self.anchors.push((format!("fn-{label}"), self.out.len));
            let mut attrs = self.attrs(&small);
            attrs.style.size = self.size * 0.85;
            self.append(&format!("{number}. "), &attrs);
            let start = self.out.len;
            for (index, child) in def.children.iter().enumerate() {
                if index == 0 && child.kind == Kind::Paragraph {
                    let open = self.html.len();
                    for inline in &child.children {
                        self.inline(inline, &attrs);
                    }
                    self.close_inline_frames(open);
                    self.append("\n", &attrs);
                } else {
                    self.block(child, &small);
                }
            }
            if self.out.len == start {
                self.append("\n", &attrs);
            }
            self.blocks.push((def.range.start, start));
        }
    }

    // MARK: Inline content

    fn inline(&mut self, node: &Node, attrs: &Attrs) {
        let mut a = attrs.clone();
        match &node.kind {
            Kind::Text(text) => {
                if self.hidden_depth > 0 {
                    return;
                }
                let styled = self.html_inline(&a);
                if self.link_depth == 0 && styled.link.is_none() {
                    self.append_autolinked(text, &styled);
                } else {
                    self.append(text, &styled);
                }
            }
            Kind::Strong => {
                a.style = a.style.bold();
                self.inline_children(node, &a);
            }
            Kind::Emphasis => {
                a.style = a.style.italic();
                self.inline_children(node, &a);
            }
            Kind::Strikethrough => {
                a.style.strike = true;
                self.inline_children(node, &a);
            }
            Kind::Superscript | Kind::Subscript => {
                let sup = node.kind == Kind::Superscript;
                a.style.size *= 0.75;
                a.style.rise = if sup { self.size * 0.35 } else { -self.size * 0.18 };
                self.inline_children(node, &a);
            }
            Kind::Code(code) => {
                if self.hidden_depth > 0 {
                    return;
                }
                a.style.family = Family::Mono;
                a.style.size *= 0.86;
                a.style.background = Some(Color::InlineCode);
                let styled = self.html_inline(&a);
                self.append(code, &styled);
            }
            Kind::Link { dest, .. } => {
                if let Some(url) = self.link_url(dest) {
                    a.link = Some(url);
                    a.style.color = Color::Accent;
                }
                self.link_depth += 1;
                self.inline_children(node, &a);
                self.link_depth -= 1;
            }
            Kind::Image { dest, title } => {
                if self.hidden_depth > 0 {
                    return;
                }
                let alt = node.plain_text();
                if let Some(url) = self.resolve(dest) {
                    let styled = self.html_inline(&a);
                    let title = (!title.is_empty()).then(|| title.clone());
                    self.append_image(url, &alt, None, None, title, &styled);
                } else {
                    self.append(&alt, &a);
                }
            }
            Kind::SoftBreak => {
                let styled = self.html_inline(&a);
                self.append(" ", &styled);
            }
            Kind::HardBreak => self.append(&LINE_BREAK.to_string(), &a),
            Kind::InlineHtml(raw) | Kind::Html(raw) => self.inline_html(raw, &a),
            Kind::FootnoteRef(label) => {
                let number = self.footnote_number(label);
                a.style.size *= 0.75;
                a.style.rise = self.size * 0.35;
                a.style.color = Color::Accent;
                a.link = Some(format!("x-mdlite-anchor:fn-{label}"));
                self.append(&format!("[{number}]"), &a);
            }
            Kind::TaskMarker(checked) => {
                self.append_embed(Embed::Check { checked: *checked, task: Some(node.range.start) }, &a);
                self.append(" ", &a);
            }
            _ => self.inline_children(node, &a),
        }
    }

    fn inline_children(&mut self, node: &Node, attrs: &Attrs) {
        for child in &node.children {
            self.inline(child, attrs);
        }
    }

    fn append_autolinked(&mut self, text: &str, attrs: &Attrs) {
        let links = gfm::autolinks(text);
        if links.is_empty() {
            self.append(text, attrs);
            return;
        }
        let mut cursor = 0;
        for (range, url) in links {
            if range.start > cursor {
                self.append(&text[cursor..range.start], attrs);
            }
            let mut link = attrs.clone();
            link.link = Some(url);
            link.style.color = Color::Accent;
            self.append(&text[range.clone()], &link);
            cursor = range.end;
        }
        if cursor < text.len() {
            self.append(&text[cursor..], attrs);
        }
    }

    /// Absolute URL for a destination, relative to the document's folder.
    pub fn resolve(&self, destination: &str) -> Option<String> {
        resolve_url(destination, self.base_dir.as_deref())
    }

    fn link_url(&self, destination: &str) -> Option<String> {
        if let Some(anchor) = destination.strip_prefix('#') {
            return Some(format!("x-mdlite-anchor:{}", percent_decode(anchor)));
        }
        let url = self.resolve(destination)?;
        let scheme = url.split(':').next()?.to_lowercase();
        ["https", "http", "mailto", "file"].contains(&scheme.as_str()).then_some(url)
    }

    fn append_image(&mut self, url: String, alt: &str, width: Option<f32>, height: Option<f32>, title: Option<String>, attrs: &Attrs) {
        let scheme = url.split(':').next().unwrap_or("").to_lowercase();
        if (scheme == "http" || scheme == "https") && !self.remote.contains(&url) {
            self.remote.push(url.clone());
        }
        let link = attrs.link.clone();
        self.append_embed(Embed::Image { url, alt: alt.to_string(), width, height, title, link }, attrs);
    }

    // MARK: HTML

    fn html_alignment(&self) -> Option<Align> {
        static TEXT_ALIGN: std::sync::LazyLock<regex::Regex> =
            std::sync::LazyLock::new(|| regex::Regex::new(r"text-align\s*:\s*([a-z]+)").unwrap());
        for frame in self.html.iter().rev() {
            if frame.name == "center" {
                return Some(Align::Center);
            }
            let mut value = frame.attributes.get("align").map(|v| v.to_lowercase());
            if value.is_none() {
                if let Some(style) = frame.attributes.get("style") {
                    value = TEXT_ALIGN.captures(&style.to_lowercase()).map(|c| c[1].to_string());
                }
            }
            match value.as_deref() {
                Some("center") | Some("middle") => return Some(Align::Center),
                Some("right") | Some("end") => return Some(Align::Right),
                Some("left") | Some("start") => return Some(Align::Left),
                Some("justify") => return Some(Align::Fill),
                _ => continue,
            }
        }
        None
    }

    fn html_inline(&self, base: &Attrs) -> Attrs {
        if self.html.is_empty() {
            return base.clone();
        }
        let mut a = base.clone();
        let in_pre = self.html.iter().any(|f| f.name == "pre");
        for frame in &self.html {
            match frame.name.as_str() {
                "b" | "strong" | "th" | "dt" | "summary" => a.style = a.style.bold(),
                "i" | "em" | "cite" | "var" | "dfn" | "address" => a.style = a.style.italic(),
                "code" | "tt" | "samp" | "kbd" => {
                    a.style.family = Family::Mono;
                    a.style.size *= 0.88;
                    if frame.name == "kbd" {
                        a.style.weight = a.style.weight.max(500);
                    }
                    if !in_pre {
                        a.style.background = Some(Color::InlineCode);
                    }
                }
                "pre" => {
                    a.style.family = Family::Mono;
                    a.style.size = self.size * 0.8;
                }
                "u" | "ins" => a.style.underline = true,
                "s" | "strike" | "del" => a.style.strike = true,
                "mark" => a.style.background = Some(Color::Mark),
                "small" | "figcaption" => {
                    a.style.size *= 0.85;
                    if frame.name == "figcaption" {
                        a.style.color = Color::Secondary;
                    }
                }
                "big" => a.style.size *= 1.15,
                "sub" | "sup" => {
                    a.style.size *= 0.75;
                    a.style.rise = if frame.name == "sup" { self.size * 0.35 } else { -self.size * 0.18 };
                }
                "a" => {
                    if let Some(url) = frame.attributes.get("href").and_then(|h| self.link_url(h)) {
                        a.link = Some(url);
                        a.style.color = Color::Accent;
                    }
                }
                "blockquote" => a.style.color = Color::Secondary,
                "h1" | "h2" | "h3" | "h4" | "h5" | "h6" => {
                    let level = frame.name[1..].parse().unwrap_or(1);
                    let heading = self.heading_attrs(level, &Ctx::default());
                    a.style.size = heading.style.size;
                    a.style.weight = heading.style.weight;
                }
                _ => {}
            }
        }
        a
    }

    fn html_attrs(&self, ctx: &Ctx) -> Attrs {
        let mut ctx = ctx.clone();
        if self.html.iter().any(|f| f.name == "blockquote") {
            ctx.color = Color::Secondary;
        }
        let mut a = self.attrs(&ctx);
        let lists = self.html.iter().filter(|f| f.name == "ul" || f.name == "ol").count() as f32;
        let quotes = self.html.iter().filter(|f| f.name == "blockquote").count() as f32;
        let indent = ctx.indent + quotes * 18.0 + lists * self.size * 1.4;
        let mut para = self.para(&ctx, None);
        para.first = indent;
        para.head = indent;
        if let Some(heading) = self
            .html
            .iter()
            .rev()
            .find(|f| f.name.len() == 2 && f.name.starts_with('h') && f.name[1..].parse::<u8>().is_ok())
        {
            let level = heading.name[1..].parse().unwrap_or(1);
            let h = self.heading_attrs(level, &ctx);
            para.before = h.style.para.before;
            para.after = h.style.para.after;
        }
        if lists > 0.0 {
            para.first = indent - self.size * 1.4;
            para.tabs = vec![(indent - self.size * 0.5, true), (indent, false)];
            para.after = self.size * 0.3;
        }
        if self.html.iter().any(|f| f.name == "pre") {
            para.head += 18.0;
            para.first = para.head;
            para.tail = 18.0;
            para.after = 0.0;
        }
        if self.html.iter().any(|f| f.name == "summary" || f.name == "dt") {
            para.after = self.size * 0.35;
        }
        if self.html.iter().any(|f| f.name == "dd") {
            para.head += self.size * 1.4;
            para.first += self.size * 1.4;
        }
        a.style.para = para;
        a.style.color = ctx.color;
        self.html_inline(&a)
    }

    fn render_html(&mut self, raw: &str, ctx: &Ctx) {
        let tokens = html::tokenize(raw);
        let mut skip_until: Option<usize> = None;
        for token in tokens {
            match token {
                Token::Comment => {}
                Token::Text(text) => {
                    if skip_until.is_none() {
                        self.html_text(&text, ctx);
                    }
                }
                Token::Open { name, attributes, self_closing, start, .. } => {
                    if let Some(end) = skip_until {
                        if start < end {
                            continue;
                        }
                    }
                    skip_until = None;
                    if name == "svg" && self.hidden_depth == 0 {
                        let lower = raw.to_lowercase();
                        if let Some(close) = lower[start..].find("</svg>") {
                            let end = start + close + "</svg>".len();
                            let width = attributes.get("width").and_then(|w| dimension(Some(w), self.max_image_width));
                            let attrs = self.html_attrs(ctx);
                            self.append_embed(Embed::Svg { data: raw[start..end].to_string(), width }, &attrs);
                            skip_until = Some(end);
                            continue;
                        }
                    }
                    self.open_html(&name, attributes, self_closing, ctx);
                }
                Token::Close { name } => {
                    if skip_until.is_some() {
                        if name == "svg" {
                            skip_until = None;
                        }
                        continue;
                    }
                    if let Some(index) = self.html.iter().rposition(|f| f.name == name) {
                        while self.html.len() > index {
                            self.close_html_frame(ctx);
                        }
                    }
                }
            }
        }
    }

    fn html_text(&mut self, raw: &str, ctx: &Ctx) {
        if self.hidden_depth > 0 {
            return;
        }
        if !self.html_tables.is_empty() && !self.html.iter().any(|f| f.name == "td" || f.name == "th") {
            return;
        }
        let mut text = html::decode_entities(raw);
        if !self.html.iter().any(|f| f.name == "pre") {
            text = collapse_whitespace(&text);
            if self.at_line_start() || self.last_char() == Some(' ') {
                text = text.trim_start_matches(' ').to_string();
            }
        } else if self.at_line_start() && text.starts_with('\n') {
            text.remove(0);
        }
        if text.is_empty() {
            return;
        }
        let attrs = self.html_attrs(ctx);
        self.append(&text, &attrs);
    }

    fn open_html(&mut self, name: &str, attributes: HashMap<String, String>, self_closing: bool, ctx: &Ctx) {
        if self.hidden_depth > 0 {
            if !self_closing {
                self.html.push(HtmlFrame::new(name, attributes));
                if html::is_hidden(name) {
                    self.hidden_depth += 1;
                }
            }
            return;
        }
        match name {
            "br" => {
                let attrs = self.html_attrs(ctx);
                self.append(&LINE_BREAK.to_string(), &attrs);
                return;
            }
            "hr" => {
                let attrs = self.html_attrs(ctx);
                self.ensure_newline(&attrs);
                self.render_rule(ctx);
                return;
            }
            "img" => {
                let src = self.picture_source.clone().or_else(|| attributes.get("src").cloned());
                if let Some(url) = src.and_then(|s| self.resolve(&s)) {
                    let attrs = self.html_attrs(ctx);
                    let width = dimension(attributes.get("width").map(String::as_str), self.max_image_width);
                    let height = dimension(attributes.get("height").map(String::as_str), self.max_image_width);
                    let alt = attributes.get("alt").cloned().unwrap_or_default();
                    let title = attributes.get("title").cloned();
                    self.append_image(url, &alt, width, height, title, &attrs);
                }
                return;
            }
            "source" => {
                if self.html.last().is_some_and(|f| f.name == "picture") {
                    if let (Some(media), Some(srcset)) = (attributes.get("media"), attributes.get("srcset")) {
                        let media = media.to_lowercase();
                        if media.contains("prefers-color-scheme") && media.contains(if self.dark { "dark" } else { "light" }) {
                            self.picture_source = srcset.split(',').next().and_then(|s| s.split_whitespace().next()).map(str::to_string);
                        }
                    }
                }
                return;
            }
            "input" => {
                if attributes.get("type").is_some_and(|t| t.eq_ignore_ascii_case("checkbox")) {
                    let attrs = self.html_attrs(ctx);
                    self.append_embed(Embed::Check { checked: attributes.contains_key("checked"), task: None }, &attrs);
                    self.append(" ", &attrs);
                }
                return;
            }
            _ if html::is_void(name) => return,
            _ => {}
        }
        if html::is_block(name) && name != "td" && name != "th" && name != "tr" {
            let attrs = self.html_attrs(ctx);
            self.ensure_newline(&attrs);
        }
        let mut frame = HtmlFrame::new(name, attributes);
        frame.start = self.out.len;
        frame.start_byte = self.out.text.len();
        match name {
            "blockquote" => {
                let depth = self.html.iter().filter(|f| f.name == "blockquote").count() as f32;
                frame.decoration = Some(Decoration::new(DecorationKind::Quote, ctx.indent + depth * 18.0));
            }
            "pre" => {
                let mut decoration = Decoration::new(DecorationKind::Code, ctx.indent);
                decoration.pad_top = 14.0;
                decoration.pad_bottom = 14.0;
                frame.decoration = Some(decoration);
            }
            "ol" => frame.counter = frame.attributes.get("start").and_then(|s| s.parse().ok()).unwrap_or(1),
            "table" => self.html_tables.push(HtmlTable::default()),
            "thead" => {
                if let Some(t) = self.html_tables.last_mut() {
                    t.in_head = true;
                }
            }
            "tbody" | "tfoot" => {
                if let Some(t) = self.html_tables.last_mut() {
                    t.in_head = false;
                }
            }
            "tr" => {
                if let Some(table) = self.html_tables.last_mut() {
                    if let Some(row) = table.row.take() {
                        table.rows.push(row);
                    }
                    table.row = Some(Vec::new());
                }
            }
            "td" | "th" => {
                if let Some(table) = self.html_tables.last_mut() {
                    if table.row.is_none() {
                        table.row = Some(Vec::new());
                    }
                }
                frame.saved = Some(std::mem::take(&mut self.out));
                self.capturing += 1;
            }
            _ => {}
        }
        if html::is_hidden(name) {
            self.hidden_depth += 1;
        }
        if self_closing {
            return;
        }
        self.html.push(frame);
        if name == "li" {
            let list_index = self.html.iter().rposition(|f| f.name == "ul" || f.name == "ol");
            let mut marker = "•".to_string();
            if let Some(index) = list_index {
                if self.html[index].name == "ol" {
                    marker = format!("{}.", self.html[index].counter);
                    self.html[index].counter += 1;
                }
            }
            let attrs = self.html_attrs(ctx);
            self.append("\t", &attrs);
            let mut marker_attrs = attrs.clone();
            marker_attrs.style.color = Color::Secondary;
            self.append(&marker, &marker_attrs);
            self.append("\t", &attrs);
        } else if name == "summary" {
            let attrs = self.html_attrs(ctx);
            self.append("\u{25BE} ", &attrs);
        }
    }

    fn close_html_frame(&mut self, ctx: &Ctx) {
        let Some(frame) = self.html.last() else { return };
        if self.hidden_depth > 0 {
            if html::is_hidden(&frame.name) {
                self.hidden_depth -= 1;
            }
            self.html.pop();
            return;
        }
        let name = frame.name.clone();
        match name.as_str() {
            "td" | "th" => {
                let mut frame = self.html.pop().unwrap();
                let content = match frame.saved.take() {
                    Some(saved) => std::mem::replace(&mut self.out, saved),
                    None => std::mem::take(&mut self.out),
                };
                self.capturing = self.capturing.saturating_sub(1);
                let header = name == "th" || self.html_tables.last().is_some_and(|t| t.in_head);
                let align = match frame.attributes.get("align").map(|a| a.to_lowercase()).as_deref() {
                    Some("center") => Align::Center,
                    Some("right") => Align::Right,
                    _ => Align::Natural,
                };
                let mut runs = self.cell_runs(&content);
                if header {
                    for run in &mut runs {
                        let mut style = self.styles[run.style].clone();
                        style.weight = 600;
                        style.size = self.size * 0.92;
                        run.style = self.style_id(&style);
                    }
                }
                if let Some(row) = self.html_tables.last_mut().and_then(|t| t.row.as_mut()) {
                    row.push(Cell { runs, header, align });
                }
                return;
            }
            "tr" => {
                if let Some(table) = self.html_tables.last_mut() {
                    if let Some(row) = table.row.take() {
                        table.rows.push(row);
                    }
                }
                self.html.pop();
                return;
            }
            "table" => {
                self.html.pop();
                if let Some(mut table) = self.html_tables.pop() {
                    if let Some(row) = table.row.take() {
                        table.rows.push(row);
                    }
                    let attrs = self.html_attrs(ctx);
                    self.ensure_newline(&attrs);
                    self.append_table(table.rows, ctx);
                }
                return;
            }
            "picture" => self.picture_source = None,
            "h1" | "h2" | "h3" | "h4" | "h5" | "h6" => {
                let (start, start_byte) = (frame.start, frame.start_byte);
                if self.out.len > start {
                    let level: u8 = name[1..].parse().unwrap_or(1);
                    let attrs = self.html_attrs(ctx);
                    self.ensure_newline(&attrs);
                    let title = self.out.text[start_byte..].to_string();
                    let end = self.out.len;
                    let source = self.current_source;
                    self.add_outline(&title, level, start, end, source);
                    if level <= 2 {
                        self.push_decoration(Decoration::new(DecorationKind::HeadingRule, ctx.indent), start);
                    }
                }
            }
            _ => {}
        }
        if html::is_block(&name) {
            let attrs = self.html_attrs(ctx);
            self.ensure_newline(&attrs);
        }
        let mut frame = self.html.pop().unwrap();
        if let Some(decoration) = frame.decoration.take() {
            let is_pre = frame.name == "pre";
            self.push_decoration(decoration, frame.start);
            if is_pre {
                self.set_trailing_spacing(self.size * 0.9);
            }
        }
    }

    fn close_inline_frames(&mut self, count: usize) {
        while self.html.len() > count {
            let Some(last) = self.html.last() else { break };
            if html::is_block(&last.name) {
                break;
            }
            if html::is_hidden(&last.name) && self.hidden_depth > 0 {
                self.hidden_depth -= 1;
            }
            self.html.pop();
        }
    }

    fn inline_html(&mut self, raw: &str, attrs: &Attrs) {
        for token in html::tokenize(raw) {
            match token {
                Token::Open { name, attributes, self_closing, .. } => {
                    if self.hidden_depth > 0 && self_closing {
                        continue;
                    }
                    match name.as_str() {
                        "br" => {
                            if self.hidden_depth == 0 {
                                let styled = self.html_inline(attrs);
                                self.append(&LINE_BREAK.to_string(), &styled);
                            }
                        }
                        "img" => {
                            if self.hidden_depth == 0 {
                                if let Some(url) = attributes.get("src").and_then(|s| self.resolve(s)) {
                                    let styled = self.html_inline(attrs);
                                    let width = dimension(attributes.get("width").map(String::as_str), self.max_image_width);
                                    let height = dimension(attributes.get("height").map(String::as_str), self.max_image_width);
                                    let alt = attributes.get("alt").cloned().unwrap_or_default();
                                    let title = attributes.get("title").cloned();
                                    self.append_image(url, &alt, width, height, title, &styled);
                                }
                            }
                        }
                        "input" => {
                            if self.hidden_depth == 0 && attributes.get("type").is_some_and(|t| t.eq_ignore_ascii_case("checkbox")) {
                                self.append_embed(Embed::Check { checked: attributes.contains_key("checked"), task: None }, attrs);
                            }
                        }
                        _ => {
                            if html::is_hidden(&name) {
                                self.hidden_depth += 1;
                            }
                            if !self_closing {
                                let mut frame = HtmlFrame::new(&name, attributes);
                                frame.start = self.out.len;
                                frame.start_byte = self.out.text.len();
                                self.html.push(frame);
                            }
                        }
                    }
                }
                Token::Close { name } => {
                    let Some(index) = self.html.iter().rposition(|f| f.name == name) else { continue };
                    while self.html.len() > index {
                        if let Some(last) = self.html.pop() {
                            if html::is_hidden(&last.name) && self.hidden_depth > 0 {
                                self.hidden_depth -= 1;
                            }
                        }
                    }
                }
                Token::Text(text) => {
                    if self.hidden_depth == 0 {
                        let styled = self.html_inline(attrs);
                        self.append(&html::decode_entities(&text), &styled);
                    }
                }
                Token::Comment => {}
            }
        }
    }
}

fn collapse_whitespace(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut space = false;
    for c in text.chars() {
        if matches!(c, ' ' | '\t' | '\r' | '\n' | '\x0C') {
            if !space {
                out.push(' ');
            }
            space = true;
        } else {
            out.push(c);
            space = false;
        }
    }
    out
}

fn dimension(value: Option<&str>, max_width: f32) -> Option<f32> {
    let mut value = value?.trim().to_lowercase();
    if value.is_empty() {
        return None;
    }
    if let Some(percent) = value.strip_suffix('%') {
        return percent.parse::<f32>().ok().map(|p| p / 100.0 * max_width);
    }
    if let Some(px) = value.strip_suffix("px") {
        value = px.to_string();
    }
    value.parse::<f32>().ok().filter(|v| *v > 0.0)
}

fn has_scheme(text: &str) -> bool {
    let Some(colon) = text.find(':') else { return false };
    let scheme = &text[..colon];
    colon > 1
        && scheme.chars().next().is_some_and(|c| c.is_ascii_alphabetic())
        && scheme.chars().all(|c| c.is_ascii_alphanumeric() || "+.-".contains(c))
}

pub fn percent_decode(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() && bytes[i + 1].is_ascii_hexdigit() && bytes[i + 2].is_ascii_hexdigit() {
            let hex = |b: u8| (b as char).to_digit(16).unwrap_or(0) as u8;
            out.push(hex(bytes[i + 1]) * 16 + hex(bytes[i + 2]));
            i += 3;
            continue;
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

pub fn file_uri(path: &Path) -> String {
    let mut out = String::from("file://");
    for b in path.to_string_lossy().bytes() {
        if b.is_ascii_alphanumeric() || b"/-_.~".contains(&b) {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

/// Resolves a Markdown link or image destination. Relative paths become `file://` URLs
/// next to the document; without a folder they cannot be resolved.
pub fn resolve_url(destination: &str, base_dir: Option<&Path>) -> Option<String> {
    let trimmed = destination.trim();
    if trimmed.is_empty() {
        return None;
    }
    if has_scheme(trimmed) {
        return Some(trimmed.to_string());
    }
    if let Some(rest) = trimmed.strip_prefix("//") {
        return Some(format!("https://{rest}"));
    }
    let split = trimmed.find(['#', '?']).unwrap_or(trimmed.len());
    let (path_part, suffix) = trimmed.split_at(split);
    let decoded = percent_decode(path_part);
    let path = if decoded.starts_with('/') {
        PathBuf::from(&decoded)
    } else if let Some(stripped) = decoded.strip_prefix("~/") {
        PathBuf::from(std::env::var("HOME").ok()?).join(stripped)
    } else {
        base_dir?.join(&decoded)
    };
    let fragment = suffix.strip_prefix('?').map_or(suffix.to_string(), |_| String::new());
    Some(format!("{}{}", file_uri(&normalize(&path)), if fragment.starts_with('#') { fragment } else { String::new() }))
}

fn normalize(path: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for component in path.components() {
        match component {
            std::path::Component::ParentDir => {
                out.pop();
            }
            std::path::Component::CurDir => {}
            other => out.push(other),
        }
    }
    out
}

#[cfg(test)]
pub fn render(text: &str, size: f32, base_dir: Option<&Path>) -> Rendered {
    Renderer::new(size, base_dir).render(text)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn link_at(r: &Rendered, needle: &str) -> Option<String> {
        let byte = r.text.find(needle)?;
        let offset = r.text[..byte].chars().count();
        r.link_at(offset).map(|l| l.url.clone())
    }

    #[test]
    fn headings_and_unicode_ranges() {
        let r = render("# Hola 🌿\n\nTexto\n\n## Segundo\n", 17.0, None);
        assert_eq!(r.outline.iter().map(|o| o.title.as_str()).collect::<Vec<_>>(), ["Hola 🌿", "Segundo"]);
        assert_eq!(r.outline.iter().map(|o| o.level).collect::<Vec<_>>(), [1, 2]);
        let chars: Vec<char> = r.text.chars().collect();
        for heading in &r.outline {
            let s: String = chars[heading.start..heading.end].iter().collect();
            assert_eq!(s, format!("{}\n", heading.title));
        }
    }

    #[test]
    fn reference_links_and_emphasis() {
        let r = render("**Fuerte** y *suave* [guía][g].\n\n[g]: https://example.com\n", 17.0, None);
        assert_eq!(r.text, "Fuerte y suave guía.\n");
        assert_eq!(r.style_at(0).unwrap().weight, 700);
        assert_eq!(link_at(&r, "guía").as_deref(), Some("https://example.com"));
    }

    #[test]
    fn lists_code_and_breaks() {
        let r = render("3. Tres\n4. Cuatro\n\n- Uno\n  - Dos\n\n```\nlet x = 1\n```\n\nA  \nB\n", 17.0, None);
        assert!(r.text.contains("3.\tTres"));
        assert!(r.text.contains("4.\tCuatro"));
        assert!(r.text.contains("•\tUno"));
        assert!(r.text.contains("◦\tDos"));
        assert!(r.text.contains("let x = 1"));
        assert!(r.text.contains("A\u{2028}B"));
    }

    #[test]
    fn unsafe_links_are_not_interactive() {
        let r = render("[a](javascript:alert(1)) [b](https://x.y)\n", 17.0, None);
        assert!(r.link_at(0).is_none());
        assert!(r.link_at(2).is_some());
    }

    #[test]
    fn relative_links() {
        let r = render("[a](other.md)\n", 17.0, Some(Path::new("/tmp/docs")));
        assert_eq!(r.link_at(0).unwrap().url, "file:///tmp/docs/other.md");
    }

    #[test]
    fn tables_and_alignment() {
        let r = render("| Name | Count |\n| --- | ---: |\n| A | 2 |\n\n# After table\n", 17.0, None);
        let Embed::Table(table) = &r.embeds[0].1 else { panic!("table") };
        assert_eq!(table.columns, 2);
        assert_eq!(table.rows.len(), 2);
        assert_eq!(table.rows[1][1].align, Align::Right);
        assert_eq!(table.rows[1][1].runs[0].text, "2");
        let chars: Vec<char> = r.text.chars().collect();
        let s: String = chars[r.outline[0].start..r.outline[0].end].iter().collect();
        assert_eq!(s, "After table\n");
    }

    #[test]
    fn html_blocks_render_instead_of_showing_tags() {
        let source = "<p align=\"center\">\n  <img src=\"logo.png\" width=\"80\" alt=\"Logo\">\n</p>\n\nA <kbd>⌘</kbd> key &amp; <b>bold</b>.\n";
        let r = render(source, 17.0, Some(Path::new("/tmp")));
        assert!(!r.text.contains("<p"));
        assert!(!r.text.contains("<img"));
        assert!(!r.text.contains("<kbd>"));
        let (offset, embed) = &r.embeds[0];
        let Embed::Image { width, .. } = embed else { panic!("image") };
        assert_eq!(*width, Some(80.0));
        assert_eq!(r.style_at(*offset).unwrap().para.align, Align::Center);
        assert!(r.text.contains("A ⌘ key & bold."));
        let bold = r.text.find("bold").unwrap();
        assert_eq!(r.style_at(r.text[..bold].chars().count()).unwrap().weight, 700);
    }

    #[test]
    fn centered_div_wraps_markdown_and_hides_comments() {
        let r = render("<div align=\"center\">\n\n# Title\n\n</div>\n\nLeft <!-- hidden -->\n", 17.0, None);
        assert_eq!(r.style_at(r.outline[0].start).unwrap().para.align, Align::Center);
        let left = r.text.find("Left").unwrap();
        assert_ne!(r.style_at(r.text[..left].chars().count()).unwrap().para.align, Align::Center);
        assert!(!r.text.contains("hidden"));
    }

    #[test]
    fn html_table_and_script_filtering() {
        let r = render("<table><tr><th>A</th><th>B</th></tr><tr><td>1</td><td>2</td></tr></table>\n\n<script>alert(1)</script>\n", 17.0, None);
        assert!(!r.text.contains("alert"));
        let Embed::Table(table) = &r.embeds[0].1 else { panic!("table") };
        assert_eq!(table.columns, 2);
        assert!(table.rows[0][0].header);
    }

    #[test]
    fn github_alerts() {
        let r = render("> [!NOTE]\n> Internal packages are shared.\n", 17.0, None);
        assert!(r.text.contains("Note\n"));
        assert!(r.text.contains("Internal packages are shared."));
        assert!(!r.text.contains("[!NOTE]"));
        assert_eq!(r.decorations[0].kind, DecorationKind::Alert);
    }

    #[test]
    fn extended_autolinks_and_no_smart_punctuation() {
        let r = render("See www.example.com. Mail me@example.org -- \"quoted\"\n", 17.0, None);
        assert_eq!(link_at(&r, "www.example.com").as_deref(), Some("http://www.example.com"));
        assert!(link_at(&r, ". Mail").is_none());
        assert_eq!(link_at(&r, "me@").as_deref(), Some("mailto:me@example.org"));
        assert!(r.text.contains("-- \"quoted\""));
    }

    #[test]
    fn code_blocks_are_single_boxes_with_copy_and_highlighting() {
        let r = render("```swift\nlet value = \"hi\"\nreturn value\n```\n", 17.0, None);
        let code = &r.decorations[0];
        assert_eq!(code.kind, DecorationKind::Code);
        assert_eq!(code.code.as_deref(), Some("let value = \"hi\"\nreturn value"));
        assert_eq!(code.label.as_deref(), Some("swift"));
        assert_eq!(code.end - code.start, r.text.chars().count());
        assert_eq!(r.style_at(0).unwrap().color, Color::Keyword);
        let second = r.text.find("return").unwrap();
        assert_eq!(r.style_at(second).unwrap().para.before, 0.0);
    }

    #[test]
    fn task_lists_anchors_and_front_matter() {
        let source = "---\ntitle: Demo\n---\n# My Title\n\n- [ ] one\n- [x] two\n\n[jump](#my-title)\n";
        let r = render(source, 17.0, None);
        assert_eq!(r.outline[0].anchor, "my-title");
        assert_eq!(r.outline[0].source, source.find("# My Title").unwrap());
        let tasks: Vec<usize> = r
            .embeds
            .iter()
            .filter_map(|(_, e)| match e {
                Embed::Check { task, .. } => *task,
                _ => None,
            })
            .collect();
        assert_eq!(tasks, [source.find("[ ]").unwrap(), source.find("[x]").unwrap()]);
        assert_eq!(link_at(&r, "jump").as_deref(), Some("x-mdlite-anchor:my-title"));
        assert!(r.text.contains("title: Demo"));
    }

    #[test]
    fn source_map_handles_multibyte_text() {
        let source = "Ñandú 🌿 texto\n\n## Título\n";
        let r = render(source, 17.0, None);
        let heading = source.find("## Título").unwrap();
        assert_eq!(r.outline[0].source, heading);
        assert_eq!(r.rendered_offset(heading), r.outline[0].start);
    }
}
