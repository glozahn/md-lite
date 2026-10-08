//! Markdown parsing, rendering and editor styling. Nothing in here depends on GTK:
//! the reader and the editor turn these models into text tags and widgets.

pub mod export;
pub mod gfm;
pub mod highlight;
pub mod html;
pub mod parse;
pub mod render;
pub mod style;

/// Semantic colors, resolved by the views for the current appearance and accent.
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug, Default)]
pub enum Color {
    #[default]
    Text,
    Secondary,
    Tertiary,
    Accent,
    Clear,
    CodeText,
    Keyword,
    Str,
    Comment,
    Number,
    Type,
    Function,
    Attribute,
    Added,
    Removed,
    Meta,
    Note,
    Tip,
    Important,
    Warning,
    Caution,
    InlineCode,
    Mark,
}

#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug, Default)]
pub enum Family {
    #[default]
    Body,
    Mono,
}

#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug, Default)]
pub enum Align {
    #[default]
    Natural,
    Left,
    Center,
    Right,
    Fill,
}

/// Paragraph layout, in pixels from the left edge of the text column.
#[derive(Clone, Debug, PartialEq, Default)]
pub struct Para {
    /// Left edge of wrapped lines.
    pub head: f32,
    /// Left edge of the first line.
    pub first: f32,
    /// Right inset.
    pub tail: f32,
    pub before: f32,
    pub after: f32,
    /// Extra space between wrapped lines.
    pub line_spacing: f32,
    pub align: Align,
    /// Tab stops (position, right aligned), measured like `head` and `first`.
    pub tabs: Vec<(f32, bool)>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Style {
    pub family: Family,
    pub size: f32,
    pub weight: u16,
    pub italic: bool,
    pub strike: bool,
    pub underline: bool,
    pub color: Color,
    pub background: Option<Color>,
    pub rise: f32,
    pub para: Para,
}

impl Style {
    pub fn body(size: f32) -> Style {
        Style {
            family: Family::Body,
            size,
            weight: 400,
            italic: false,
            strike: false,
            underline: false,
            color: Color::Text,
            background: None,
            rise: 0.0,
            para: Para::default(),
        }
    }

    pub fn bold(mut self) -> Style {
        self.weight = self.weight.max(700);
        self
    }

    pub fn italic(mut self) -> Style {
        self.italic = true;
        self
    }

    /// A stable identity for caching text tags.
    pub fn key(&self) -> String {
        format!("{self:?}")
    }
}

/// Converts byte offsets of a string into character offsets (what GTK text buffers count).
pub struct CharMap {
    /// Byte offset of every character boundary, plus the end.
    starts: Vec<usize>,
}

impl CharMap {
    pub fn new(text: &str) -> CharMap {
        let mut starts: Vec<usize> = text.char_indices().map(|(i, _)| i).collect();
        starts.push(text.len());
        CharMap { starts }
    }

    pub fn char(&self, byte: usize) -> usize {
        self.starts.partition_point(|&b| b < byte)
    }

    pub fn byte(&self, char: usize) -> usize {
        self.starts[char.min(self.starts.len() - 1)]
    }

    pub fn len(&self) -> usize {
        self.starts.len() - 1
    }
}
