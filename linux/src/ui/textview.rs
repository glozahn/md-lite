//! Text view with a centered reading column that draws block ornaments (code boxes, quote bars,
//! rules), list bullets and task boxes behind the text. Used by both the reader and the editor.

use crate::i18n::t;
use crate::markdown::render::{Decoration, DecorationKind};
use crate::ui::theme::Palette;
use adw::prelude::*;
use gtk::subclass::prelude::*;
use gtk::{gdk, glib, graphene, pango};
use std::cell::{Cell, RefCell};
use std::rc::Rc;

/// A hit area for a code box's copy button, in buffer coordinates.
#[derive(Clone)]
pub struct CopyButton {
    rect: graphene::Rect,
    code: String,
}

#[derive(Clone)]
pub struct TaskBox {
    pub start: usize,
    pub end: usize,
    pub checked: bool,
    /// Offset in the source handed back when the box is clicked.
    pub source: usize,
}

mod imp {
    use super::*;

    #[derive(Default)]
    pub struct MdTextView {
        pub decorations: RefCell<Vec<Decoration>>,
        pub bullets: RefCell<Vec<usize>>,
        pub tasks: RefCell<Vec<TaskBox>>,
        pub palette: RefCell<Option<Palette>>,
        pub column: Cell<i32>,
        pub vertical_inset: Cell<i32>,
        pub copy_buttons: RefCell<Vec<CopyButton>>,
        pub task_hits: RefCell<Vec<(graphene::Rect, usize)>>,
        pub copied: RefCell<Option<(String, std::time::Instant)>>,
        /// Width available to embedded widgets; shared with them so they can size themselves.
        pub available: Rc<Cell<i32>>,
        pub on_task: RefCell<Option<Box<dyn Fn(usize)>>>,
        pub on_copy: RefCell<Option<Box<dyn Fn()>>>,
        pub last_width: Cell<i32>,
        pub embeds: RefCell<Vec<gtk::Widget>>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for MdTextView {
        const NAME: &'static str = "MdTextView";
        type Type = super::MdTextView;
        type ParentType = gtk::TextView;
    }

    impl ObjectImpl for MdTextView {
        fn constructed(&self) {
            self.parent_constructed();
            self.column.set(760);
            self.vertical_inset.set(30);
            self.available.set(600);
            let view = self.obj();
            view.set_wrap_mode(gtk::WrapMode::WordChar);
            view.set_top_margin(30);
            view.set_bottom_margin(60);
            view.add_css_class("md-text");
            let click = gtk::GestureClick::new();
            click.set_button(gdk::BUTTON_PRIMARY);
            click.set_propagation_phase(gtk::PropagationPhase::Capture);
            let weak = view.downgrade();
            click.connect_pressed(move |gesture, _, x, y| {
                let Some(view) = weak.upgrade() else { return };
                if view.handle_press(x, y) {
                    gesture.set_state(gtk::EventSequenceState::Claimed);
                }
            });
            view.add_controller(click);
        }
    }

    impl WidgetImpl for MdTextView {
        fn size_allocate(&self, width: i32, height: i32, baseline: i32) {
            let view = self.obj();
            if width != self.last_width.get() {
                self.last_width.set(width);
                view.update_margins(width);
            }
            self.parent_size_allocate(width, height, baseline);
        }
    }

    impl TextViewImpl for MdTextView {
        fn snapshot_layer(&self, layer: gtk::TextViewLayer, snapshot: gtk::Snapshot) {
            if layer == gtk::TextViewLayer::BelowText {
                self.obj().draw_below(&snapshot);
            } else {
                self.obj().draw_above(&snapshot);
            }
        }
    }
}

glib::wrapper! {
    pub struct MdTextView(ObjectSubclass<imp::MdTextView>)
        @extends gtk::TextView, gtk::Widget,
        @implements gtk::Accessible, gtk::Buildable, gtk::ConstraintTarget, gtk::Scrollable;
}

impl Default for MdTextView {
    fn default() -> Self {
        Self::new()
    }
}

impl MdTextView {
    pub fn new() -> Self {
        glib::Object::new()
    }

    /// Embeds a widget at an anchor, remembering it so it can be removed before the text goes.
    pub fn add_embed(&self, widget: &gtk::Widget, anchor: &gtk::TextChildAnchor) {
        self.add_child_at_anchor(widget, anchor);
        self.imp().embeds.borrow_mut().push(widget.clone());
    }

    /// Removes every embedded widget while the buffer is still intact. Deleting text that holds
    /// a widget under the pointer makes GTK read the selection mid-deletion and crash.
    pub fn clear_embeds(&self) {
        for widget in self.imp().embeds.borrow_mut().drain(..) {
            if widget.parent().as_ref() == Some(self.upcast_ref::<gtk::Widget>()) {
                self.remove(&widget);
            }
        }
    }

    pub fn available(&self) -> Rc<Cell<i32>> {
        self.imp().available.clone()
    }

    pub fn set_palette(&self, palette: &Palette) {
        *self.imp().palette.borrow_mut() = Some(palette.clone());
        if palette.dark {
            self.add_css_class("md-dark");
        } else {
            self.remove_css_class("md-dark");
        }
        self.queue_draw();
    }


    pub fn set_decorations(&self, decorations: Vec<Decoration>) {
        *self.imp().decorations.borrow_mut() = decorations;
        self.queue_draw();
    }

    pub fn set_bullets(&self, bullets: Vec<usize>) {
        *self.imp().bullets.borrow_mut() = bullets;
    }

    pub fn set_tasks(&self, tasks: Vec<TaskBox>) {
        *self.imp().tasks.borrow_mut() = tasks;
    }

    pub fn connect_task(&self, f: impl Fn(usize) + 'static) {
        *self.imp().on_task.borrow_mut() = Some(Box::new(f));
    }

    pub fn connect_copy(&self, f: impl Fn() + 'static) {
        *self.imp().on_copy.borrow_mut() = Some(Box::new(f));
    }

    /// The text column is centered by the clamp around the view; embedded widgets follow its width.
    fn update_margins(&self, width: i32) {
        let imp = self.imp();
        let available = (width - 12).max(40);
        if imp.available.get() != available {
            imp.available.set(available);
            let weak = self.downgrade();
            glib::idle_add_local_once(move || {
                if let Some(view) = weak.upgrade() {
                    let mut child = view.first_child();
                    while let Some(widget) = child {
                        widget.queue_resize();
                        child = widget.next_sibling();
                    }
                }
            });
        }
    }

    fn palette(&self) -> Option<Palette> {
        self.imp().palette.borrow().clone()
    }

    /// Visible character range, with some slack above and below.
    fn visible_offsets(&self) -> (usize, usize) {
        let rect = self.visible_rect();
        let (top, _) = self.line_at_y((rect.y() - 400).max(0));
        let (bottom, _) = self.line_at_y(rect.y() + rect.height() + 400);
        (top.offset().max(0) as usize, bottom.line_end_offset_iter_offset().max(0) as usize)
    }

    /// Top and bottom of the text (without paragraph spacing) of a character range, in buffer coordinates.
    fn text_bounds(&self, start: usize, end: usize) -> Option<(f32, f32)> {
        let buffer = self.buffer();
        let count = buffer.char_count() as usize;
        if start >= count || end <= start {
            return None;
        }
        let first = buffer.iter_at_offset(start as i32);
        let mut last = buffer.iter_at_offset((end.min(count) - 1) as i32);
        // A trailing newline belongs to the line before it.
        if last.char() == '\n' && last.offset() > first.offset() {
            last.backward_char();
        }
        let mut line_start = first;
        line_start.set_line_offset(0);
        let above = line_start.tags().iter().map(|t| t.pixels_above_lines()).max().unwrap_or(0);
        let (top_y, _) = self.line_yrange(&first);
        let mut last_start = last;
        last_start.set_line_offset(0);
        let below = last_start.tags().iter().map(|t| t.pixels_below_lines()).max().unwrap_or(0);
        let (line_y, line_height) = self.line_yrange(&last);
        Some(((top_y + above) as f32, (line_y + line_height - below) as f32))
    }

    fn column_bounds(&self, indent: f32) -> (f32, f32) {
        let left = self.left_margin() as f32 + indent;
        let width = (self.width() - self.left_margin() - self.right_margin()) as f32 - indent;
        (left, width.max(10.0))
    }

    fn draw_below(&self, snapshot: &gtk::Snapshot) {
        let Some(palette) = self.palette() else { return };
        let (visible_start, visible_end) = self.visible_offsets();
        let decorations = self.imp().decorations.borrow();
        let mut buttons = Vec::new();
        let visible = self.visible_rect();
        let area = graphene::Rect::new(0.0, visible.y() as f32 - 50.0, self.width() as f32 + 100.0, visible.height() as f32 + 100.0);
        let cr = snapshot.append_cairo(&area);
        for decoration in decorations.iter() {
            if decoration.end < visible_start || decoration.start > visible_end {
                continue;
            }
            let Some((top, bottom)) = self.text_bounds(decoration.start, decoration.end) else { continue };
            let (left, width) = self.column_bounds(decoration.indent);
            match decoration.kind {
                DecorationKind::Code | DecorationKind::Diagram => {
                    let rect = (left, top - decoration.pad_top, width, bottom - top + decoration.pad_top + decoration.pad_bottom);
                    rounded(&cr, rect, 10.0);
                    set(&cr, &palette.code_background());
                    let _ = cr.fill_preserve();
                    set(&cr, &palette.code_border());
                    cr.set_line_width(1.0);
                    let _ = cr.stroke();
                    if decoration.kind == DecorationKind::Code && decoration.pad_top >= 24.0 {
                        if let Some(button) = self.draw_code_header(&cr, decoration, rect, &palette) {
                            buttons.push(button);
                        }
                    }
                }
                DecorationKind::Quote | DecorationKind::Alert => {
                    let rect = (left, top - 4.0, width, bottom - top + 8.0);
                    let color = palette.color(decoration.color);
                    if decoration.kind == DecorationKind::Alert {
                        rounded(&cr, rect, 6.0);
                        set(&cr, &gdk::RGBA::new(color.red(), color.green(), color.blue(), 0.07));
                        let _ = cr.fill();
                    }
                    rounded(&cr, (rect.0, rect.1, 3.0, rect.3), 1.5);
                    set(&cr, &color);
                    let _ = cr.fill();
                }
                DecorationKind::Rule => {
                    set(&cr, &palette.separator());
                    cr.rectangle(left as f64, ((top + bottom) / 2.0).round() as f64, width as f64, 1.0);
                    let _ = cr.fill();
                }
                DecorationKind::HeadingRule => {
                    let mut c = palette.separator();
                    c.set_alpha(c.alpha() * 0.7);
                    set(&cr, &c);
                    cr.rectangle(left as f64, (bottom + 6.0).round() as f64, width as f64, 1.0);
                    let _ = cr.fill();
                }
            }
        }
        *self.imp().copy_buttons.borrow_mut() = buttons;
    }

    fn draw_code_header(&self, cr: &gtk::cairo::Context, decoration: &Decoration, rect: (f32, f32, f32, f32), palette: &Palette) -> Option<CopyButton> {
        let tertiary = palette.color(crate::markdown::Color::Tertiary);
        let font = pango::FontDescription::from_string(&format!("{} 8", palette.body_family));
        if let Some(label) = decoration.label.as_ref().filter(|l| !l.is_empty()) {
            let layout = self.create_pango_layout(Some(label));
            layout.set_font_description(Some(&font));
            set(cr, &tertiary);
            cr.move_to((rect.0 + 16.0) as f64, (rect.1 + 9.0) as f64);
            pangocairo::functions::show_layout(cr, &layout);
        }
        let code = decoration.code.clone()?;
        let copied = self
            .imp()
            .copied
            .borrow()
            .as_ref()
            .is_some_and(|(c, at)| *c == code && at.elapsed().as_secs_f32() < 1.4);
        let x = rect.0 + rect.2 - 30.0;
        let y = rect.1 + 8.0;
        let color = if copied { palette.accent } else { tertiary };
        set(cr, &color);
        cr.set_line_width(1.2);
        if copied {
            cr.move_to((x + 2.0) as f64, (y + 8.0) as f64);
            cr.line_to((x + 6.0) as f64, (y + 12.0) as f64);
            cr.line_to((x + 13.0) as f64, (y + 3.0) as f64);
            let _ = cr.stroke();
            let layout = self.create_pango_layout(Some(&t("Copiado")));
            layout.set_font_description(Some(&font));
            let (w, _) = layout.pixel_size();
            cr.move_to((x - 5.0 - w as f32) as f64, (y + 1.0) as f64);
            pangocairo::functions::show_layout(cr, &layout);
        } else {
            rounded(cr, (x + 4.0, y + 1.0, 9.0, 11.0), 2.0);
            let _ = cr.stroke();
            rounded(cr, (x + 1.0, y + 4.0, 9.0, 11.0), 2.0);
            set(cr, &palette.code_background());
            let _ = cr.fill_preserve();
            set(cr, &color);
            let _ = cr.stroke();
        }
        Some(CopyButton { rect: graphene::Rect::new(x - 8.0, y - 6.0, 31.0, 28.0), code })
    }

    fn draw_above(&self, snapshot: &gtk::Snapshot) {
        let Some(palette) = self.palette() else { return };
        let bullets = self.imp().bullets.borrow();
        let tasks = self.imp().tasks.borrow();
        let mut hits = Vec::new();
        if bullets.is_empty() && tasks.is_empty() {
            self.imp().task_hits.borrow_mut().clear();
            return;
        }
        let (visible_start, visible_end) = self.visible_offsets();
        let buffer = self.buffer();
        let visible = self.visible_rect();
        let area = graphene::Rect::new(0.0, visible.y() as f32 - 50.0, self.width() as f32 + 100.0, visible.height() as f32 + 100.0);
        let cr = snapshot.append_cairo(&area);
        let secondary = palette.color(crate::markdown::Color::Secondary);
        for &offset in bullets.iter().filter(|o| **o >= visible_start && **o <= visible_end) {
            let iter = buffer.iter_at_offset(offset as i32);
            let rect = self.iter_location(&iter);
            set(&cr, &secondary);
            let size = (rect.height() as f64 * 0.16).clamp(2.2, 4.0);
            cr.arc(rect.x() as f64 + rect.width() as f64 / 2.0, rect.y() as f64 + rect.height() as f64 * 0.55, size, 0.0, std::f64::consts::TAU);
            let _ = cr.fill();
        }
        for task in tasks.iter().filter(|t| t.start >= visible_start && t.start <= visible_end) {
            let start = self.iter_location(&buffer.iter_at_offset(task.start as i32));
            let end = self.iter_location(&buffer.iter_at_offset(task.end as i32));
            let side = (start.height() as f32 * 0.7).clamp(12.0, 22.0);
            let mid_x = (start.x() + end.x()) as f32 / 2.0;
            let mid_y = start.y() as f32 + start.height() as f32 * 0.55;
            let rect = (mid_x - side / 2.0, mid_y - side / 2.0, side, side);
            rounded(&cr, rect, 3.5);
            if task.checked {
                set(&cr, &palette.accent);
                let _ = cr.fill();
                set(&cr, &gdk::RGBA::WHITE);
                cr.set_line_width(1.8);
                cr.move_to((rect.0 + side * 0.25) as f64, (rect.1 + side * 0.52) as f64);
                cr.line_to((rect.0 + side * 0.43) as f64, (rect.1 + side * 0.7) as f64);
                cr.line_to((rect.0 + side * 0.76) as f64, (rect.1 + side * 0.32) as f64);
                let _ = cr.stroke();
            } else {
                set(&cr, &palette.color(crate::markdown::Color::Tertiary));
                cr.set_line_width(1.3);
                let _ = cr.stroke();
            }
            hits.push((graphene::Rect::new(rect.0 - 3.0, rect.1 - 3.0, side + 6.0, side + 6.0), task.source));
        }
        *self.imp().task_hits.borrow_mut() = hits;
    }

    /// Copy buttons and task boxes answer clicks before the text view sees them.
    fn handle_press(&self, x: f64, y: f64) -> bool {
        let (bx, by) = self.window_to_buffer_coords(gtk::TextWindowType::Widget, x as i32, y as i32);
        let point = graphene::Point::new(bx as f32, by as f32);
        let button = self.imp().copy_buttons.borrow().iter().find(|b| b.rect.contains_point(&point)).cloned();
        if let Some(button) = button {
            self.clipboard().set_text(&button.code);
            *self.imp().copied.borrow_mut() = Some((button.code, std::time::Instant::now()));
            self.queue_draw();
            let weak = self.downgrade();
            glib::timeout_add_local_once(std::time::Duration::from_millis(1500), move || {
                if let Some(view) = weak.upgrade() {
                    view.queue_draw();
                }
            });
            if let Some(f) = self.imp().on_copy.borrow().as_ref() {
                f();
            }
            return true;
        }
        let task = self.imp().task_hits.borrow().iter().find(|(r, _)| r.contains_point(&point)).map(|(_, s)| *s);
        if let Some(source) = task {
            if let Some(f) = self.imp().on_task.borrow().as_ref() {
                f(source);
            }
            return true;
        }
        false
    }

    /// Character offset at a point in widget coordinates, if it lands on text.
    pub fn offset_at(&self, x: f64, y: f64) -> Option<usize> {
        let (bx, by) = self.window_to_buffer_coords(gtk::TextWindowType::Widget, x as i32, y as i32);
        let iter = self.iter_at_location(bx, by)?;
        let rect = self.iter_location(&iter);
        if bx < rect.x() - 3 || bx > rect.x() + rect.width().max(4) + 3 || by < rect.y() - 2 || by > rect.y() + rect.height() + 2 {
            return None;
        }
        Some(iter.offset() as usize)
    }

    /// Character offset of the first line at the top of the viewport.
    pub fn top_offset(&self) -> usize {
        self.offset_below_top(12)
    }

    /// Character offset of the line `probe` pixels below the top of the viewport.
    pub fn offset_below_top(&self, probe: i32) -> usize {
        let rect = self.visible_rect();
        let (iter, _) = self.line_at_y(rect.y() + probe);
        iter.offset().max(0) as usize
    }

    /// Scrolls so the line holding `offset` sits near the top of the viewport.
    pub fn scroll_to_offset(&self, offset: usize, animate: bool) {
        let buffer = self.buffer();
        let iter = buffer.iter_at_offset(offset as i32);
        let Some(adjustment) = self.vadjustment() else { return };
        let (y, _) = self.line_yrange(&iter);
        let target = if offset == 0 { 0.0 } else { (y as f64 - 14.0).max(0.0) };
        let max = (adjustment.upper() - adjustment.page_size()).max(0.0);
        let target = target.min(max);
        if animate && (adjustment.value() - target).abs() > 1.0 {
            let animation = adw::TimedAnimation::new(
                self,
                adjustment.value(),
                target,
                220,
                adw::CallbackAnimationTarget::new(glib::clone!(
                    #[weak]
                    adjustment,
                    move |value| adjustment.set_value(value)
                )),
            );
            animation.set_easing(adw::Easing::EaseOutCubic);
            animation.play();
        } else {
            adjustment.set_value(target);
        }
    }
}

trait LineEnd {
    fn line_end_offset_iter_offset(&self) -> i32;
}

impl LineEnd for gtk::TextIter {
    fn line_end_offset_iter_offset(&self) -> i32 {
        let mut iter = *self;
        if !iter.ends_line() {
            iter.forward_to_line_end();
        }
        iter.offset()
    }
}

fn set(cr: &gtk::cairo::Context, color: &gdk::RGBA) {
    cr.set_source_rgba(color.red() as f64, color.green() as f64, color.blue() as f64, color.alpha() as f64);
}

fn rounded(cr: &gtk::cairo::Context, rect: (f32, f32, f32, f32), radius: f32) {
    let (x, y, w, h) = (rect.0 as f64 + 0.5, rect.1 as f64 + 0.5, rect.2 as f64 - 1.0, rect.3 as f64 - 1.0);
    let r = (radius as f64).min(w / 2.0).min(h / 2.0).max(0.0);
    cr.new_sub_path();
    cr.arc(x + w - r, y + r, r, -std::f64::consts::FRAC_PI_2, 0.0);
    cr.arc(x + w - r, y + h - r, r, 0.0, std::f64::consts::FRAC_PI_2);
    cr.arc(x + r, y + h - r, r, std::f64::consts::FRAC_PI_2, std::f64::consts::PI);
    cr.arc(x + r, y + r, r, std::f64::consts::PI, 1.5 * std::f64::consts::PI);
    cr.close_path();
}
