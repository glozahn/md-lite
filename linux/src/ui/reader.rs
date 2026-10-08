//! Puts a rendered document into a text view: text with tags, then tables, images,
//! diagrams and checkboxes as embedded widgets.

use crate::i18n::t;
use crate::images;
use crate::markdown::render::{Cell, Embed, Rendered, Table};
use crate::markdown::{Align, CharMap};
use crate::mermaid;
use crate::ui::bounded::Bounded;
use crate::ui::textview::MdTextView;
use crate::ui::theme::{Palette, TagCache};
use gtk::prelude::*;
use gtk::{gdk, glib};
use std::cell::Cell as StdCell;
use std::rc::Rc;

#[derive(Clone)]
pub struct Hooks {
    /// Toggles the task whose `[` sits at this byte offset of the source.
    pub on_task: Rc<dyn Fn(usize)>,
    pub on_link: Rc<dyn Fn(String)>,
    pub remote_allowed: bool,
    /// A remote image finished downloading.
    pub on_remote_loaded: Rc<dyn Fn()>,
    pub max_image_width: f32,
}

pub fn show(view: &MdTextView, tags: &TagCache, rendered: &Rendered, hooks: &Hooks) {
    let buffer = view.buffer();
    let palette = tags.palette();
    view.clear_embeds();
    buffer.set_text("");
    let map = CharMap::new(&rendered.text);
    let mut iter = buffer.start_iter();
    let mut cursor = 0;
    let available = view.available();
    for (offset, embed) in &rendered.embeds {
        if *offset > cursor {
            buffer.insert(&mut iter, &rendered.text[map.byte(cursor)..map.byte(*offset)]);
        }
        let anchor = buffer.create_child_anchor(&mut iter);
        if let Some(widget) = build(embed, rendered, &palette, hooks, &available) {
            view.add_embed(&widget, &anchor);
        }
        cursor = offset + 1;
    }
    if cursor < map.len() {
        buffer.insert(&mut iter, &rendered.text[map.byte(cursor)..]);
    }
    for run in &rendered.runs {
        let tag = tags.tag(&rendered.styles[run.style]);
        buffer.apply_tag(&tag, &buffer.iter_at_offset(run.start as i32), &buffer.iter_at_offset(run.end as i32));
    }
    view.set_decorations(rendered.decorations.clone());
}

fn build(embed: &Embed, rendered: &Rendered, palette: &Palette, hooks: &Hooks, available: &Rc<StdCell<i32>>) -> Option<gtk::Widget> {
    match embed {
        Embed::Image { url, alt, width, height, title, link } => {
            let texture = if images::is_remote(url) {
                if hooks.remote_allowed {
                    let texture = images::remote(url);
                    if texture.is_none() && !images::remote_failed(url) {
                        let done = hooks.on_remote_loaded.clone();
                        images::fetch(url, move || done());
                    }
                    texture
                } else {
                    None
                }
            } else {
                images::local(url)
            };
            let tooltip = title.clone().or_else(|| (!alt.is_empty()).then(|| alt.clone()));
            match texture {
                Some(texture) => {
                    let (w, h) = (texture.width() as f32, texture.height() as f32);
                    let mut size = match (width, height) {
                        (Some(w2), Some(h2)) => (*w2, *h2),
                        (Some(w2), None) => (*w2, w2 * h / w.max(1.0)),
                        (None, Some(h2)) => (h2 * w / h.max(1.0), *h2),
                        (None, None) => (w, h),
                    };
                    let scale = (hooks.max_image_width / size.0).min(1600.0 / size.1).min(1.0);
                    size = (size.0 * scale, size.1 * scale);
                    Some(picture(&texture, size.0 as i32, tooltip.as_deref(), link.clone(), hooks, available))
                }
                None => {
                    let name = if alt.is_empty() {
                        url.rsplit('/').next().filter(|n| !n.is_empty()).map(crate::markdown::render::percent_decode).unwrap_or_else(|| t("Imagen"))
                    } else {
                        alt.clone()
                    };
                    let chip = gtk::Button::with_label(&format!("▧ {name}"));
                    chip.add_css_class("md-chip");
                    chip.set_tooltip_text(Some(url));
                    let target = link.clone().unwrap_or_else(|| url.clone());
                    let on_link = hooks.on_link.clone();
                    chip.connect_clicked(move |_| on_link(target.clone()));
                    Some(chip.upcast())
                }
            }
        }
        Embed::Svg { data, width } => {
            let texture = gdk::Texture::from_bytes(&glib::Bytes::from(data.as_bytes())).ok()?;
            let cap = width.map_or(texture.width(), |w| w as i32);
            Some(picture(&texture, cap, None, None, hooks, available))
        }
        Embed::Table(table) => Some(table_widget(table, rendered, palette, hooks, available)),
        Embed::Diagram { code, dark } => match mermaid::result(code, *dark) {
            Some(mermaid::Diagram::Image { texture, width, .. }) => Some(picture(&texture, width, None, None, hooks, available)),
            _ => None,
        },
        Embed::Check { checked, task } => {
            let check = gtk::CheckButton::new();
            check.set_active(*checked);
            check.add_css_class("md-check");
            check.set_can_focus(false);
            match task {
                Some(offset) => {
                    let offset = *offset;
                    let on_task = hooks.on_task.clone();
                    // Toggling rebuilds the reader, which destroys this checkbox. Wait until GTK
                    // has finished handling the click; removing a widget inside its own click
                    // handler freezes the app.
                    check.connect_toggled(move |_| {
                        let on_task = on_task.clone();
                        glib::idle_add_local_once(move || on_task(offset));
                    });
                }
                None => check.set_sensitive(false),
            }
            Some(check.upcast())
        }
        Embed::AlertIcon(alert) => {
            let image = gtk::Image::from_icon_name(alert.icon());
            image.set_pixel_size(16);
            image.add_css_class("md-alert-icon");
            image.add_css_class(&format!("md-{:?}", alert).to_lowercase());
            Some(image.upcast())
        }
    }
}

fn picture(texture: &gdk::Texture, cap: i32, tooltip: Option<&str>, link: Option<String>, hooks: &Hooks, available: &Rc<StdCell<i32>>) -> gtk::Widget {
    let picture = gtk::Picture::for_paintable(texture);
    picture.set_can_shrink(true);
    picture.set_content_fit(gtk::ContentFit::Contain);
    picture.set_tooltip_text(tooltip);
    picture.add_css_class("md-image");
    if let Some(link) = link {
        picture.set_cursor_from_name(Some("pointer"));
        let click = gtk::GestureClick::new();
        let on_link = hooks.on_link.clone();
        click.connect_released(move |_, _, _, _| on_link(link.clone()));
        picture.add_controller(click);
    }
    Bounded::new(&picture, available.clone(), cap.max(1)).upcast()
}

fn markup(cell: &Cell, rendered: &Rendered, palette: &Palette) -> String {
    let mut out = String::new();
    for run in &cell.runs {
        let style = &rendered.styles[run.style];
        let text = glib::markup_escape_text(&run.text.replace('\u{2028}', "\n"));
        let span = format!("<span {}>{}</span>", palette.span_attributes(style), text);
        match &run.link {
            Some(link) => out.push_str(&format!("<a href=\"{}\">{}</a>", glib::markup_escape_text(link), span)),
            None => out.push_str(&span),
        }
    }
    out
}

fn table_widget(table: &Table, rendered: &Rendered, palette: &Palette, hooks: &Hooks, available: &Rc<StdCell<i32>>) -> gtk::Widget {
    let grid = gtk::Grid::new();
    grid.add_css_class("md-table");
    let empty = Cell { runs: Vec::new(), header: false, align: Align::Natural };
    for (r, row) in table.rows.iter().enumerate() {
        for column in 0..table.columns {
            let cell = row.get(column).unwrap_or(&empty);
            let label = gtk::Label::new(None);
            label.set_markup(&markup(cell, rendered, palette));
            label.set_wrap(true);
            label.set_wrap_mode(gtk::pango::WrapMode::WordChar);
            label.set_selectable(true);
            label.set_can_focus(false);
            label.set_xalign(match cell.align {
                Align::Center => 0.5,
                Align::Right => 1.0,
                _ => 0.0,
            });
            label.set_justify(match cell.align {
                Align::Center => gtk::Justification::Center,
                Align::Right => gtk::Justification::Right,
                _ => gtk::Justification::Left,
            });
            label.set_hexpand(true);
            let on_link = hooks.on_link.clone();
            label.connect_activate_link(move |_, uri| {
                on_link(uri.to_string());
                glib::Propagation::Stop
            });
            let holder = gtk::Box::new(gtk::Orientation::Vertical, 0);
            holder.add_css_class("md-cell");
            holder.set_valign(gtk::Align::Fill);
            label.set_valign(gtk::Align::Center);
            label.set_vexpand(true);
            if cell.header || (r == 0 && row.iter().all(|c| c.header)) {
                holder.add_css_class("md-head");
            } else if r % 2 == 0 {
                holder.add_css_class("md-stripe");
            }
            if column == 0 {
                holder.add_css_class("md-first-column");
            }
            if r == 0 {
                holder.add_css_class("md-first-row");
            }
            holder.append(&label);
            grid.attach(&holder, column as i32, r as i32, 1, 1);
        }
    }
    Bounded::new(&grid, available.clone(), 0).upcast()
}
