//! Colors and fonts for the current appearance, and the text tags built from styles.

use crate::markdown::{Align, Color, Family, Style};
use gtk::prelude::*;
use gtk::{gdk, pango};
use std::cell::RefCell;
use std::collections::HashMap;

fn hex(value: u32, alpha: f32) -> gdk::RGBA {
    gdk::RGBA::new(
        ((value >> 16) & 0xFF) as f32 / 255.0,
        ((value >> 8) & 0xFF) as f32 / 255.0,
        (value & 0xFF) as f32 / 255.0,
        alpha,
    )
}

#[derive(Clone, Debug, PartialEq)]
pub struct Palette {
    pub dark: bool,
    pub accent: gdk::RGBA,
    pub body_family: String,
    pub mono_family: String,
}

impl Palette {
    pub fn color(&self, color: Color) -> gdk::RGBA {
        let d = self.dark;
        let pick = |light: u32, dark: u32| hex(if d { dark } else { light }, 1.0);
        let ink = |alpha: f32| if d { gdk::RGBA::new(1.0, 1.0, 1.0, alpha) } else { gdk::RGBA::new(0.0, 0.0, 0.03, alpha) };
        match color {
            Color::Text => ink(if d { 0.92 } else { 0.84 }),
            Color::Secondary => ink(if d { 0.6 } else { 0.56 }),
            Color::Tertiary => ink(if d { 0.36 } else { 0.32 }),
            Color::Accent => self.accent,
            Color::Clear => gdk::RGBA::new(0.0, 0.0, 0.0, 0.004),
            Color::CodeText => pick(0x24292F, 0xE6EDF3),
            Color::Keyword => pick(0x9B2393, 0xFF7AB2),
            Color::Str => pick(0xC41A16, 0xFF8170),
            Color::Comment => pick(0x6E7781, 0x8B949E),
            Color::Number => pick(0x1C00CF, 0xD9C97C),
            Color::Type => pick(0x0B4F79, 0x5DD8FF),
            Color::Function => pick(0x326D74, 0x67B7A4),
            Color::Attribute => pick(0x815F03, 0xE3A869),
            Color::Added => pick(0x1A7F37, 0x7EE787),
            Color::Removed => pick(0xCF222E, 0xFF7B72),
            Color::Meta => pick(0x6639BA, 0xD2A8FF),
            Color::Note => pick(0x0969DA, 0x4493F8),
            Color::Tip => pick(0x1A7F37, 0x3FB950),
            Color::Important => pick(0x8250DF, 0xAB7DF8),
            Color::Warning => pick(0x9A6700, 0xD29922),
            Color::Caution => pick(0xCF222E, 0xF85149),
            Color::InlineCode => ink(if d { 0.1 } else { 0.06 }),
            Color::Mark => gdk::RGBA::new(1.0, 0.8, 0.0, 0.35),
        }
    }

    pub fn code_background(&self) -> gdk::RGBA {
        if self.dark { gdk::RGBA::new(1.0, 1.0, 1.0, 0.05) } else { gdk::RGBA::new(0.0, 0.0, 0.0, 0.035) }
    }

    pub fn code_border(&self) -> gdk::RGBA {
        if self.dark { gdk::RGBA::new(1.0, 1.0, 1.0, 0.07) } else { gdk::RGBA::new(0.0, 0.0, 0.0, 0.06) }
    }

    pub fn separator(&self) -> gdk::RGBA {
        if self.dark { gdk::RGBA::new(1.0, 1.0, 1.0, 0.13) } else { gdk::RGBA::new(0.0, 0.0, 0.0, 0.12) }
    }

    pub fn family(&self, family: Family) -> &str {
        match family {
            Family::Body => &self.body_family,
            Family::Mono => &self.mono_family,
        }
    }

    /// Pango markup attributes for a style (used in table cells).
    pub fn span_attributes(&self, style: &Style) -> String {
        let color = self.color(style.color);
        let mut out = format!(
            "font_family=\"{}\" size=\"{}\" weight=\"{}\" foreground=\"{}\"",
            glib::markup_escape_text(self.family(style.family)),
            (style.size * 0.75 * pango::SCALE as f32) as i32,
            style.weight,
            rgba_hex(&color),
        );
        if color.alpha() < 1.0 {
            out.push_str(&format!(" fgalpha=\"{}%\"", (color.alpha() * 100.0).round() as i32));
        }
        if style.italic {
            out.push_str(" style=\"italic\"");
        }
        if style.strike {
            out.push_str(" strikethrough=\"true\"");
        }
        if style.underline {
            out.push_str(" underline=\"single\"");
        }
        if let Some(background) = style.background {
            let bg = self.color(background);
            out.push_str(&format!(" background=\"{}\" bgalpha=\"{}%\"", rgba_hex(&bg), (bg.alpha() * 100.0).round().max(1.0) as i32));
        }
        if style.rise != 0.0 {
            out.push_str(&format!(" rise=\"{}\"", (style.rise * pango::SCALE as f32) as i32));
        }
        out
    }
}

pub fn rgba_hex(color: &gdk::RGBA) -> String {
    format!(
        "#{:02x}{:02x}{:02x}",
        (color.red() * 255.0).round() as u8,
        (color.green() * 255.0).round() as u8,
        (color.blue() * 255.0).round() as u8
    )
}

/// One text tag per distinct style, created on demand in a buffer's tag table.
pub struct TagCache {
    table: gtk::TextTagTable,
    tags: RefCell<HashMap<String, gtk::TextTag>>,
    palette: RefCell<Option<Palette>>,
    /// Tags that must stay above every style tag (concealing, search highlights).
    overlays: RefCell<Vec<gtk::TextTag>>,
}

impl TagCache {
    pub fn new(table: &gtk::TextTagTable) -> TagCache {
        TagCache {
            table: table.clone(),
            tags: RefCell::new(HashMap::new()),
            palette: RefCell::new(None),
            overlays: RefCell::new(Vec::new()),
        }
    }

    /// Drops every cached tag when the colors or fonts change.
    pub fn set_palette(&self, palette: &Palette) {
        if self.palette.borrow().as_ref() == Some(palette) {
            return;
        }
        for tag in self.tags.borrow_mut().drain().map(|(_, t)| t) {
            self.table.remove(&tag);
        }
        *self.palette.borrow_mut() = Some(palette.clone());
    }

    pub fn palette(&self) -> Palette {
        self.palette.borrow().clone().expect("palette set before tags")
    }

    pub fn add_overlay(&self, tag: &gtk::TextTag) {
        self.table.add(tag);
        self.overlays.borrow_mut().push(tag.clone());
    }

    fn raise_overlays(&self) {
        let top = self.table.size() - 1;
        for tag in self.overlays.borrow().iter() {
            tag.set_priority(top);
        }
    }

    pub fn tag(&self, style: &Style) -> gtk::TextTag {
        let key = style.key();
        if let Some(tag) = self.tags.borrow().get(&key) {
            return tag.clone();
        }
        let palette = self.palette();
        let tag = build_tag(style, &palette);
        self.table.add(&tag);
        self.tags.borrow_mut().insert(key, tag.clone());
        self.raise_overlays();
        tag
    }
}

pub fn build_tag(style: &Style, palette: &Palette) -> gtk::TextTag {
    let tag = gtk::TextTag::new(None);
    tag.set_family(Some(palette.family(style.family)));
    tag.set_size_points(f64::from(style.size) * 0.75);
    tag.set_weight(i32::from(style.weight));
    tag.set_style(if style.italic { pango::Style::Italic } else { pango::Style::Normal });
    tag.set_strikethrough(style.strike);
    tag.set_underline(if style.underline { pango::Underline::Single } else { pango::Underline::None });
    tag.set_foreground_rgba(Some(&palette.color(style.color)));
    if let Some(background) = style.background {
        tag.set_background_rgba(Some(&palette.color(background)));
    }
    if style.rise != 0.0 {
        tag.set_rise((style.rise * pango::SCALE as f32) as i32);
    }
    let para = &style.para;
    // GTK puts the first line at the left margin; a negative indent hangs the lines after it.
    let left = para.head.min(para.first);
    tag.set_left_margin(left.round().max(0.0) as i32);
    tag.set_indent((para.first - para.head).round() as i32);
    tag.set_right_margin(para.tail.round().max(0.0) as i32);
    tag.set_pixels_above_lines(para.before.round().max(0.0) as i32);
    tag.set_pixels_below_lines(para.after.round().max(0.0) as i32);
    tag.set_pixels_inside_wrap(para.line_spacing.round().max(0.0) as i32);
    tag.set_justification(match para.align {
        Align::Center => gtk::Justification::Center,
        Align::Right => gtk::Justification::Right,
        Align::Fill => gtk::Justification::Fill,
        _ => gtk::Justification::Left,
    });
    if !para.tabs.is_empty() {
        // Pango measures tab stops from the start of the first line.
        let mut tabs = pango::TabArray::new(para.tabs.len() as i32, true);
        for (index, (position, right)) in para.tabs.iter().enumerate() {
            let alignment = if *right { pango::TabAlign::Right } else { pango::TabAlign::Left };
            tabs.set_tab(index as i32, alignment, (position - left).round().max(0.0) as i32);
        }
        tag.set_tabs(Some(&tabs));
    }
    tag
}
