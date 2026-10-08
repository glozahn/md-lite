//! The editor: styles the Markdown source in place (live or code mode), hides markers away from
//! the caret, and implements the formatting commands, list continuation and indentation.

use crate::i18n::t;
use crate::markdown::style::{self, Analysis, Font, Styler};
use crate::markdown::{CharMap, Style};
use crate::ui::textview::{MdTextView, TaskBox};
use crate::ui::theme::{Palette, TagCache};
use gtk::prelude::*;
use gtk::{gdk, glib, pango};
use regex::Regex;
use std::cell::{Cell, RefCell};
use std::collections::BTreeMap;
use std::ops::Range;
use std::path::PathBuf;
use std::rc::Rc;
use std::sync::LazyLock;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FormatAction {
    Bold,
    Italic,
    Strikethrough,
    Code,
    Link,
    Heading1,
    Heading2,
    Heading3,
    Paragraph,
    BulletList,
    NumberedList,
    TaskList,
    Quote,
    CodeBlock,
    Table,
    Rule,
}

impl FormatAction {
    pub fn from_name(name: &str) -> Option<FormatAction> {
        Some(match name {
            "bold" => FormatAction::Bold,
            "italic" => FormatAction::Italic,
            "strikethrough" => FormatAction::Strikethrough,
            "code" => FormatAction::Code,
            "link" => FormatAction::Link,
            "heading1" => FormatAction::Heading1,
            "heading2" => FormatAction::Heading2,
            "heading3" => FormatAction::Heading3,
            "paragraph" => FormatAction::Paragraph,
            "bullet-list" => FormatAction::BulletList,
            "numbered-list" => FormatAction::NumberedList,
            "task-list" => FormatAction::TaskList,
            "quote" => FormatAction::Quote,
            "code-block" => FormatAction::CodeBlock,
            "table" => FormatAction::Table,
            "rule" => FormatAction::Rule,
            _ => return None,
        })
    }
}

pub struct Editor {
    pub view: MdTextView,
    pub tags: Rc<TagCache>,
    conceal: gtk::TextTag,
    collapse: gtk::TextTag,
    clear: gtk::TextTag,
    analysis: RefCell<Analysis>,
    live: Cell<bool>,
    size: Cell<f32>,
    active: Cell<(usize, usize)>,
    pending: RefCell<Option<glib::SourceId>>,
    pub base_dir: RefCell<Option<PathBuf>>,
    pub on_link: RefCell<Option<Rc<dyn Fn(String)>>>,
}

impl Editor {
    pub fn new() -> Rc<Editor> {
        let view = MdTextView::new();
        view.add_css_class("md-editor");
        view.set_editable(true);
        view.set_accepts_tab(true);
        let buffer = view.buffer();
        let tags = Rc::new(TagCache::new(&buffer.tag_table()));
        // Hidden markers stay in the layout as tiny transparent glyphs: GTK's invisible text
        // breaks hit testing, and the caret never walks through them because entering a line
        // reveals its markers.
        // Pango treats a zero foreground alpha as unset, so "transparent" is nearly so.
        let conceal = gtk::TextTag::new(Some("md-conceal"));
        conceal.set_size_points(0.05);
        conceal.set_foreground_rgba(Some(&gdk::RGBA::new(0.0, 0.0, 0.0, 0.004)));
        let collapse = gtk::TextTag::new(Some("md-collapse"));
        collapse.set_size_points(1.0);
        collapse.set_foreground_rgba(Some(&gdk::RGBA::new(0.0, 0.0, 0.0, 0.004)));
        collapse.set_pixels_inside_wrap(0);
        let clear = gtk::TextTag::new(Some("md-clear"));
        clear.set_foreground_rgba(Some(&gdk::RGBA::new(0.0, 0.0, 0.0, 0.004)));
        tags.add_overlay(&clear);
        tags.add_overlay(&collapse);
        tags.add_overlay(&conceal);
        let editor = Rc::new(Editor {
            view,
            tags,
            conceal,
            collapse,
            clear,
            analysis: RefCell::new(Analysis::default()),
            live: Cell::new(true),
            size: Cell::new(17.0),
            active: Cell::new((usize::MAX, usize::MAX)),
            pending: RefCell::new(None),
            base_dir: RefCell::new(None),
            on_link: RefCell::new(None),
        });
        editor.connect();
        editor
    }

    fn connect(self: &Rc<Self>) {
        let buffer = self.view.buffer();
        // New text takes the look of the text before it until the next restyle.
        let weak = Rc::downgrade(self);
        buffer.connect_closure(
            "insert-text",
            true,
            glib::closure_local!(move |buffer: gtk::TextBuffer, iter: gtk::TextIter, text: String, _len: i32| {
                let Some(editor) = weak.upgrade() else { return };
                let count = text.chars().count() as i32;
                let end = iter;
                let mut start = iter;
                start.backward_chars(count);
                let mut before = start;
                if before.backward_char() {
                    for tag in before.tags() {
                        if tag != editor.conceal && tag != editor.collapse && tag != editor.clear {
                            buffer.apply_tag(&tag, &start, &end);
                        }
                    }
                }
            }),
        );
        buffer.connect_changed(glib::clone!(
            #[weak(rename_to = editor)]
            self,
            move |buffer| {
                let delay = if buffer.char_count() > 60_000 { 150 } else { 0 };
                editor.schedule_restyle(delay);
            }
        ));
        buffer.connect_mark_set(glib::clone!(
            #[weak(rename_to = editor)]
            self,
            move |_, _, mark| {
                if mark.name().as_deref() == Some("insert") || mark.name().as_deref() == Some("selection_bound") {
                    editor.update_active();
                }
            }
        ));
        let keys = gtk::EventControllerKey::new();
        keys.set_propagation_phase(gtk::PropagationPhase::Capture);
        keys.connect_key_pressed(glib::clone!(
            #[weak(rename_to = editor)]
            self,
            #[upgrade_or]
            glib::Propagation::Proceed,
            move |_, key, _, modifiers| {
                let plain = !modifiers.intersects(gdk::ModifierType::CONTROL_MASK | gdk::ModifierType::ALT_MASK | gdk::ModifierType::SUPER_MASK);
                if !plain {
                    return glib::Propagation::Proceed;
                }
                let shift = modifiers.contains(gdk::ModifierType::SHIFT_MASK);
                let handled = match key {
                    gdk::Key::Return | gdk::Key::KP_Enter if !shift => editor.continue_block_on_newline(),
                    gdk::Key::Tab => editor.shift_list_items(false),
                    gdk::Key::ISO_Left_Tab => editor.shift_list_items(true),
                    _ => false,
                };
                if handled { glib::Propagation::Stop } else { glib::Propagation::Proceed }
            }
        ));
        self.view.add_controller(keys);
        // Ctrl-click opens links in the editor.
        let click = gtk::GestureClick::new();
        click.connect_pressed(glib::clone!(
            #[weak(rename_to = editor)]
            self,
            move |gesture, _, x, y| {
                let modifiers = gesture.current_event_state();
                if !modifiers.contains(gdk::ModifierType::CONTROL_MASK) {
                    return;
                }
                let Some(offset) = editor.view.offset_at(x, y) else { return };
                let url = editor.analysis.borrow().links.iter().find(|(r, _)| r.start <= offset && offset < r.end).map(|(_, u)| u.clone());
                if let (Some(url), Some(open)) = (url, editor.on_link.borrow().clone()) {
                    gesture.set_state(gtk::EventSequenceState::Claimed);
                    open(url);
                }
            }
        ));
        self.view.add_controller(click);
        let motion = gtk::EventControllerMotion::new();
        motion.connect_motion(glib::clone!(
            #[weak(rename_to = editor)]
            self,
            move |controller, x, y| {
                let ctrl = controller.current_event_state().contains(gdk::ModifierType::CONTROL_MASK);
                let over = ctrl
                    && editor
                        .view
                        .offset_at(x, y)
                        .is_some_and(|o| editor.analysis.borrow().links.iter().any(|(r, _)| r.start <= o && o < r.end));
                editor.view.set_cursor_from_name(Some(if over { "pointer" } else { "text" }));
            }
        ));
        self.view.add_controller(motion);
    }

    pub fn set_palette(&self, palette: &Palette) {
        self.tags.set_palette(palette);
        self.view.set_palette(palette);
    }

    pub fn configure(&self, live: bool, size: f32) {
        let changed = self.live.get() != live || self.size.get() != size;
        self.live.set(live);
        self.size.set(size);
        if changed {
            self.restyle();
        }
    }

    pub fn is_live(&self) -> bool {
        self.live.get()
    }

    pub fn schedule_restyle(self: &Rc<Self>, delay: u64) {
        if let Some(id) = self.pending.borrow_mut().take() {
            id.remove();
        }
        let weak = Rc::downgrade(self);
        let id = glib::timeout_add_local_full(std::time::Duration::from_millis(delay), glib::Priority::HIGH_IDLE, move || {
            if let Some(editor) = weak.upgrade() {
                editor.pending.borrow_mut().take();
                editor.restyle();
            }
            glib::ControlFlow::Break
        });
        *self.pending.borrow_mut() = Some(id);
    }

    fn measure(&self) -> impl Fn(&str, &Font) -> f32 + '_ {
        move |text: &str, font: &Font| {
            let palette = self.tags.palette();
            let layout = self.view.create_pango_layout(Some(text));
            let mut description = pango::FontDescription::new();
            description.set_family(palette.family(font.family));
            description.set_size((font.size * 0.75 * pango::SCALE as f32) as i32);
            description.set_weight(pango::Weight::__Unknown(i32::from(font.weight)));
            layout.set_font_description(Some(&description));
            layout.pixel_size().0 as f32
        }
    }

    /// Re-analyzes the whole buffer and applies styles, decorations and concealment.
    pub fn restyle(&self) {
        let buffer = self.view.buffer();
        let (start, end) = buffer.bounds();
        let text = buffer.text(&start, &end, true).to_string();
        let measure = self.measure();
        let base_dir = self.base_dir.borrow().clone();
        let styler = Styler::new(&text, self.size.get(), self.live.get(), &measure).with_base(base_dir.as_deref());
        let base = styler.base_style();
        let analysis = styler.analyze();
        let count = text.chars().count();
        buffer.remove_all_tags(&start, &end);
        for (range, style) in flatten(&analysis, &base, count) {
            let tag = self.tags.tag(&style);
            buffer.apply_tag(&tag, &buffer.iter_at_offset(range.start as i32), &buffer.iter_at_offset(range.end as i32));
        }
        *self.analysis.borrow_mut() = analysis;
        self.active.set(self.active_lines());
        self.apply_concealment();
    }

    /// Character range of the lines holding the selection.
    fn active_lines(&self) -> (usize, usize) {
        let buffer = self.view.buffer();
        let (mut a, mut b) = buffer.selection_bounds().unwrap_or_else(|| {
            let i = buffer.iter_at_mark(&buffer.get_insert());
            (i, i)
        });
        a.set_line_offset(0);
        if !b.ends_line() {
            b.forward_to_line_end();
        }
        b.forward_char();
        (a.offset() as usize, b.offset() as usize)
    }

    fn update_active(&self) {
        if !self.live.get() {
            return;
        }
        let active = self.active_lines();
        if active != self.active.get() {
            self.active.set(active);
            self.apply_concealment();
        }
    }

    fn apply_concealment(&self) {
        let buffer = self.view.buffer();
        let (start, end) = buffer.bounds();
        buffer.remove_tag(&self.conceal, &start, &end);
        buffer.remove_tag(&self.collapse, &start, &end);
        buffer.remove_tag(&self.clear, &start, &end);
        let analysis = self.analysis.borrow();
        let mut decorations = analysis.decorations.clone();
        let mut tasks = Vec::new();
        let mut bullets = Vec::new();
        if self.live.get() {
            let (a, b) = self.active.get();
            let active = a..b.max(a);
            let at = |o: usize| buffer.iter_at_offset(o as i32);
            for conceal in &analysis.conceals {
                if style::overlaps(&conceal.scope, &active) {
                    continue;
                }
                if let Some(decoration) = &conceal.decoration {
                    let mut d = decoration.clone();
                    d.start = conceal.range.start;
                    d.end = conceal.range.end;
                    decorations.push(d);
                }
                if conceal.collapse {
                    let mut line_start = at(conceal.range.start);
                    line_start.set_line_offset(0);
                    let mut line_end = at(conceal.range.end);
                    if !line_end.ends_line() {
                        line_end.forward_to_line_end();
                    }
                    line_end.forward_char();
                    buffer.apply_tag(&self.collapse, &line_start, &line_end);
                } else {
                    buffer.apply_tag(&self.conceal, &at(conceal.range.start), &at(conceal.range.end));
                }
            }
            for bullet in &analysis.bullets {
                buffer.apply_tag(&self.clear, &at(bullet.start), &at(bullet.end));
                bullets.push(bullet.start);
            }
            for task in &analysis.tasks {
                if style::overlaps(&task.scope, &active) {
                    continue;
                }
                buffer.apply_tag(&self.clear, &at(task.range.start), &at(task.range.end));
                tasks.push(TaskBox { start: task.range.start, end: task.range.end, checked: task.checked, source: task.range.start });
            }
        }
        decorations.sort_by_key(|d| (d.start, std::cmp::Reverse(d.end)));
        self.view.set_decorations(decorations);
        self.view.set_bullets(bullets);
        self.view.set_tasks(tasks);
        self.view.queue_draw();
    }

    // MARK: Editing helpers

    fn text(&self) -> String {
        let buffer = self.view.buffer();
        let (s, e) = buffer.bounds();
        buffer.text(&s, &e, true).to_string()
    }

    /// Selection as byte offsets into `text`.
    fn selection(&self, map: &CharMap) -> Range<usize> {
        let buffer = self.view.buffer();
        let (a, b) = buffer.selection_bounds().unwrap_or_else(|| {
            let i = buffer.iter_at_mark(&buffer.get_insert());
            (i, i)
        });
        map.byte(a.offset() as usize)..map.byte(b.offset() as usize)
    }

    /// Replaces a byte range of `text` as one undoable step and selects a byte range of the result.
    fn replace(&self, text: &str, range: Range<usize>, with: &str, select: Option<Range<usize>>) {
        let buffer = self.view.buffer();
        let map = CharMap::new(text);
        let mut result = String::with_capacity(text.len() + with.len());
        result.push_str(&text[..range.start]);
        result.push_str(with);
        result.push_str(&text[range.end..]);
        let new_map = CharMap::new(&result);
        buffer.begin_user_action();
        let mut a = buffer.iter_at_offset(map.char(range.start) as i32);
        let mut b = buffer.iter_at_offset(map.char(range.end) as i32);
        buffer.delete(&mut a, &mut b);
        buffer.insert(&mut a, with);
        buffer.end_user_action();
        if let Some(select) = select {
            let s = buffer.iter_at_offset(new_map.char(select.start.min(result.len())) as i32);
            let e = buffer.iter_at_offset(new_map.char(select.end.min(result.len())) as i32);
            buffer.select_range(&s, &e);
        }
        self.view.scroll_mark_onscreen(&buffer.get_insert());
    }

    pub fn perform(&self, action: FormatAction) {
        match action {
            FormatAction::Bold => self.toggle_wrap("**", &t("texto")),
            FormatAction::Italic => self.toggle_wrap("*", &t("texto")),
            FormatAction::Strikethrough => self.toggle_wrap("~~", &t("texto")),
            FormatAction::Code => self.toggle_wrap("`", &t("código")),
            FormatAction::Link => self.insert_link(),
            FormatAction::Heading1 => self.set_heading(1),
            FormatAction::Heading2 => self.set_heading(2),
            FormatAction::Heading3 => self.set_heading(3),
            FormatAction::Paragraph => self.set_heading(0),
            FormatAction::BulletList => self.toggle_list(&|_| "- ".to_string()),
            FormatAction::NumberedList => self.toggle_list(&|i| format!("{}. ", i + 1)),
            FormatAction::TaskList => self.toggle_list(&|_| "- [ ] ".to_string()),
            FormatAction::Quote => self.toggle_quote(),
            FormatAction::CodeBlock => self.insert_code_block(),
            FormatAction::Table => {
                let column = t("Columna");
                self.insert_block(&format!("| {column} 1 | {column} 2 |\n| --- | --- |\n|  |  |\n"), 2)
            }
            FormatAction::Rule => self.insert_block("---\n", 4),
        }
        self.view.grab_focus();
    }

    fn toggle_wrap(&self, marker: &str, placeholder: &str) {
        let text = self.text();
        let map = CharMap::new(&text);
        let selection = self.selection(&map);
        let length = marker.len();
        if selection.start >= length
            && selection.end + length <= text.len()
            && text.get(selection.start - length..selection.start) == Some(marker)
            && text.get(selection.end..selection.end + length) == Some(marker)
        {
            let outer = selection.start - length..selection.end + length;
            let inner = text[selection.clone()].to_string();
            let start = outer.start;
            self.replace(&text, outer, &inner, Some(start..start + inner.len()));
            return;
        }
        let selected = text[selection.clone()].to_string();
        if selected.len() >= length * 2 && selected.starts_with(marker) && selected.ends_with(marker) {
            let inner = selected[length..selected.len() - length].to_string();
            let start = selection.start;
            self.replace(&text, selection, &inner, Some(start..start + inner.len()));
            return;
        }
        let start = selection.start;
        if selected.is_empty() {
            self.replace(&text, selection, &format!("{marker}{placeholder}{marker}"), Some(start + length..start + length + placeholder.len()));
        } else {
            let len = selected.len();
            self.replace(&text, selection, &format!("{marker}{selected}{marker}"), Some(start + length..start + length + len));
        }
    }

    fn insert_link(&self) {
        let text = self.text();
        let map = CharMap::new(&text);
        let selection = self.selection(&map);
        let selected = text[selection.clone()].to_string();
        let start = selection.start;
        if selected.starts_with("http://") || selected.starts_with("https://") {
            let label = t("enlace");
            self.replace(&text, selection, &format!("[{label}]({selected})"), Some(start + 1..start + 1 + label.len()));
        } else {
            let label = if selected.is_empty() { t("enlace") } else { selected };
            let at = start + label.len() + 3;
            self.replace(&text, selection, &format!("[{label}](https://)"), Some(at..at + 8));
        }
    }

    /// Byte range of the full lines holding the selection.
    fn selected_lines(text: &str, selection: &Range<usize>) -> Range<usize> {
        let start = text[..selection.start].rfind('\n').map_or(0, |i| i + 1);
        let end = if selection.end > selection.start && text.as_bytes()[selection.end - 1] == b'\n' {
            selection.end
        } else {
            text[selection.end..].find('\n').map_or(text.len(), |i| selection.end + i + 1)
        };
        start..end
    }

    fn transform_lines(&self, transform: &dyn Fn(Vec<String>) -> Vec<String>) {
        let text = self.text();
        let map = CharMap::new(&text);
        let selection = self.selection(&map);
        let range = Self::selected_lines(&text, &selection);
        let mut block = text[range.clone()].to_string();
        let newline = block.ends_with('\n');
        if newline {
            block.pop();
        }
        let lines: Vec<String> = block.split('\n').map(str::to_string).collect();
        let count = lines.len();
        let replacement = transform(lines).join("\n") + if newline { "\n" } else { "" };
        let new_length = replacement.len() - usize::from(newline);
        let old_length = range.len() - usize::from(newline);
        if count == 1 && selection.is_empty() {
            let delta = new_length as isize - old_length as isize;
            let caret = (selection.start as isize + delta).clamp(range.start as isize, (range.start + new_length) as isize) as usize;
            let start = range.start;
            self.replace(&text, range, &replacement, Some(caret.max(start)..caret.max(start)));
        } else {
            let start = range.start;
            self.replace(&text, range, &replacement, Some(start..start + new_length));
        }
    }

    fn set_heading(&self, level: usize) {
        static MARKER: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^[ \t]{0,3}(#{1,6})[ \t]+").unwrap());
        self.transform_lines(&|lines| {
            lines
                .into_iter()
                .map(|line| {
                    let current = MARKER.captures(&line).map_or(0, |c| c[1].len());
                    let stripped = MARKER.replace(&line, "").to_string();
                    if level == 0 || current == level {
                        stripped
                    } else {
                        format!("{} {}", "#".repeat(level), stripped)
                    }
                })
                .collect()
        });
    }

    fn toggle_list(&self, marker: &dyn Fn(usize) -> String) {
        let sample = marker(0);
        let numbered_sample = sample.chars().next().is_some_and(|c| c.is_ascii_digit());
        let task_sample = sample.contains('[');
        self.transform_lines(&|lines| {
            let content: Vec<&String> = lines.iter().filter(|l| !l.trim().is_empty()).collect();
            let all = !content.is_empty()
                && content.iter().all(|line| match LIST.captures(line) {
                    Some(c) => c.get(3).is_some() == numbered_sample && c.get(6).is_some() == task_sample,
                    None => false,
                });
            let mut index = 0;
            lines
                .iter()
                .map(|line| {
                    if line.trim().is_empty() {
                        return line.clone();
                    }
                    let (indent, body) = match LIST.captures(line) {
                        Some(c) => (c[1].to_string(), line[c.get(0).unwrap().end()..].to_string()),
                        None => (String::new(), line.clone()),
                    };
                    if all {
                        return indent + &body;
                    }
                    let result = indent + &marker(index) + &body;
                    index += 1;
                    result
                })
                .collect()
        });
    }

    fn toggle_quote(&self) {
        self.transform_lines(&|lines| {
            let all = lines.iter().all(|l| l.trim().is_empty() || l.starts_with('>'));
            lines
                .into_iter()
                .map(|line| {
                    if all {
                        line.strip_prefix("> ").or_else(|| line.strip_prefix('>')).unwrap_or(&line).to_string()
                    } else {
                        format!("> {line}")
                    }
                })
                .collect()
        });
    }

    fn insert_code_block(&self) {
        let text = self.text();
        let map = CharMap::new(&text);
        let selection = self.selection(&map);
        if !selection.is_empty() {
            let range = Self::selected_lines(&text, &selection);
            let mut block = text[range.clone()].to_string();
            if !block.ends_with('\n') {
                block.push('\n');
            }
            let at = range.start + 3;
            self.replace(&text, range, &format!("```\n{block}```\n"), Some(at..at));
        } else {
            self.insert_block("```\n\n```\n", 3);
        }
    }

    /// Inserts a block on its own line and places the caret `caret` bytes into it.
    fn insert_block(&self, block: &str, caret: usize) {
        let text = self.text();
        let map = CharMap::new(&text);
        let selection = self.selection(&map);
        let line = Self::selected_lines(&text, &(selection.start..selection.start));
        let line_text = &text[line.clone()];
        if line_text.trim().is_empty() {
            let target = line.start..line.end - usize::from(line_text.ends_with('\n'));
            let insertion = if block.ends_with('\n') && line.end < text.len() { &block[..block.len() - 1] } else { block };
            let at = line.start + caret;
            self.replace(&text, target, insertion, Some(at..at));
        } else {
            let end = line.end;
            let needs_newline = end == text.len() && !line_text.ends_with('\n');
            let insertion = format!("{}\n{block}", if needs_newline { "\n" } else { "" });
            let at = end + insertion.len() - block.len() + caret;
            self.replace(&text, end..end, &insertion, Some(at..at));
        }
    }

    /// Continues lists and quotes on Return. Returns false when the default newline should run.
    fn continue_block_on_newline(&self) -> bool {
        let text = self.text();
        let map = CharMap::new(&text);
        let selection = self.selection(&map);
        if !selection.is_empty() {
            return false;
        }
        let line = Self::selected_lines(&text, &(selection.start..selection.start));
        let content = text[line.clone()].trim_end_matches('\n').to_string();
        let caret = selection.start - line.start;
        if let Some(c) = LIST.captures(&content) {
            let whole = c.get(0).unwrap().end();
            if caret < whole {
                return false;
            }
            if content[whole..].trim().is_empty() {
                let start = line.start;
                self.replace(&text, line.start..line.start + content.len(), "", Some(start..start));
                return true;
            }
            let indent = &c[1];
            let mut marker = match (c.get(2), c.get(3)) {
                (Some(bullet), _) => bullet.as_str().to_string(),
                (None, Some(number)) => format!("{}{}", number.as_str().parse::<u64>().unwrap_or(1) + 1, &c[4]),
                _ => String::new(),
            };
            marker.push_str(&c[5]);
            if c.get(6).is_some() {
                marker.push_str("[ ] ");
            }
            let insertion = format!("\n{indent}{marker}");
            let at = selection.start + insertion.len();
            self.replace(&text, selection, &insertion, Some(at..at));
            return true;
        }
        if let Some(c) = QUOTE.captures(&content) {
            let whole = c.get(0).unwrap().end();
            if caret >= whole {
                if content[whole..].trim().is_empty() {
                    let start = line.start;
                    self.replace(&text, line.start..line.start + content.len(), "", Some(start..start));
                    return true;
                }
                let mut prefix = c[0].to_string();
                if !prefix.ends_with(' ') {
                    prefix.push(' ');
                }
                let insertion = format!("\n{prefix}");
                let at = selection.start + insertion.len();
                self.replace(&text, selection, &insertion, Some(at..at));
                return true;
            }
        }
        false
    }

    /// Indents or outdents list items with Tab / Shift-Tab. Returns false outside lists.
    fn shift_list_items(&self, outdent: bool) -> bool {
        let text = self.text();
        let map = CharMap::new(&text);
        let selection = self.selection(&map);
        let range = Self::selected_lines(&text, &selection);
        let block = text[range.clone()].to_string();
        let lines: Vec<&str> = block.split('\n').collect();
        let Some(first) = lines.first() else { return false };
        let Some(c) = LIST.captures(first) else { return false };
        let marker_len = c.get(0).unwrap().end() - c[1].len() - c.get(6).map_or(0, |m| m.len());
        let width = marker_len.max(2);
        let pad = " ".repeat(width);
        let count = lines.len();
        let shifted: Vec<String> = lines
            .iter()
            .enumerate()
            .map(|(index, line)| {
                if line.is_empty() && index == count - 1 {
                    return line.to_string();
                }
                if outdent {
                    let mut result = *line;
                    let mut removed = 0;
                    while removed < width && result.starts_with(' ') {
                        result = &result[1..];
                        removed += 1;
                    }
                    if removed == 0 && result.starts_with('\t') {
                        result = &result[1..];
                    }
                    result.to_string()
                } else {
                    format!("{pad}{line}")
                }
            })
            .collect();
        let shifted = shifted.join("\n");
        let delta = shifted.len() as isize - range.len() as isize;
        let start = range.start;
        let select = if count <= 2 && selection.is_empty() {
            let moved = if outdent { delta.max(-(width as isize)) } else { width as isize };
            let caret = (selection.start as isize + moved).max(start as isize) as usize;
            caret..caret
        } else {
            start..start + shifted.len()
        };
        self.replace(&text, range, &shifted, Some(select));
        true
    }

    #[cfg(debug_assertions)]
    pub fn debug_type(&self, text: &str) {
        let buffer = self.view.buffer();
        for c in text.chars() {
            match c {
                '\n' => {
                    if !self.continue_block_on_newline() {
                        buffer.insert_at_cursor("\n");
                    }
                }
                '\t' => {
                    if !self.shift_list_items(false) {
                        buffer.insert_at_cursor("\t");
                    }
                }
                _ => buffer.insert_at_cursor(&c.to_string()),
            }
        }
    }

    /// Toggles the task box whose `[` is at a character offset of the buffer.
    pub fn toggle_task_at_char(&self, offset: usize) {
        let buffer = self.view.buffer();
        let mut a = buffer.iter_at_offset(offset as i32 + 1);
        let mut b = buffer.iter_at_offset(offset as i32 + 2);
        let current = buffer.text(&a, &b, true).to_string();
        let next = if current.eq_ignore_ascii_case("x") { " " } else { "x" };
        if current != " " && !current.eq_ignore_ascii_case("x") {
            return;
        }
        buffer.begin_user_action();
        buffer.delete(&mut a, &mut b);
        buffer.insert(&mut a, next);
        buffer.end_user_action();
    }
}

static LIST: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^([ \t]*(?:>[ \t]?)*[ \t]*)(?:([-+*])|(\d{1,9})([.)]))([ \t]+)(\[[ xX]\][ \t]+)?").unwrap());
static QUOTE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^([ \t]*(?:>[ \t]?)+)").unwrap());

/// Resolves overlapping partial styles into one full style per run, later spans winning.
fn flatten(analysis: &Analysis, base: &Style, count: usize) -> Vec<(Range<usize>, Style)> {
    let mut points: Vec<usize> = vec![0, count];
    for (range, _) in &analysis.spans {
        points.push(range.start.min(count));
        points.push(range.end.min(count));
    }
    points.sort_unstable();
    points.dedup();
    let mut starts: Vec<(usize, usize)> = analysis.spans.iter().enumerate().map(|(i, (r, _))| (r.start, i)).collect();
    starts.sort_unstable();
    let mut ends: Vec<(usize, usize)> = analysis.spans.iter().enumerate().map(|(i, (r, _))| (r.end, i)).collect();
    ends.sort_unstable();
    let (mut si, mut ei) = (0, 0);
    let mut active: BTreeMap<usize, ()> = BTreeMap::new();
    let mut out: Vec<(Range<usize>, Style)> = Vec::new();
    for window in points.windows(2) {
        let (a, b) = (window[0], window[1]);
        while ei < ends.len() && ends[ei].0 <= a {
            active.remove(&ends[ei].1);
            ei += 1;
        }
        while si < starts.len() && starts[si].0 <= a {
            if analysis.spans[starts[si].1].0.end > a {
                active.insert(starts[si].1, ());
            }
            si += 1;
        }
        if a >= b {
            continue;
        }
        let mut style = base.clone();
        for index in active.keys() {
            analysis.spans[*index].1.apply(&mut style);
        }
        match out.last_mut() {
            Some((range, last)) if range.end == a && *last == style => range.end = b,
            _ => out.push((a..b, style)),
        }
    }
    out
}
