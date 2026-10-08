//! Styles Markdown source in place for the editor. The text itself never changes:
//! in live mode syntax markers are hidden until the caret enters their line (Typora style),
//! in code mode everything stays visible with syntax colors.

use super::gfm::{self, Alert};
use super::parse::{self, Kind, Node};
use super::render::{Decoration, DecorationKind};
use super::{highlight, CharMap, Color, Family, Para, Style};
use regex::Regex;
use std::ops::Range;
use std::sync::LazyLock;

/// Partial style: only the fields that are set override what lies below.
#[derive(Clone, Debug, Default)]
pub struct Delta {
    pub family: Option<Family>,
    pub size: Option<f32>,
    pub weight: Option<u16>,
    pub italic: Option<bool>,
    pub strike: Option<bool>,
    pub underline: Option<bool>,
    pub color: Option<Color>,
    pub background: Option<Color>,
    pub para: Option<Para>,
}

impl Delta {
    pub fn color(color: Color) -> Delta {
        Delta { color: Some(color), ..Delta::default() }
    }

    pub fn para(para: Para) -> Delta {
        Delta { para: Some(para), ..Delta::default() }
    }

    pub fn font(font: &Font) -> Delta {
        Delta {
            family: Some(font.family),
            size: Some(font.size),
            weight: Some(font.weight),
            italic: Some(font.italic),
            ..Delta::default()
        }
    }

    pub fn apply(&self, style: &mut Style) {
        if let Some(v) = self.family {
            style.family = v;
        }
        if let Some(v) = self.size {
            style.size = v;
        }
        if let Some(v) = self.weight {
            style.weight = v;
        }
        if let Some(v) = self.italic {
            style.italic = v;
        }
        if let Some(v) = self.strike {
            style.strike = v;
        }
        if let Some(v) = self.underline {
            style.underline = v;
        }
        if let Some(v) = self.color {
            style.color = v;
        }
        if let Some(v) = self.background {
            style.background = Some(v);
        }
        if let Some(v) = &self.para {
            style.para = v.clone();
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Font {
    pub family: Family,
    pub size: f32,
    pub weight: u16,
    pub italic: bool,
}

#[derive(Clone, Debug)]
pub struct Conceal {
    pub range: Range<usize>,
    pub scope: Range<usize>,
    /// The whole line shrinks to a sliver instead of hiding a few characters.
    pub collapse: bool,
    pub decoration: Option<Decoration>,
}

#[derive(Clone, Debug)]
pub struct Task {
    pub range: Range<usize>,
    pub checked: bool,
    pub scope: Range<usize>,
}

/// Character ranges (GTK buffer offsets) of everything the editor shows differently.
#[derive(Clone, Debug, Default)]
pub struct Analysis {
    pub spans: Vec<(Range<usize>, Delta)>,
    pub conceals: Vec<Conceal>,
    pub decorations: Vec<Decoration>,
    pub bullets: Vec<Range<usize>>,
    pub tasks: Vec<Task>,
    pub links: Vec<(Range<usize>, String)>,
}

pub fn overlaps(scope: &Range<usize>, active: &Range<usize>) -> bool {
    // An empty active range (a caret) counts when it touches the scope.
    if active.start == active.end {
        return scope.start <= active.start && active.start < scope.end.max(scope.start + 1);
    }
    scope.start < active.end && active.start < scope.end
}

static HEADING_MARKER: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^[ \t]{0,3}#{1,6}(?:[ \t]+|$)").unwrap());
static HEADING_CLOSING: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"[ \t]+#+[ \t]*$").unwrap());
static QUOTE_MARKER: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^[ \t]{0,3}(?:>[ \t]?)+").unwrap());
static LIST_MARKER: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"^([ \t]*(?:>[ \t]?)*[ \t]*)([-+*]|\d{1,9}[.)])([ \t]+|$)(\[[ xX]\][ \t]+)?").unwrap()
});
static FENCE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^[ \t]{0,3}(?:`{3,}|~{3,})").unwrap());
static FENCE_ONLY: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^[ \t]{0,3}(?:`{3,}|~{3,})[ \t]*$").unwrap());
static TABLE_PIPES: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\||(?m:^[ \t|:\-]+$)").unwrap());

pub struct Styler<'a> {
    pub size: f32,
    pub live: bool,
    /// Width of a string in pixels for a font; used to hang list items under their text.
    pub measure: &'a dyn Fn(&str, &Font) -> f32,
    text: &'a str,
    spans: Vec<(Range<usize>, Delta)>,
    conceals: Vec<Conceal>,
    decorations: Vec<Decoration>,
    bullets: Vec<Range<usize>>,
    tasks: Vec<Task>,
    links: Vec<(Range<usize>, String)>,
    base_dir: Option<std::path::PathBuf>,
}

#[derive(Clone)]
struct Ctx {
    font: Font,
    indent: f32,
    quote_depth: usize,
}

impl<'a> Styler<'a> {
    pub fn new(text: &'a str, size: f32, live: bool, measure: &'a dyn Fn(&str, &Font) -> f32) -> Styler<'a> {
        Styler {
            size,
            live,
            measure,
            text,
            spans: Vec::new(),
            conceals: Vec::new(),
            decorations: Vec::new(),
            bullets: Vec::new(),
            tasks: Vec::new(),
            links: Vec::new(),
            base_dir: None,
        }
    }

    pub fn with_base(mut self, base: Option<&std::path::Path>) -> Self {
        self.base_dir = base.map(std::path::Path::to_path_buf);
        self
    }

    pub fn body_font(&self) -> Font {
        if self.live {
            Font { family: Family::Body, size: self.size, weight: 400, italic: false }
        } else {
            Font { family: Family::Mono, size: self.size * 0.82, weight: 400, italic: false }
        }
    }

    fn code_font(&self) -> Font {
        Font { family: Family::Mono, size: self.size * if self.live { 0.8 } else { 0.82 }, weight: 400, italic: false }
    }

    fn paragraph(&self, indent: f32, head: Option<f32>) -> Para {
        Para {
            line_spacing: if self.live { self.size * 0.3 } else { self.size * 0.22 },
            after: if self.live { self.size * 0.12 } else { 0.0 },
            first: indent,
            head: head.unwrap_or(indent),
            ..Para::default()
        }
    }

    /// The style every character starts from.
    pub fn base_style(&self) -> Style {
        let font = self.body_font();
        let mut style = Style::body(font.size);
        style.family = font.family;
        style.para = self.paragraph(0.0, None);
        style
    }

    fn marker_color(&self) -> Color {
        if self.live { Color::Tertiary } else { Color::Accent }
    }

    pub fn analyze(mut self) -> Analysis {
        let document = parse::parse(self.text);
        self.empty_lines();
        let ctx = Ctx { font: self.body_font(), indent: 0.0, quote_depth: 0 };
        for child in &document.children {
            self.visit(child, &ctx);
        }
        let map = CharMap::new(self.text);
        let c = |r: &Range<usize>| map.char(r.start)..map.char(r.end);
        let convert_decoration = |mut d: Decoration| {
            d.start = map.char(d.start);
            d.end = map.char(d.end);
            d
        };
        Analysis {
            spans: self.spans.iter().map(|(r, d)| (c(r), d.clone())).collect(),
            conceals: self
                .conceals
                .into_iter()
                .map(|x| Conceal {
                    range: c(&x.range),
                    scope: c(&x.scope),
                    collapse: x.collapse,
                    decoration: x.decoration.map(convert_decoration),
                })
                .collect(),
            decorations: self.decorations.into_iter().map(convert_decoration).collect(),
            bullets: self.bullets.iter().map(c).collect(),
            tasks: self.tasks.iter().map(|t| Task { range: c(&t.range), checked: t.checked, scope: c(&t.scope) }).collect(),
            links: self.links.iter().map(|(r, u)| (c(r), u.clone())).collect(),
        }
    }

    // MARK: Helpers (byte ranges)

    fn span(&mut self, range: Range<usize>, delta: Delta) {
        if range.start < range.end && range.end <= self.text.len() {
            self.spans.push((range, delta));
        }
    }

    fn conceal(&mut self, range: Range<usize>, scope: Range<usize>, collapse: bool, decoration: Option<Decoration>) {
        if self.live && range.start < range.end && range.end <= self.text.len() {
            self.conceals.push(Conceal { range, scope, collapse, decoration });
        }
    }

    /// The full lines (with terminators) covering a range, like NSString's lineRange.
    fn lines(&self, range: Range<usize>) -> Range<usize> {
        let len = self.text.len();
        let s = self.floor(range.start.min(len));
        let e = self.floor(range.end.max(s).min(len));
        let start = self.text[..s].rfind('\n').map_or(0, |i| i + 1);
        let end = if e > s && self.text.as_bytes()[e - 1] == b'\n' {
            e
        } else {
            self.text[e..].find('\n').map_or(len, |i| e + i + 1)
        };
        start..end
    }

    /// The nearest character boundary at or before a byte offset.
    fn floor(&self, mut offset: usize) -> usize {
        while offset > 0 && !self.text.is_char_boundary(offset) {
            offset -= 1;
        }
        offset
    }

    fn line_at(&self, offset: usize) -> Range<usize> {
        self.lines(offset..offset)
    }

    /// A line without its terminator.
    fn content(&self, line: Range<usize>) -> Range<usize> {
        let mut end = line.end;
        while end > line.start && matches!(self.text.as_bytes()[end - 1], b'\n' | b'\r') {
            end -= 1;
        }
        line.start..end
    }

    fn find(&self, regex: &Regex, range: Range<usize>) -> Option<regex::Captures<'a>> {
        let text: &'a str = self.text;
        regex.captures(&text[range.clone()])
    }

    fn empty_lines(&mut self) {
        if !self.live {
            return;
        }
        let mut para = self.paragraph(0.0, None);
        para.line_spacing = 0.0;
        let small = self.size * 0.7;
        let mut location = 0;
        while location < self.text.len() {
            let line = self.line_at(location);
            if self.text[line.clone()].trim().is_empty() {
                self.span(line.clone(), Delta { size: Some(small), para: Some(para.clone()), ..Delta::default() });
            }
            if line.end <= location {
                break;
            }
            location = line.end;
        }
    }

    fn child_range(node: &Node) -> Option<Range<usize>> {
        let start = node.children.first()?.range.start;
        let end = node.children.last()?.range.end;
        (end >= start).then_some(start..end)
    }

    fn visit(&mut self, node: &Node, ctx: &Ctx) {
        let range = node.range.clone();
        let mut ctx = ctx.clone();
        match &node.kind {
            Kind::Heading(level) => self.style_heading(node, *level, &mut ctx),
            Kind::Emphasis => {
                ctx.font.italic = true;
                self.span(range.clone(), Delta::font(&ctx.font));
                self.delimiters(range, 1);
            }
            Kind::Strong => {
                ctx.font.weight = ctx.font.weight.max(700);
                self.span(range.clone(), Delta::font(&ctx.font));
                self.delimiters(range, 2);
            }
            Kind::Strikethrough => {
                self.span(range.clone(), Delta { strike: Some(true), ..Delta::default() });
                let count = if self.text[range.clone()].starts_with("~~") { 2 } else { 1 };
                self.delimiters(range, count);
            }
            Kind::Code(_) => {
                let ticks = self.text[range.clone()].bytes().take_while(|b| *b == b'`').count();
                let mut font = ctx.font.clone();
                font.family = Family::Mono;
                font.size *= if self.live { 0.86 } else { 1.0 };
                let mut delta = Delta::font(&font);
                delta.color = Some(if self.live { Color::Text } else { Color::Str });
                self.span(range.clone(), delta);
                if self.live && range.len() > ticks * 2 {
                    self.span(range.start + ticks..range.end - ticks, Delta { background: Some(Color::InlineCode), ..Delta::default() });
                }
                self.delimiters(range, ticks);
                return;
            }
            Kind::Link { dest, .. } => self.style_link(dest, range.clone(), node),
            Kind::Image { dest, .. } => {
                self.style_link(dest, range.clone(), node);
                if let Some(inner) = Self::child_range(node) {
                    self.span(inner, Delta::color(Color::Secondary));
                }
                return;
            }
            Kind::Text(text) => {
                for (link, url) in gfm::autolinks(text) {
                    if link.end <= range.len() && self.text.get(range.clone()) == Some(text.as_str()) {
                        let r = range.start + link.start..range.start + link.end;
                        self.span(r.clone(), Delta::color(Color::Accent));
                        self.links.push((r, url));
                    }
                }
                return;
            }
            Kind::InlineHtml(_) => {
                self.span(range, Delta::color(Color::Meta));
                return;
            }
            Kind::BlockQuote(alert) => self.style_quote(range, *alert, &mut ctx),
            Kind::Item => self.style_list_item(range, &ctx),
            Kind::CodeBlock { info, .. } => {
                self.style_code(range, info.as_deref(), &ctx);
                return;
            }
            Kind::Metadata => {
                let block = self.lines(range);
                let mut delta = Delta::font(&self.code_font());
                delta.color = Some(Color::Secondary);
                self.span(block, delta);
                return;
            }
            Kind::Rule => {
                let line = self.lines(range);
                self.span(line.clone(), Delta::color(Color::Tertiary));
                if self.live {
                    let rule = Decoration {
                        kind: DecorationKind::Rule,
                        start: 0,
                        end: 0,
                        indent: ctx.indent,
                        pad_top: 0.0,
                        pad_bottom: 0.0,
                        color: Color::Tertiary,
                        label: None,
                        code: None,
                    };
                    let mut para = self.paragraph(ctx.indent, None);
                    para.before = self.size * 0.5;
                    para.after = self.size * 0.5;
                    self.span(line.clone(), Delta::para(para));
                    let content = self.content(line.clone());
                    self.conceal(content, line, true, Some(rule));
                }
                return;
            }
            Kind::HtmlBlock => {
                let line = self.lines(range.clone());
                let mut delta = Delta::font(&self.code_font());
                delta.color = Some(Color::Secondary);
                self.span(line, delta);
                let text = &self.text[range.clone()];
                let tokens = highlight::tokens(text, Some("html"));
                for (token, color) in tokens {
                    self.span(range.start + token.start..range.start + token.end, Delta::color(color));
                }
                return;
            }
            Kind::Table(_) => self.style_table(range, &mut ctx),
            _ => {}
        }
        for child in &node.children {
            self.visit(child, &ctx);
        }
    }

    fn delimiters(&mut self, range: Range<usize>, count: usize) {
        if count == 0 || range.len() < count * 2 {
            return;
        }
        let scope = self.lines(range.clone());
        let open = range.start..range.start + count;
        let close = range.end - count..range.end;
        let color = self.marker_color();
        self.span(open.clone(), Delta::color(color));
        self.span(close.clone(), Delta::color(color));
        self.conceal(open, scope.clone(), false, None);
        self.conceal(close, scope, false, None);
    }

    fn heading_font(&self, level: u8) -> Font {
        if !self.live {
            let mut font = self.body_font();
            font.weight = 700;
            return font;
        }
        let scale = [2.0, 1.5, 1.25, 1.08, 0.97, 0.9][(level.clamp(1, 6) - 1) as usize];
        Font { family: Family::Body, size: self.size * scale, weight: if level == 1 { 700 } else { 600 }, italic: false }
    }

    fn style_heading(&mut self, node: &Node, level: u8, ctx: &mut Ctx) {
        let range = node.range.clone();
        let line = self.lines(range.clone());
        ctx.font = self.heading_font(level);
        let mut para = self.paragraph(ctx.indent, None);
        if self.live {
            para.before = if level <= 2 { self.size * 0.9 } else { self.size * 0.6 };
            para.after = if level <= 2 { self.size * 0.55 } else { self.size * 0.3 };
            para.line_spacing = 2.0;
        }
        let mut delta = Delta::font(&ctx.font);
        delta.para = Some(para);
        delta.color = Some(if level == 6 { Color::Secondary } else { Color::Text });
        self.span(line.clone(), delta);
        let first_line = self.line_at(range.start);
        let body = self.content(first_line);
        let marker_color = self.marker_color();
        if let Some(marker) = self.find(&HEADING_MARKER, body.clone()) {
            let m = marker.get(0).unwrap();
            let r = body.start + m.start()..body.start + m.end();
            self.span(r.clone(), Delta::color(marker_color));
            self.conceal(r, line.clone(), false, None);
            if let Some(closing) = self.find(&HEADING_CLOSING, body.clone()) {
                let c = closing.get(0).unwrap();
                let r = body.start + c.start()..body.start + c.end();
                if r.start > body.start + m.end() {
                    self.span(r.clone(), Delta::color(marker_color));
                    self.conceal(r, line.clone(), false, None);
                }
            }
        } else if range.end > body.end + 1 {
            let last = self.line_at(range.end.saturating_sub(1).max(body.end + 1));
            let underline = self.content(last);
            self.span(underline.clone(), Delta::color(marker_color));
            if self.live {
                self.conceal(underline, line.clone(), true, None);
            }
        }
        if self.live && level <= 2 {
            self.decorations.push(Decoration {
                kind: DecorationKind::HeadingRule,
                start: body.start,
                end: body.end,
                indent: ctx.indent,
                pad_top: 0.0,
                pad_bottom: 0.0,
                color: Color::Tertiary,
                label: None,
                code: None,
            });
        }
    }

    fn style_link(&mut self, dest: &str, range: Range<usize>, node: &Node) {
        let Some(inner) = Self::child_range(node) else { return };
        if inner.is_empty() || inner.start <= range.start || inner.end >= range.end {
            return;
        }
        let mut delta = Delta::color(Color::Accent);
        if self.live {
            delta.underline = Some(true);
        }
        self.span(inner.clone(), delta);
        if let Some(url) = super::render::resolve_url(dest, self.base_dir.as_deref()) {
            self.links.push((inner.clone(), url));
        }
        let scope = self.lines(range.clone());
        let color = if self.live { Color::Tertiary } else { Color::Secondary };
        for marker in [range.start..inner.start, inner.end..range.end] {
            if !marker.is_empty() {
                self.span(marker.clone(), Delta::color(color));
                self.conceal(marker, scope.clone(), false, None);
            }
        }
    }

    fn alert_color(alert: Alert) -> Color {
        match alert {
            Alert::Note => Color::Note,
            Alert::Tip => Color::Tip,
            Alert::Important => Color::Important,
            Alert::Warning => Color::Warning,
            Alert::Caution => Color::Caution,
        }
    }

    fn style_quote(&mut self, range: Range<usize>, alert: Option<Alert>, ctx: &mut Ctx) {
        let block = self.lines(range);
        if ctx.quote_depth == 0 {
            let mut location = block.start;
            let marker_color = self.marker_color();
            while location < block.end {
                let line = self.line_at(location);
                let content = self.content(line.clone());
                if let Some(marker) = self.find(&QUOTE_MARKER, content.clone()) {
                    let m = marker.get(0).unwrap();
                    if !m.is_empty() {
                        let r = content.start + m.start()..content.start + m.end();
                        self.span(r.clone(), Delta::color(marker_color));
                        self.conceal(r, line.clone(), false, None);
                    }
                }
                if line.end <= location {
                    break;
                }
                location = line.end;
            }
        }
        ctx.quote_depth += 1;
        if self.live {
            let content = self.content(block.clone());
            self.decorations.push(Decoration {
                kind: if alert.is_some() { DecorationKind::Alert } else { DecorationKind::Quote },
                start: content.start,
                end: content.end,
                indent: ctx.indent,
                pad_top: 0.0,
                pad_bottom: 0.0,
                color: alert.map_or(Color::Tertiary, Self::alert_color),
                label: None,
                code: None,
            });
            ctx.indent += if alert.is_some() { 20.0 } else { 18.0 };
            self.span(block.clone(), Delta::para(self.paragraph(ctx.indent, None)));
            let first = self.line_at(block.start);
            let last = self.line_at(block.end.saturating_sub(1).max(block.start));
            let mut top = self.paragraph(ctx.indent, None);
            top.before = self.size * 0.5;
            let mut bottom = self.paragraph(ctx.indent, None);
            bottom.after = self.size * 0.5;
            if first == last {
                top.after = self.size * 0.5;
            }
            self.span(first.clone(), Delta::para(top));
            if first != last {
                self.span(last, Delta::para(bottom));
            }
        }
        if alert.is_none() {
            self.span(block.clone(), Delta::color(Color::Secondary));
        }
        if let Some(alert) = alert {
            let first = self.content(self.line_at(block.start));
            let mut font = ctx.font.clone();
            font.weight = 700;
            let mut delta = Delta::font(&font);
            delta.color = Some(Self::alert_color(alert));
            self.span(first, delta);
        }
    }

    fn style_list_item(&mut self, range: Range<usize>, ctx: &Ctx) {
        let line = self.line_at(range.start);
        let content = self.content(line.clone());
        let Some(marker) = self.find(&LIST_MARKER, content.clone()) else { return };
        let whole = marker.get(0).unwrap();
        let whole = content.start + whole.start()..content.start + whole.end();
        let symbol = marker.get(2).unwrap();
        let symbol = content.start + symbol.start()..content.start + symbol.end();
        let task = marker.get(4).map(|m| content.start + m.start()..content.start + m.end());
        self.span(symbol.clone(), Delta::color(if self.live { Color::Secondary } else { Color::Accent }));
        let symbol_text = &self.text[symbol.clone()];
        let is_bullet = symbol_text.len() == 1 && "-+*".contains(symbol_text);
        let mut bullet = false;
        if self.live && is_bullet {
            if let Some(task) = &task {
                self.conceal(symbol.start..task.start, line.clone(), false, None);
            } else {
                self.bullets.push(symbol.clone());
                bullet = true;
            }
        }
        if let Some(task) = &task {
            let task_start = task.start;
            let box_range = task_start..task_start + 3;
            let checked = self.text[box_range.clone()].eq_ignore_ascii_case("[x]");
            self.span(box_range.clone(), Delta::color(self.marker_color()));
            self.tasks.push(Task { range: box_range, checked, scope: line.clone() });
            if checked && whole.end < content.end {
                self.span(whole.end..content.end, Delta::color(Color::Secondary));
            }
        }
        if self.live {
            let mut visible = self.text[whole.clone()].to_string();
            if let Some(task) = &task {
                if !bullet && is_bullet {
                    let from = symbol.start - whole.start;
                    let to = task.start - whole.start;
                    visible.replace_range(from..to, "");
                }
            }
            let mut width = (self.measure)(&visible, &ctx.font);
            if bullet {
                width += 1.0;
            }
            self.span(line, Delta::para(self.paragraph(ctx.indent, Some(ctx.indent + width))));
        }
    }

    fn style_code(&mut self, range: Range<usize>, info: Option<&str>, ctx: &Ctx) {
        let block = self.lines(range);
        let first = self.line_at(block.start);
        let fenced = self.find(&FENCE, self.content(first.clone())).is_some();
        let mut inner = block.clone();
        let mut closing = None;
        if fenced {
            inner = first.end..block.end.max(first.end);
            let last = self.line_at(block.end.saturating_sub(1).max(block.start));
            if last.start > first.start && self.find(&FENCE_ONLY, self.content(last.clone())).is_some() {
                inner.end = last.start.max(inner.start);
                closing = Some(last);
            }
        }
        let mut delta = Delta::font(&self.code_font());
        delta.color = Some(if self.live { Color::CodeText } else { Color::Text });
        self.span(block.clone(), delta);
        let language = info.and_then(|i| i.split(' ').next());
        let code_text = &self.text[inner.clone()];
        for (token, color) in highlight::tokens(code_text, language) {
            self.span(inner.start + token.start..inner.start + token.end, Delta::color(color));
        }
        let fences: Vec<Range<usize>> = [fenced.then(|| first.clone()), closing].into_iter().flatten().collect();
        for fence in &fences {
            let content = self.content(fence.clone());
            self.span(content.clone(), Delta::color(Color::Tertiary));
            if self.live {
                self.conceal(content, block.clone(), true, None);
            }
        }
        if !self.live {
            return;
        }
        let mut copy = self.text[inner.clone()].to_string();
        if copy.ends_with('\n') {
            copy.pop();
        }
        let content = self.content(block.clone());
        self.decorations.push(Decoration {
            kind: DecorationKind::Code,
            start: content.start,
            end: content.end,
            indent: ctx.indent,
            pad_top: 32.0,
            pad_bottom: 14.0,
            color: Color::Tertiary,
            label: info.and_then(|i| i.split(' ').next()).map(str::to_lowercase),
            code: Some(copy),
        });
        let mut location = block.start;
        while location < block.end {
            let line = self.line_at(location);
            let mut para = self.paragraph(ctx.indent + 18.0, None);
            para.tail = 18.0;
            para.line_spacing = self.size * 0.2;
            para.after = 0.0;
            if line.start == block.start {
                para.before = 32.0 + 8.0;
            }
            if line.end >= block.end {
                para.after = 14.0 + 10.0;
            }
            self.span(line.clone(), Delta::para(para));
            if line.end <= location {
                break;
            }
            location = line.end;
        }
    }

    fn style_table(&mut self, range: Range<usize>, ctx: &mut Ctx) {
        let block = self.lines(range);
        let mono = Font { family: Family::Mono, size: self.size * 0.82, weight: 400, italic: false };
        ctx.font = mono.clone();
        self.span(block.clone(), Delta::font(&mono));
        let first = self.line_at(block.start);
        let mut header = mono;
        header.weight = 600;
        self.span(first, Delta::font(&header));
        let text = &self.text[block.clone()];
        let found: Vec<Range<usize>> = TABLE_PIPES.find_iter(text).map(|m| block.start + m.start()..block.start + m.end()).collect();
        for r in found {
            self.span(r, Delta::color(Color::Tertiary));
        }
    }
}

/// A rough text measure for tests.
#[cfg(test)]
pub fn approximate_measure(text: &str, font: &Font) -> f32 {
    let factor = if font.family == Family::Mono { 0.6 } else { 0.55 };
    text.chars().count() as f32 * font.size * factor
}

#[cfg(test)]
pub fn analyze(text: &str, size: f32, live: bool) -> Analysis {
    Styler::new(text, size, live, &approximate_measure).analyze()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn concealed(text: &str, analysis: &Analysis) -> Vec<String> {
        let chars: Vec<char> = text.chars().collect();
        analysis.conceals.iter().filter(|c| !c.collapse).map(|c| chars[c.range.clone()].iter().collect()).collect()
    }

    #[test]
    fn live_styler_conceals_markers_outside_active_line() {
        let text = "# Title\n\nSome **bold** and `code`.\n";
        let analysis = analyze(text, 17.0, true);
        let hidden = concealed(text, &analysis);
        assert!(hidden.contains(&"# ".to_string()));
        assert_eq!(hidden.iter().filter(|s| *s == "**").count(), 2);
        assert_eq!(hidden.iter().filter(|s| *s == "`").count(), 2);
        let heading = analysis.conceals.iter().find(|c| c.range.start == 0).unwrap();
        assert!(!overlaps(&heading.scope, &(20..20)));
        assert!(overlaps(&heading.scope, &(2..2)));
    }

    #[test]
    fn continuation_lines_keep_markers_aligned() {
        let text = "First line\n  continues **bold** [link](https://a.b)\n";
        let analysis = analyze(text, 17.0, true);
        let hidden = concealed(text, &analysis);
        assert_eq!(hidden.iter().filter(|s| *s == "**").count(), 2);
        assert!(hidden.contains(&"[".to_string()));
        assert!(hidden.contains(&"](https://a.b)".to_string()));
    }

    #[test]
    fn code_mode_keeps_everything_visible() {
        let analysis = analyze("# Title\n\n**bold**\n", 17.0, false);
        assert!(analysis.conceals.is_empty());
    }

    #[test]
    fn fenced_code_fences_collapse_and_copy_content() {
        let text = "```js\nlet a = 1\n```\n";
        let analysis = analyze(text, 17.0, true);
        let chars: Vec<char> = text.chars().collect();
        let fences: Vec<String> =
            analysis.conceals.iter().filter(|c| c.collapse).map(|c| chars[c.range.clone()].iter().collect()).collect();
        assert_eq!(fences, ["```js", "```"]);
        assert_eq!(analysis.decorations[0].code.as_deref(), Some("let a = 1"));
    }

    #[test]
    fn multibyte_edges_do_not_panic() {
        let samples = [
            "> café", "> [!NOTE]\n> café", "Título é\n===", "Título é\n---", "```\ncódigo é", "```rust\nlet é = 1;\n```",
            "**é**", "*é*", "~~é~~", "`é`", "| a | é |\n| - | - |\n| ñ | ü |", "- é", "1. é", "- [ ] é", "[é](ú)", "![é](ú.png)",
            "<b>é</b>", "<div>\né\n</div>", "---\ntítulo: é\n---\n# é", "é\n\n---", "# é #", "    código é", "日本語\n=====",
        ];
        for sample in samples {
            for live in [true, false] {
                let _ = analyze(sample, 17.0, live);
            }
            let _ = crate::markdown::render::render(sample, 17.0, None);
            let _ = crate::markdown::export::body(sample);
        }
    }

    #[test]
    fn tasks_and_bullets() {
        let text = "- one\n- [x] done\n";
        let analysis = analyze(text, 17.0, true);
        assert_eq!(analysis.bullets.len(), 1);
        assert_eq!(analysis.tasks.len(), 1);
        assert!(analysis.tasks[0].checked);
    }
}

#[cfg(test)]
mod corpus {
    /// `cargo test --release corpus -- --ignored --nocapture` times the repository's own documents.
    #[test]
    #[ignore]
    fn large_documents_stay_fast() {
        let mut text = String::new();
        for _ in 0..25 {
            text.push_str(include_str!("../../../README.md"));
            text.push_str(include_str!("../../../CHANGELOG.md"));
        }
        let start = std::time::Instant::now();
        let rendered = crate::markdown::render::render(&text, 17.0, None);
        let render = start.elapsed();
        let start = std::time::Instant::now();
        let analysis = super::analyze(&text, 17.0, true);
        let style = start.elapsed();
        println!("{} KB: render {render:?} ({} runs), live styling {style:?} ({} spans)", text.len() / 1024, rendered.runs.len(), analysis.spans.len());
    }
}
