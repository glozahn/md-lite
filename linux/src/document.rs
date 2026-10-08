//! One tab: a Markdown document with its reader, editor, undo history and file.

use crate::i18n::{t, tf};
use crate::markdown::render::{MermaidState, OutlineItem, Rendered, Renderer};
use crate::markdown::{export, CharMap};
use crate::ui::editor::{Editor, FormatAction};
use crate::ui::reader;
use crate::ui::textview::MdTextView;
use crate::ui::theme::{Palette, TagCache};
use crate::{mermaid, prefs};
use adw::prelude::*;
use adw::subclass::prelude::*;
use gtk::glib::subclass::Signal;
use gtk::{gdk, gio, glib};
use std::cell::{Cell, OnceCell, RefCell};
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::sync::OnceLock;
use std::time::Duration;
use webkit6::prelude::WebViewExt;

pub const MAX_FILE: u64 = 5_000_000;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub enum Kind {
    #[default]
    Welcome,
    File,
    Note,
    Pasted,
    Blank,
    Changelog,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub enum Mode {
    #[default]
    Read,
    Edit,
    Source,
    Split,
}

impl Mode {
    pub fn name(self) -> &'static str {
        match self {
            Mode::Read => "read",
            Mode::Edit => "edit",
            Mode::Source => "source",
            Mode::Split => "split",
        }
    }

    pub fn from_name(name: &str) -> Mode {
        match name {
            "edit" => Mode::Edit,
            "source" => Mode::Source,
            "split" => Mode::Split,
            _ => Mode::Read,
        }
    }

    fn shows_reader(self) -> bool {
        matches!(self, Mode::Read | Mode::Split)
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum BannerKind {
    None,
    Remote,
    Changed,
}

pub fn welcome_text() -> &'static str {
    if crate::i18n::language() == "es" {
        include_str!("../data/welcome.es.md")
    } else {
        include_str!("../data/welcome.en.md")
    }
}

pub fn read_file(path: &Path) -> Result<String, String> {
    let meta = std::fs::metadata(path).map_err(|e| e.to_string())?;
    if !meta.is_file() || meta.len() > MAX_FILE {
        return Err(t("Elige un archivo de texto UTF-8 de hasta 5 MB."));
    }
    let bytes = std::fs::read(path).map_err(|e| e.to_string())?;
    String::from_utf8(bytes).map_err(|_| t("Elige un archivo de texto UTF-8 de hasta 5 MB."))
}

/// Writes through a temporary file and a rename so a crash never leaves a half-written document.
pub fn write_file(path: &Path, contents: &str) -> std::io::Result<()> {
    let name = path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_else(|| "document.md".into());
    let temporary = path.with_file_name(format!(".{name}.mdlite-tmp"));
    std::fs::write(&temporary, contents)?;
    if let Ok(meta) = std::fs::metadata(path) {
        let _ = std::fs::set_permissions(&temporary, meta.permissions());
    }
    std::fs::rename(&temporary, path).inspect_err(|_| {
        let _ = std::fs::remove_file(&temporary);
    })
}

pub fn palette(dark: bool) -> Palette {
    let accent = accent_color(dark);
    let font = gtk::Settings::default()
        .and_then(|s| s.gtk_font_name())
        .map(|f| gtk::pango::FontDescription::from_string(&f))
        .and_then(|d| d.family().map(|f| f.to_string()))
        .filter(|f| !f.is_empty())
        .unwrap_or_else(|| "Sans".into());
    Palette { dark, accent, body_family: font, mono_family: "Monospace".into() }
}

pub fn accent_color(dark: bool) -> gdk::RGBA {
    let choice = prefs::with(|p| p.accent.clone());
    let accent = match choice.as_str() {
        "teal" => Some(adw::AccentColor::Teal),
        "blue" => Some(adw::AccentColor::Blue),
        "purple" => Some(adw::AccentColor::Purple),
        "pink" => Some(adw::AccentColor::Pink),
        "orange" => Some(adw::AccentColor::Orange),
        "green" => Some(adw::AccentColor::Green),
        _ => None,
    };
    match accent {
        Some(a) => a.to_standalone_rgba(dark),
        None => {
            let manager = adw::StyleManager::default();
            manager.accent_color().to_standalone_rgba(dark)
        }
    }
}

mod imp {
    use super::*;

    #[derive(Default)]
    pub struct DocumentPage {
        pub kind: Cell<Kind>,
        pub path: RefCell<Option<PathBuf>>,
        pub mode: Cell<Mode>,
        pub last_edit_mode: Cell<Mode>,
        pub dirty: Cell<bool>,
        pub saving: Cell<bool>,
        pub saved_at: Cell<Option<std::time::Instant>>,
        pub last_written: RefCell<Option<String>>,
        pub remote_allowed: Cell<bool>,
        pub loading: Cell<bool>,
        pub rendered: RefCell<Rc<Rendered>>,
        pub reader_stale: Cell<bool>,
        pub heading: Cell<i32>,
        pub syncing: Cell<bool>,
        pub banner_kind: Cell<u8>,
        pub render_timer: RefCell<Option<glib::SourceId>>,
        pub save_timer: RefCell<Option<glib::SourceId>>,
        pub reload_timer: RefCell<Option<glib::SourceId>>,
        pub monitor: RefCell<Option<gio::FileMonitor>>,
        pub listener: RefCell<Option<Rc<dyn Fn()>>>,
        pub palette: RefCell<Option<Palette>>,

        pub editor: OnceCell<Rc<Editor>>,
        pub reader: OnceCell<MdTextView>,
        pub reader_tags: OnceCell<Rc<TagCache>>,
        pub reader_scroll: OnceCell<gtk::ScrolledWindow>,
        pub editor_scroll: OnceCell<gtk::ScrolledWindow>,
        pub reader_clamp: OnceCell<adw::ClampScrollable>,
        pub editor_clamp: OnceCell<adw::ClampScrollable>,
        pub paned: OnceCell<gtk::Paned>,
        pub stack: OnceCell<gtk::Stack>,
        pub banner: OnceCell<adw::Banner>,
        pub search_bar: OnceCell<gtk::SearchBar>,
        pub search_entry: OnceCell<gtk::SearchEntry>,
        pub search_label: OnceCell<gtk::Label>,
        pub format_bar: OnceCell<gtk::Revealer>,
        pub footer: OnceCell<gtk::Box>,
        pub stats: OnceCell<gtk::Label>,
        pub progress: OnceCell<gtk::Label>,
        pub status: OnceCell<gtk::Label>,
        pub matches: RefCell<Vec<(usize, usize)>>,
        pub current_match: Cell<usize>,
        pub print_view: RefCell<Option<webkit6::WebView>>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for DocumentPage {
        const NAME: &'static str = "MdDocumentPage";
        type Type = super::DocumentPage;
        type ParentType = adw::Bin;
    }

    impl ObjectImpl for DocumentPage {
        fn signals() -> &'static [Signal] {
            static SIGNALS: OnceLock<Vec<Signal>> = OnceLock::new();
            SIGNALS.get_or_init(|| {
                vec![
                    Signal::builder("state-changed").build(),
                    Signal::builder("outline-changed").build(),
                    Signal::builder("heading-changed").build(),
                    Signal::builder("open-path").param_types([String::static_type(), bool::static_type()]).build(),
                    Signal::builder("toast").param_types([String::static_type()]).build(),
                ]
            })
        }

        fn constructed(&self) {
            self.parent_constructed();
            self.obj().build();
        }

        fn dispose(&self) {
            if let Some(monitor) = self.monitor.borrow_mut().take() {
                monitor.cancel();
            }
            for timer in [&self.render_timer, &self.save_timer, &self.reload_timer] {
                if let Some(id) = timer.borrow_mut().take() {
                    id.remove();
                }
            }
        }
    }

    impl WidgetImpl for DocumentPage {}
    impl BinImpl for DocumentPage {}
}

glib::wrapper! {
    pub struct DocumentPage(ObjectSubclass<imp::DocumentPage>)
        @extends adw::Bin, gtk::Widget,
        @implements gtk::Accessible, gtk::Buildable, gtk::ConstraintTarget;
}

impl Default for DocumentPage {
    fn default() -> Self {
        Self::new()
    }
}

impl DocumentPage {
    pub fn new() -> Self {
        glib::Object::new()
    }

    fn editor(&self) -> &Rc<Editor> {
        self.imp().editor.get().unwrap()
    }

    pub fn reader(&self) -> &MdTextView {
        self.imp().reader.get().unwrap()
    }

    pub fn buffer(&self) -> gtk::TextBuffer {
        self.editor().view.buffer()
    }

    pub fn source(&self) -> String {
        let buffer = self.buffer();
        let (s, e) = buffer.bounds();
        buffer.text(&s, &e, true).to_string()
    }

    // MARK: Building

    fn build(&self) {
        let imp = self.imp();
        self.add_css_class("md-page");
        imp.mode.set(Mode::Read);
        imp.last_edit_mode.set(Mode::Edit);
        imp.heading.set(-1);

        let reader = MdTextView::new();
        reader.set_editable(false);
        reader.set_cursor_visible(false);
        reader.add_css_class("md-reader");
        let reader_tags = Rc::new(TagCache::new(&reader.buffer().tag_table()));
        let search = gtk::TextTag::new(Some("md-search"));
        search.set_background_rgba(Some(&gdk::RGBA::new(1.0, 0.8, 0.0, 0.35)));
        let current = gtk::TextTag::new(Some("md-search-current"));
        current.set_background_rgba(Some(&gdk::RGBA::new(1.0, 0.6, 0.0, 0.7)));
        reader_tags.add_overlay(&search);
        reader_tags.add_overlay(&current);

        let editor = Editor::new();
        for tag_name in ["md-search", "md-search-current"] {
            let tag = gtk::TextTag::new(Some(tag_name));
            let alpha = if tag_name == "md-search" { 0.35 } else { 0.7 };
            tag.set_background_rgba(Some(&gdk::RGBA::new(1.0, 0.7, 0.0, alpha)));
            editor.tags.add_overlay(&tag);
        }

        let (reader_scroll, reader_clamp) = scroller(&reader);
        let (editor_scroll, editor_clamp) = scroller(&editor.view);
        let paned = gtk::Paned::new(gtk::Orientation::Horizontal);
        paned.set_start_child(Some(&editor_scroll));
        paned.set_end_child(Some(&reader_scroll));
        paned.set_resize_start_child(true);
        paned.set_resize_end_child(true);
        paned.set_shrink_start_child(false);
        paned.set_shrink_end_child(false);
        paned.set_wide_handle(false);
        editor_scroll.set_visible(false);

        let stack = gtk::Stack::new();
        stack.set_vexpand(true);
        stack.add_named(&paned, Some("document"));
        stack.add_named(&self.blank_page(), Some("blank"));

        let banner = adw::Banner::new("");
        banner.connect_button_clicked(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |_| page.banner_action()
        ));

        let (search_bar, search_entry, search_label) = self.search_bar();
        let format_bar = gtk::Revealer::new();
        format_bar.set_child(Some(&self.format_bar()));
        format_bar.set_transition_type(gtk::RevealerTransitionType::SlideDown);

        let footer = gtk::Box::new(gtk::Orientation::Horizontal, 12);
        footer.add_css_class("md-footer");
        let stats = gtk::Label::new(None);
        let progress = gtk::Label::new(None);
        let status = gtk::Label::new(None);
        stats.set_xalign(0.0);
        stats.set_hexpand(true);
        stats.set_ellipsize(gtk::pango::EllipsizeMode::End);
        footer.append(&stats);
        footer.append(&progress);
        footer.append(&status);

        let column = gtk::Box::new(gtk::Orientation::Vertical, 0);
        column.append(&banner);
        column.append(&search_bar);
        column.append(&format_bar);
        column.append(&stack);
        column.append(&footer);
        self.set_child(Some(&column));

        let _ = imp.reader.set(reader.clone());
        let _ = imp.reader_tags.set(reader_tags);
        let _ = imp.editor.set(editor.clone());
        let _ = imp.reader_scroll.set(reader_scroll.clone());
        let _ = imp.editor_scroll.set(editor_scroll.clone());
        let _ = imp.reader_clamp.set(reader_clamp);
        let _ = imp.editor_clamp.set(editor_clamp);
        let _ = imp.paned.set(paned.clone());
        let _ = imp.stack.set(stack);
        let _ = imp.banner.set(banner);
        let _ = imp.search_bar.set(search_bar);
        let _ = imp.search_entry.set(search_entry);
        let _ = imp.search_label.set(search_label);
        let _ = imp.format_bar.set(format_bar);
        let _ = imp.footer.set(footer);
        let _ = imp.stats.set(stats);
        let _ = imp.progress.set(progress);
        let _ = imp.status.set(status);

        self.connect_views();
        self.apply_prefs();
        self.load_text("", Kind::Blank, None);
    }

    fn connect_views(&self) {
        let imp = self.imp();
        let editor = self.editor().clone();
        let buffer = editor.view.buffer();
        buffer.connect_changed(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |_| page.text_changed()
        ));
        let weak = self.downgrade();
        *editor.on_link.borrow_mut() = Some(Rc::new(move |url| {
            if let Some(page) = weak.upgrade() {
                page.open_link(&url);
            }
        }));
        editor.view.connect_task(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |offset| page.editor().toggle_task_at_char(offset)
        ));
        let toast = glib::clone!(
            #[weak(rename_to = page)]
            self,
            move || page.emit_by_name::<()>("toast", &[&t("Código copiado")])
        );
        editor.view.connect_copy(toast.clone());
        self.reader().connect_copy(toast);

        // Links in the reader open on a click that does not select text.
        let click = gtk::GestureClick::new();
        click.set_button(gdk::BUTTON_PRIMARY);
        click.connect_released(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |_, n, x, y| {
                if n != 1 || page.reader().buffer().has_selection() {
                    return;
                }
                let Some(offset) = page.reader().offset_at(x, y) else { return };
                let url = page.imp().rendered.borrow().link_at(offset).map(|l| l.url.clone());
                if let Some(url) = url {
                    page.open_link(&url);
                }
            }
        ));
        self.reader().add_controller(click);
        let motion = gtk::EventControllerMotion::new();
        motion.connect_motion(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |_, x, y| {
                let over = page.reader().offset_at(x, y).is_some_and(|o| page.imp().rendered.borrow().link_at(o).is_some());
                page.reader().set_cursor_from_name(Some(if over { "pointer" } else { "text" }));
            }
        ));
        self.reader().add_controller(motion);

        // Double-click on the reader jumps into the editor at that spot.
        let reader_adjustment = imp.reader_scroll.get().unwrap().vadjustment();
        reader_adjustment.connect_value_changed(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |_| page.reader_scrolled()
        ));
        let editor_adjustment = imp.editor_scroll.get().unwrap().vadjustment();
        editor_adjustment.connect_value_changed(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |_| page.editor_scrolled()
        ));
        imp.paned.get().unwrap().connect_notify_local(
            Some("max-position"),
            glib::clone!(
                #[weak(rename_to = page)]
                self,
                move |_, _| {
                    if page.mode() == Mode::Split {
                        page.apply_split_ratio();
                    }
                }
            ),
        );
        imp.paned.get().unwrap().connect_position_notify(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |paned| {
                let width = paned.width();
                if width > 0 && page.mode() == Mode::Split && paned.is_mapped() {
                    let ratio = (paned.position() as f64 / width as f64).clamp(0.2, 0.8);
                    prefs::update_quietly(|p| p.split_ratio = ratio);
                }
            }
        ));

        let listener: Rc<dyn Fn()> = Rc::new(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move || {
                let has_diagrams = page.imp().rendered.borrow().embeds.iter().any(|(_, e)| matches!(e, crate::markdown::render::Embed::Diagram { .. }))
                    || page.source().contains("```mermaid");
                if has_diagrams {
                    page.render_now();
                }
            }
        ));
        mermaid::add_listener(&listener);
        *imp.listener.borrow_mut() = Some(listener);

        let drop = gtk::DropTarget::new(gdk::FileList::static_type(), gdk::DragAction::COPY);
        drop.connect_drop(glib::clone!(
            #[weak(rename_to = page)]
            self,
            #[upgrade_or]
            false,
            move |_, value, _, _| {
                let Ok(list) = value.get::<gdk::FileList>() else { return false };
                let mut first = true;
                for file in list.files() {
                    if let Some(path) = file.path() {
                        let new_tab = !(first && page.can_reuse());
                        page.emit_by_name::<()>("open-path", &[&path.to_string_lossy().to_string(), &new_tab]);
                        first = false;
                    }
                }
                true
            }
        ));
        self.add_controller(drop);
    }

    fn blank_page(&self) -> gtk::Widget {
        let status = adw::StatusPage::new();
        status.set_icon_name(Some("io.github.glozahn.MDLite"));
        status.set_title(&t("Suelta un Markdown aquí"));
        status.set_description(Some(&t("o elige qué abrir en esta pestaña.")));
        let buttons = gtk::Box::new(gtk::Orientation::Vertical, 10);
        buttons.set_halign(gtk::Align::Center);
        for (label, action, suggested) in [
            ("Abrir documento", "win.open", true),
            ("Nueva nota", "win.new-note", false),
            ("Pegar y leer", "win.paste-read", false),
            ("Abrir carpeta…", "win.open-folder", false),
        ] {
            let button = gtk::Button::with_label(&t(label));
            button.set_action_name(Some(action));
            button.add_css_class("pill");
            if suggested {
                button.add_css_class("suggested-action");
            }
            buttons.append(&button);
        }
        status.set_child(Some(&buttons));
        status.upcast()
    }

    fn search_bar(&self) -> (gtk::SearchBar, gtk::SearchEntry, gtk::Label) {
        let bar = gtk::SearchBar::new();
        let entry = gtk::SearchEntry::new();
        entry.set_placeholder_text(Some(&t("Buscar en el documento")));
        entry.set_width_chars(28);
        let label = gtk::Label::new(None);
        label.add_css_class("dim-label");
        label.add_css_class("caption");
        let previous = gtk::Button::from_icon_name("go-up-symbolic");
        previous.set_tooltip_text(Some(&t("Buscar anterior")));
        let next = gtk::Button::from_icon_name("go-down-symbolic");
        next.set_tooltip_text(Some(&t("Buscar siguiente")));
        let row = gtk::Box::new(gtk::Orientation::Horizontal, 6);
        row.append(&entry);
        let arrows = gtk::Box::new(gtk::Orientation::Horizontal, 0);
        arrows.add_css_class("linked");
        arrows.append(&previous);
        arrows.append(&next);
        row.append(&arrows);
        row.append(&label);
        bar.set_child(Some(&row));
        bar.connect_entry(&entry);
        bar.set_show_close_button(true);
        entry.connect_search_changed(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |_| page.run_search()
        ));
        entry.connect_activate(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |_| page.find_next(1)
        ));
        entry.connect_next_match(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |_| page.find_next(1)
        ));
        entry.connect_previous_match(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |_| page.find_next(-1)
        ));
        entry.connect_stop_search(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |_| page.close_search()
        ));
        let keys = gtk::EventControllerKey::new();
        keys.connect_key_pressed(glib::clone!(
            #[weak(rename_to = page)]
            self,
            #[upgrade_or]
            glib::Propagation::Proceed,
            move |_, key, _, modifiers| {
                if matches!(key, gdk::Key::Return | gdk::Key::KP_Enter) && modifiers.contains(gdk::ModifierType::SHIFT_MASK) {
                    page.find_next(-1);
                    return glib::Propagation::Stop;
                }
                glib::Propagation::Proceed
            }
        ));
        entry.add_controller(keys);
        previous.connect_clicked(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |_| page.find_next(-1)
        ));
        next.connect_clicked(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |_| page.find_next(1)
        ));
        bar.connect_search_mode_enabled_notify(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |bar| {
                if !bar.is_search_mode() {
                    page.clear_search();
                }
            }
        ));
        (bar, entry, label)
    }

    fn format_bar(&self) -> gtk::Widget {
        let bar = gtk::Box::new(gtk::Orientation::Horizontal, 2);
        bar.add_css_class("md-format-bar");
        bar.set_halign(gtk::Align::Center);
        let groups: [&[(&str, &str, &str, bool)]; 4] = [
            &[("Título 1", "heading1", "H1", false), ("Título 2", "heading2", "H2", false), ("Título 3", "heading3", "H3", false)],
            &[
                ("Negrita", "bold", "format-text-bold-symbolic", true),
                ("Cursiva", "italic", "format-text-italic-symbolic", true),
                ("Tachado", "strikethrough", "format-text-strikethrough-symbolic", true),
                ("Código en línea", "code", "</>", false),
                ("Enlace", "link", "insert-link-symbolic", true),
            ],
            &[
                ("Lista", "bullet-list", "view-list-bullet-symbolic", true),
                ("Lista numerada", "numbered-list", "view-list-ordered-symbolic", true),
                ("Lista de tareas", "task-list", "checkbox-checked-symbolic", true),
                ("Cita", "quote", "❝", false),
            ],
            &[("Bloque de código", "code-block", "{ }", false), ("Tabla", "table", "▦", false), ("Separador", "rule", "—", false)],
        ];
        for (index, group) in groups.iter().enumerate() {
            if index > 0 {
                let separator = gtk::Separator::new(gtk::Orientation::Vertical);
                separator.set_margin_start(6);
                separator.set_margin_end(6);
                separator.set_margin_top(6);
                separator.set_margin_bottom(6);
                bar.append(&separator);
            }
            for (title, action, face, icon) in group.iter() {
                let button = if *icon { gtk::Button::from_icon_name(face) } else { gtk::Button::with_label(face) };
                button.add_css_class("flat");
                button.set_tooltip_text(Some(&t(title)));
                button.set_action_name(Some("win.format"));
                button.set_action_target_value(Some(&action.to_variant()));
                button.set_can_focus(false);
                bar.append(&button);
            }
        }
        bar.upcast()
    }

    // MARK: State

    pub fn kind(&self) -> Kind {
        self.imp().kind.get()
    }

    pub fn path(&self) -> Option<PathBuf> {
        self.imp().path.borrow().clone()
    }

    pub fn mode(&self) -> Mode {
        self.imp().mode.get()
    }

    pub fn is_dirty(&self) -> bool {
        self.imp().dirty.get()
    }

    pub fn title(&self) -> String {
        match self.kind() {
            Kind::File => self
                .path()
                .and_then(|p| p.file_name().map(|n| n.to_string_lossy().to_string()))
                .unwrap_or_else(|| t("Sin título")),
            Kind::Welcome => t("Bienvenida"),
            Kind::Note => t("Nueva nota"),
            Kind::Pasted => t("Texto pegado"),
            Kind::Blank => t("Nueva pestaña"),
            Kind::Changelog => t("Novedades"),
        }
    }

    /// A tab that can take a new document instead of opening another tab.
    pub fn can_reuse(&self) -> bool {
        match self.kind() {
            Kind::Blank => true,
            Kind::Welcome => !self.is_dirty(),
            _ => false,
        }
    }

    pub fn outline(&self) -> Vec<OutlineItem> {
        self.imp().rendered.borrow().outline.clone()
    }

    pub fn current_heading(&self) -> Option<usize> {
        let h = self.imp().heading.get();
        (h >= 0).then_some(h as usize)
    }

    fn changed(&self) {
        self.update_footer();
        self.emit_by_name::<()>("state-changed", &[]);
    }

    // MARK: Loading

    fn load_text(&self, text: &str, kind: Kind, path: Option<PathBuf>) {
        let imp = self.imp();
        imp.loading.set(true);
        imp.kind.set(kind);
        let base = path.as_ref().and_then(|p| p.parent().map(Path::to_path_buf));
        *self.editor().base_dir.borrow_mut() = base;
        *imp.path.borrow_mut() = path;
        imp.dirty.set(false);
        imp.remote_allowed.set(prefs::with(|p| p.always_load_remote_images));
        let buffer = self.buffer();
        buffer.begin_irreversible_action();
        buffer.set_text(text);
        buffer.end_irreversible_action();
        buffer.place_cursor(&buffer.start_iter());
        imp.loading.set(false);
        imp.heading.set(-1);
        self.set_banner(BannerKind::None);
        imp.stack.get().unwrap().set_visible_child_name(if kind == Kind::Blank { "blank" } else { "document" });
        imp.footer.get().unwrap().set_visible(kind != Kind::Blank);
        self.editor().restyle();
        self.render_now();
        self.scroll_both_to_top();
        self.watch();
        self.changed();
    }

    fn scroll_both_to_top(&self) {
        let imp = self.imp();
        imp.reader_scroll.get().unwrap().vadjustment().set_value(0.0);
        imp.editor_scroll.get().unwrap().vadjustment().set_value(0.0);
    }

    pub fn make_blank(&self) {
        self.load_text("", Kind::Blank, None);
    }

    pub fn load_welcome(&self) {
        self.load_text(welcome_text(), Kind::Welcome, None);
        self.set_mode(Mode::Read);
    }

    pub fn load_changelog(&self) {
        self.load_text(include_str!("../../CHANGELOG.md"), Kind::Changelog, None);
        self.set_mode(Mode::Read);
    }

    pub fn new_note(&self) {
        self.load_text("", Kind::Note, None);
        self.set_mode(Mode::Edit);
        self.editor().view.grab_focus();
    }

    pub fn load_pasted(&self, text: &str) {
        self.load_text(text, Kind::Pasted, None);
        self.set_mode(Mode::Read);
    }

    pub fn open_file(&self, path: &Path) -> Result<(), String> {
        let text = read_file(path)?;
        let path = std::fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf());
        *self.imp().last_written.borrow_mut() = Some(text.clone());
        self.load_text(&text, Kind::File, Some(path.clone()));
        if self.mode() != Mode::Read && self.mode() != Mode::Split {
            self.set_mode(Mode::Read);
        }
        prefs::add_recent(&path);
        Ok(())
    }

    fn text_changed(&self) {
        let imp = self.imp();
        if imp.loading.get() {
            return;
        }
        if !imp.dirty.get() {
            imp.dirty.set(true);
            self.changed();
        }
        self.schedule_render();
        if imp.kind.get() == Kind::File {
            self.schedule_save();
        }
        self.update_footer();
    }

    // MARK: Rendering

    pub fn apply_prefs(&self) {
        let imp = self.imp();
        let dark = adw::StyleManager::default().is_dark();
        let palette = palette(dark);
        *imp.palette.borrow_mut() = Some(palette.clone());
        imp.reader_tags.get().unwrap().set_palette(&palette);
        self.reader().set_palette(&palette);
        self.editor().set_palette(&palette);
        let column = prefs::with(|p| p.column_width());
        imp.reader_clamp.get().unwrap().set_maximum_size(column);
        imp.reader_clamp.get().unwrap().set_tightening_threshold(column);
        let editor_column = if matches!(self.mode(), Mode::Source | Mode::Split) { column.saturating_add(60) } else { column };
        imp.editor_clamp.get().unwrap().set_maximum_size(editor_column);
        imp.editor_clamp.get().unwrap().set_tightening_threshold(editor_column);
        let size = prefs::with(|p| p.font_size);
        let live = self.mode() != Mode::Source && self.mode() != Mode::Split;
        self.editor().configure(live, size);
        self.editor().restyle();
        self.render_now();
    }

    fn schedule_render(&self) {
        let imp = self.imp();
        if let Some(id) = imp.render_timer.borrow_mut().take() {
            id.remove();
        }
        let delay = if self.mode().shows_reader() { 160 } else { 450 };
        let weak = self.downgrade();
        let id = glib::timeout_add_local_once(Duration::from_millis(delay), move || {
            if let Some(page) = weak.upgrade() {
                page.imp().render_timer.borrow_mut().take();
                page.render_now();
            }
        });
        *imp.render_timer.borrow_mut() = Some(id);
    }

    fn compute(&self) -> Rendered {
        let dark = adw::StyleManager::default().is_dark();
        let size = prefs::with(|p| p.font_size);
        let column = prefs::with(|p| p.column_width());
        let mermaid = move |code: &str| -> MermaidState { mermaid::state(code, dark) };
        let base = self.path().and_then(|p| p.parent().map(Path::to_path_buf));
        let mut renderer = Renderer::new(size, base.as_deref());
        renderer.dark = dark;
        renderer.max_image_width = (column as f32).min(1200.0);
        renderer.mermaid = Some(&mermaid);
        renderer.render(&self.source())
    }

    /// Renders the source; the reader is rebuilt only while it is visible.
    pub fn render_now(&self) {
        let imp = self.imp();
        let rendered = Rc::new(self.compute());
        let outline_changed = imp.rendered.borrow().outline != rendered.outline;
        *imp.rendered.borrow_mut() = rendered;
        if self.mode().shows_reader() {
            self.show_reader();
        } else {
            imp.reader_stale.set(true);
        }
        let blocked = if imp.remote_allowed.get() { 0 } else { imp.rendered.borrow().remote_images.len() };
        if blocked > 0 {
            self.set_banner(BannerKind::Remote);
        } else if self.banner_kind() == BannerKind::Remote {
            self.set_banner(BannerKind::None);
        }
        if outline_changed {
            self.emit_by_name::<()>("outline-changed", &[]);
        }
    }

    fn show_reader(&self) {
        let imp = self.imp();
        let reader = self.reader();
        let adjustment = imp.reader_scroll.get().unwrap().vadjustment();
        let keep = adjustment.value();
        let rendered = imp.rendered.borrow().clone();
        let weak = self.downgrade();
        let on_task: Rc<dyn Fn(usize)> = Rc::new(move |byte| {
            if let Some(page) = weak.upgrade() {
                page.toggle_task_at_byte(byte);
            }
        });
        let weak = self.downgrade();
        let on_link: Rc<dyn Fn(String)> = Rc::new(move |url| {
            if let Some(page) = weak.upgrade() {
                page.open_link(&url);
            }
        });
        let weak = self.downgrade();
        let on_remote_loaded: Rc<dyn Fn()> = Rc::new(move || {
            if let Some(page) = weak.upgrade() {
                page.schedule_render();
            }
        });
        let column = prefs::with(|p| p.column_width());
        let hooks = reader::Hooks {
            on_task,
            on_link,
            remote_allowed: imp.remote_allowed.get(),
            on_remote_loaded,
            max_image_width: (column as f32).min(1200.0),
        };
        reader::show(reader, imp.reader_tags.get().unwrap(), &rendered, &hooks);
        imp.reader_stale.set(false);
        // Keep the reading position while the text view lays out again.
        adjustment.set_value(keep);
        glib::idle_add_local_once(glib::clone!(
            #[weak]
            adjustment,
            move || adjustment.set_value(keep.min((adjustment.upper() - adjustment.page_size()).max(0.0)))
        ));
        if !imp.search_entry.get().unwrap().text().is_empty() && imp.search_bar.get().unwrap().is_search_mode() {
            self.run_search();
        }
    }

    fn toggle_task_at_byte(&self, byte: usize) {
        let source = self.source();
        let map = CharMap::new(&source);
        self.editor().toggle_task_at_char(map.char(byte));
        if let Some(id) = self.imp().render_timer.borrow_mut().take() {
            id.remove();
        }
        self.render_now();
    }

    // MARK: Modes

    pub fn set_mode(&self, mode: Mode) {
        let imp = self.imp();
        if self.kind() == Kind::Blank {
            return;
        }
        let previous = imp.mode.get();
        let anchor = self.source_position();
        imp.mode.set(mode);
        if matches!(mode, Mode::Edit | Mode::Source) {
            imp.last_edit_mode.set(mode);
        }
        let editor_scroll = imp.editor_scroll.get().unwrap();
        let reader_scroll = imp.reader_scroll.get().unwrap();
        editor_scroll.set_visible(mode != Mode::Read);
        reader_scroll.set_visible(mode.shows_reader());
        imp.format_bar.get().unwrap().set_reveal_child(matches!(mode, Mode::Edit | Mode::Source));
        if mode == Mode::Split {
            self.apply_split_ratio();
        }
        if previous != mode {
            self.apply_prefs_for_mode();
        }
        if mode.shows_reader() && imp.reader_stale.get() {
            self.show_reader();
        }
        if mode != Mode::Read {
            self.editor().view.grab_focus();
        } else {
            self.reader().grab_focus();
        }
        let weak = self.downgrade();
        glib::idle_add_local_once(move || {
            if let Some(page) = weak.upgrade() {
                page.restore_position(anchor);
            }
        });
        self.changed();
    }

    /// Places the split divider at the saved ratio once the pane has a width.
    fn apply_split_ratio(&self) {
        let paned = self.imp().paned.get().unwrap();
        let width = paned.width();
        if width > 0 {
            let ratio = prefs::with(|p| p.split_ratio);
            paned.set_position((width as f64 * ratio) as i32);
        }
    }

    fn apply_prefs_for_mode(&self) {
        let imp = self.imp();
        let column = prefs::with(|p| p.column_width());
        let editor_column = if matches!(self.mode(), Mode::Source | Mode::Split) { column.saturating_add(60) } else { column };
        imp.editor_clamp.get().unwrap().set_maximum_size(editor_column);
        imp.editor_clamp.get().unwrap().set_tightening_threshold(editor_column);
        let live = !matches!(self.mode(), Mode::Source | Mode::Split);
        self.editor().configure(live, prefs::with(|p| p.font_size));
    }

    pub fn toggle_editing(&self) {
        let mode = if self.mode() == Mode::Read { self.imp().last_edit_mode.get() } else { Mode::Read };
        self.set_mode(mode);
    }

    /// Byte offset in the source of what sits at the top of the visible view.
    fn source_position(&self) -> usize {
        let imp = self.imp();
        if self.mode() == Mode::Read {
            let rendered = imp.rendered.borrow();
            rendered.source_offset(self.reader().top_offset())
        } else {
            let source = self.source();
            CharMap::new(&source).byte(self.editor().view.top_offset())
        }
    }

    fn restore_position(&self, byte: usize) {
        if byte == 0 {
            return;
        }
        let imp = self.imp();
        let mode = self.mode();
        imp.syncing.set(true);
        if mode.shows_reader() {
            let offset = imp.rendered.borrow().rendered_offset(byte);
            self.reader().scroll_to_offset(offset, false);
        }
        if mode != Mode::Read {
            let source = self.source();
            let offset = CharMap::new(&source).char(byte);
            self.editor().view.scroll_to_offset(offset, false);
        }
        let weak = self.downgrade();
        glib::idle_add_local_once(move || {
            if let Some(page) = weak.upgrade() {
                page.imp().syncing.set(false);
            }
        });
    }

    fn reader_scrolled(&self) {
        let imp = self.imp();
        let adjustment = imp.reader_scroll.get().unwrap().vadjustment();
        self.update_progress(&adjustment);
        if self.mode().shows_reader() {
            let top = self.reader().offset_below_top(48);
            let index = imp.rendered.borrow().outline.iter().rposition(|o| o.start <= top).map_or(-1, |i| i as i32);
            self.set_heading(index);
        }
    }

    fn editor_scrolled(&self) {
        let imp = self.imp();
        if self.mode() == Mode::Read {
            return;
        }
        let source = self.source();
        let byte = CharMap::new(&source).byte(self.editor().view.top_offset());
        let probe = CharMap::new(&source).byte(self.editor().view.offset_below_top(48));
        if self.mode() != Mode::Split {
            let adjustment = imp.editor_scroll.get().unwrap().vadjustment();
            self.update_progress(&adjustment);
            let index = imp.rendered.borrow().outline.iter().rposition(|o| o.source <= probe).map_or(-1, |i| i as i32);
            self.set_heading(index);
        }
        if self.mode() == Mode::Split && !imp.syncing.get() {
            imp.syncing.set(true);
            let editor_adjustment = imp.editor_scroll.get().unwrap().vadjustment();
            let reader_adjustment = imp.reader_scroll.get().unwrap().vadjustment();
            if editor_adjustment.value() <= 0.5 {
                reader_adjustment.set_value(0.0);
            } else if editor_adjustment.value() >= editor_adjustment.upper() - editor_adjustment.page_size() - 0.5 {
                reader_adjustment.set_value(reader_adjustment.upper() - reader_adjustment.page_size());
            } else {
                let offset = imp.rendered.borrow().rendered_offset(byte);
                self.reader().scroll_to_offset(offset, false);
            }
            let weak = self.downgrade();
            glib::idle_add_local_once(move || {
                if let Some(page) = weak.upgrade() {
                    page.imp().syncing.set(false);
                }
            });
        }
    }

    fn set_heading(&self, index: i32) {
        if self.imp().heading.get() != index {
            self.imp().heading.set(index);
            self.emit_by_name::<()>("heading-changed", &[]);
        }
    }

    fn update_progress(&self, adjustment: &gtk::Adjustment) {
        let range = adjustment.upper() - adjustment.page_size();
        let label = self.imp().progress.get().unwrap();
        if range > 1.0 {
            label.set_text(&format!("{}%", ((adjustment.value() / range) * 100.0).round() as i32));
        } else {
            label.set_text("");
        }
    }

    pub fn navigate_to(&self, index: usize) {
        let imp = self.imp();
        let Some(item) = imp.rendered.borrow().outline.get(index).cloned() else { return };
        if self.mode().shows_reader() {
            self.reader().scroll_to_offset(item.start, true);
        }
        if self.mode() != Mode::Read {
            let source = self.source();
            let offset = CharMap::new(&source).char(item.source);
            let buffer = self.buffer();
            buffer.place_cursor(&buffer.iter_at_offset(offset as i32));
            if self.mode() != Mode::Split {
                self.editor().view.scroll_to_offset(offset, true);
            }
        }
        self.set_heading(index as i32);
    }

    pub fn navigate_relative(&self, delta: i32) {
        let count = self.imp().rendered.borrow().outline.len() as i32;
        if count == 0 {
            return;
        }
        let current = self.imp().heading.get();
        let next = (current + delta).clamp(0, count - 1);
        self.navigate_to(next as usize);
    }

    // MARK: Links

    fn open_link(&self, url: &str) {
        if let Some(anchor) = url.strip_prefix("x-mdlite-anchor:") {
            let offset = self.imp().rendered.borrow().anchor(anchor);
            if let Some(offset) = offset {
                if self.mode() == Mode::Read || self.mode() == Mode::Split {
                    self.reader().scroll_to_offset(offset, true);
                }
            }
            return;
        }
        if url.starts_with("file:") {
            let file = gio::File::for_uri(url.split('#').next().unwrap_or(url));
            if let Some(path) = file.path() {
                let ext = path.extension().map(|e| e.to_string_lossy().to_lowercase()).unwrap_or_default();
                if ["md", "markdown", "mdown", "mkd", "txt"].contains(&ext.as_str()) && path.is_file() {
                    self.emit_by_name::<()>("open-path", &[&path.to_string_lossy().to_string(), &true]);
                    return;
                }
            }
        }
        let launcher = gtk::UriLauncher::new(url);
        let window = self.root().and_downcast::<gtk::Window>();
        launcher.launch(window.as_ref(), None::<&gio::Cancellable>, |_| {});
    }

    // MARK: Banner

    fn banner_kind(&self) -> BannerKind {
        match self.imp().banner_kind.get() {
            1 => BannerKind::Remote,
            2 => BannerKind::Changed,
            _ => BannerKind::None,
        }
    }

    fn set_banner(&self, kind: BannerKind) {
        let imp = self.imp();
        let banner = imp.banner.get().unwrap();
        imp.banner_kind.set(match kind {
            BannerKind::None => 0,
            BannerKind::Remote => 1,
            BannerKind::Changed => 2,
        });
        match kind {
            BannerKind::None => banner.set_revealed(false),
            BannerKind::Remote => {
                let count = imp.rendered.borrow().remote_images.len();
                banner.set_title(&tf("%d imágenes remotas bloqueadas para proteger tu privacidad.", &[&count.to_string()]));
                banner.set_button_label(Some(&t("Mostrar")));
                banner.set_revealed(true);
            }
            BannerKind::Changed => {
                banner.set_title(&t("El archivo cambió en el disco."));
                banner.set_button_label(Some(&t("Volver a cargar")));
                banner.set_revealed(true);
            }
        }
    }

    fn banner_action(&self) {
        match self.banner_kind() {
            BannerKind::Remote => {
                self.imp().remote_allowed.set(true);
                self.set_banner(BannerKind::None);
                self.render_now();
            }
            BannerKind::Changed => {
                self.set_banner(BannerKind::None);
                self.reload_from_disk();
            }
            BannerKind::None => {}
        }
    }

    // MARK: Footer

    fn update_footer(&self) {
        let imp = self.imp();
        let source = self.source();
        let words = source.split_whitespace().filter(|w| w.chars().any(char::is_alphanumeric)).count();
        let minutes = (words as f64 / 220.0).ceil().max(1.0) as usize;
        imp.stats.get().unwrap().set_text(&format!("{} {} · {} {}", group(words), t("palabras"), minutes, t("min de lectura")));
        let status = match self.kind() {
            Kind::File if imp.saving.get() => t("Guardando…"),
            Kind::File if imp.dirty.get() => t("Guardando…"),
            Kind::File => t("Guardado"),
            Kind::Note | Kind::Pasted if imp.dirty.get() || self.kind() == Kind::Pasted => t("Sin guardar · Ctrl+S"),
            Kind::Note => t("Este documento aún no está guardado."),
            _ => String::new(),
        };
        imp.status.get().unwrap().set_text(&status);
    }

    // MARK: Saving

    fn schedule_save(&self) {
        let imp = self.imp();
        if let Some(id) = imp.save_timer.borrow_mut().take() {
            id.remove();
        }
        let weak = self.downgrade();
        let id = glib::timeout_add_local_once(Duration::from_millis(900), move || {
            if let Some(page) = weak.upgrade() {
                page.imp().save_timer.borrow_mut().take();
                page.write_now();
            }
        });
        *imp.save_timer.borrow_mut() = Some(id);
    }

    /// Writes a file-backed document now. Returns false when it failed.
    fn write_now(&self) -> bool {
        let imp = self.imp();
        let Some(path) = self.path() else { return false };
        let text = self.source();
        imp.saving.set(true);
        let result = write_file(&path, &text);
        imp.saving.set(false);
        match result {
            Ok(()) => {
                *imp.last_written.borrow_mut() = Some(text);
                imp.dirty.set(false);
                imp.saved_at.set(Some(std::time::Instant::now()));
                self.changed();
                true
            }
            Err(error) => {
                self.alert(&t("No se pudo guardar"), &error.to_string());
                false
            }
        }
    }

    /// Saves without asking when the document has a file; work in progress never gets lost on close.
    pub fn preserve_unsaved_work(&self) {
        if let Some(id) = self.imp().save_timer.borrow_mut().take() {
            id.remove();
        }
        if self.kind() == Kind::File && self.is_dirty() {
            self.write_now();
        }
    }

    pub fn save(&self) {
        if self.kind() == Kind::File && self.path().is_some() {
            if let Some(id) = self.imp().save_timer.borrow_mut().take() {
                id.remove();
            }
            self.write_now();
        } else {
            self.save_as(|_| {});
        }
    }

    fn suggested_name(&self) -> String {
        match self.kind() {
            Kind::File => self.title(),
            _ => {
                let source = self.source();
                let heading = source
                    .lines()
                    .find_map(|l| l.trim_start().strip_prefix('#').map(|h| h.trim_start_matches('#').trim().to_string()))
                    .filter(|h| !h.is_empty());
                let mut name = heading.unwrap_or_else(|| self.title());
                name.retain(|c| !"/\\:*?\"<>|".contains(c));
                format!("{name}.md")
            }
        }
    }

    pub fn save_as(&self, done: impl FnOnce(bool) + 'static) {
        let dialog = gtk::FileDialog::new();
        dialog.set_title(&t("Guardar Markdown"));
        dialog.set_initial_name(Some(&self.suggested_name()));
        if let Some(folder) = self.path().and_then(|p| p.parent().map(Path::to_path_buf)) {
            dialog.set_initial_folder(Some(&gio::File::for_path(folder)));
        }
        dialog.set_filters(Some(&markdown_filters()));
        let window = self.root().and_downcast::<gtk::Window>();
        dialog.save(window.as_ref(), None::<&gio::Cancellable>, glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |result| {
                let Some(path) = result.ok().and_then(|f| f.path()) else {
                    done(false);
                    return;
                };
                let text = page.source();
                match write_file(&path, &text) {
                    Ok(()) => {
                        let imp = page.imp();
                        *imp.last_written.borrow_mut() = Some(text);
                        imp.kind.set(Kind::File);
                        *page.editor().base_dir.borrow_mut() = path.parent().map(Path::to_path_buf);
                        *imp.path.borrow_mut() = Some(path.clone());
                        imp.dirty.set(false);
                        prefs::add_recent(&path);
                        page.watch();
                        page.render_now();
                        page.changed();
                        done(true);
                    }
                    Err(error) => {
                        page.alert(&t("No se pudo guardar"), &error.to_string());
                        done(false);
                    }
                }
            }
        ));
    }

    /// Asks before closing a document whose changes would be lost. `done(true)` closes it.
    pub fn confirm_close(&self, done: impl FnOnce(bool) + 'static) {
        self.preserve_unsaved_work();
        let unsaved = matches!(self.kind(), Kind::Note | Kind::Pasted | Kind::Welcome) && self.is_dirty() && !self.source().trim().is_empty();
        if !unsaved {
            done(true);
            return;
        }
        let dialog = adw::AlertDialog::new(
            Some(&tf("¿Guardar los cambios de “%@”?", &[&self.title()])),
            Some(&t("Si no los guardas, se perderán.")),
        );
        dialog.add_responses(&[("cancel", &t("Cancelar")), ("discard", &t("No guardar")), ("save", &t("Guardar…"))]);
        dialog.set_response_appearance("discard", adw::ResponseAppearance::Destructive);
        dialog.set_response_appearance("save", adw::ResponseAppearance::Suggested);
        dialog.set_default_response(Some("save"));
        dialog.set_close_response("cancel");
        let done = Rc::new(RefCell::new(Some(done)));
        dialog.choose(Some(self), None::<&gio::Cancellable>, glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |response| {
                let finish = move |value: bool| {
                    if let Some(done) = done.borrow_mut().take() {
                        done(value);
                    }
                };
                match response.as_str() {
                    "discard" => finish(true),
                    "save" => page.save_as(finish),
                    _ => finish(false),
                }
            }
        ));
    }

    pub fn duplicate(&self) {
        let Some(path) = self.path() else {
            self.save_as(|_| {});
            return;
        };
        let target = duplicate_path(&path);
        match write_file(&target, &self.source()) {
            Ok(()) => self.emit_by_name::<()>("open-path", &[&target.to_string_lossy().to_string(), &true]),
            Err(error) => self.alert(&t("No se pudo guardar"), &error.to_string()),
        }
    }

    pub fn save_copy(&self) {
        let dialog = gtk::FileDialog::new();
        dialog.set_title(&t("Guardar una copia como…"));
        dialog.set_initial_name(Some(&self.suggested_name()));
        dialog.set_filters(Some(&markdown_filters()));
        let window = self.root().and_downcast::<gtk::Window>();
        let text = self.source();
        dialog.save(window.as_ref(), None::<&gio::Cancellable>, glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |result| {
                if let Some(path) = result.ok().and_then(|f| f.path()) {
                    if let Err(error) = write_file(&path, &text) {
                        page.alert(&t("No se pudo guardar"), &error.to_string());
                    }
                }
            }
        ));
    }

    // MARK: Watching the file

    fn watch(&self) {
        let imp = self.imp();
        if let Some(monitor) = imp.monitor.borrow_mut().take() {
            monitor.cancel();
        }
        let Some(path) = self.path() else { return };
        let Ok(monitor) = gio::File::for_path(&path).monitor_file(gio::FileMonitorFlags::WATCH_MOVES, None::<&gio::Cancellable>) else {
            return;
        };
        monitor.connect_changed(glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |_, _, _, event| {
                if matches!(
                    event,
                    gio::FileMonitorEvent::ChangesDoneHint | gio::FileMonitorEvent::Created | gio::FileMonitorEvent::Changed | gio::FileMonitorEvent::MovedIn | gio::FileMonitorEvent::Renamed
                ) {
                    page.schedule_external_reload();
                }
            }
        ));
        *imp.monitor.borrow_mut() = Some(monitor);
    }

    fn schedule_external_reload(&self) {
        let imp = self.imp();
        if let Some(id) = imp.reload_timer.borrow_mut().take() {
            id.remove();
        }
        let weak = self.downgrade();
        let id = glib::timeout_add_local_once(Duration::from_millis(350), move || {
            if let Some(page) = weak.upgrade() {
                page.imp().reload_timer.borrow_mut().take();
                page.external_change();
            }
        });
        *imp.reload_timer.borrow_mut() = Some(id);
    }

    fn external_change(&self) {
        let Some(path) = self.path() else { return };
        let Ok(text) = read_file(&path) else { return };
        if self.imp().last_written.borrow().as_deref() == Some(text.as_str()) || text == self.source() {
            return;
        }
        if self.is_dirty() {
            self.set_banner(BannerKind::Changed);
        } else {
            self.replace_keeping_position(&text);
        }
    }

    fn replace_keeping_position(&self, text: &str) {
        let imp = self.imp();
        let buffer = self.buffer();
        let cursor = buffer.iter_at_mark(&buffer.get_insert()).offset();
        let reader_value = imp.reader_scroll.get().unwrap().vadjustment().value();
        let editor_value = imp.editor_scroll.get().unwrap().vadjustment().value();
        imp.loading.set(true);
        // Delete and insert as one step, so the reload can be undone like an edit.
        buffer.begin_user_action();
        let (mut start, mut end) = buffer.bounds();
        buffer.delete(&mut start, &mut end);
        buffer.insert(&mut start, text);
        buffer.end_user_action();
        buffer.place_cursor(&buffer.iter_at_offset(cursor));
        imp.loading.set(false);
        *imp.last_written.borrow_mut() = Some(text.to_string());
        imp.dirty.set(false);
        self.editor().restyle();
        self.render_now();
        let weak = self.downgrade();
        glib::idle_add_local_once(move || {
            if let Some(page) = weak.upgrade() {
                page.imp().reader_scroll.get().unwrap().vadjustment().set_value(reader_value);
                page.imp().editor_scroll.get().unwrap().vadjustment().set_value(editor_value);
            }
        });
        self.changed();
    }

    fn reload_from_disk(&self) {
        let Some(path) = self.path() else { return };
        match read_file(&path) {
            Ok(text) => self.replace_keeping_position(&text),
            Err(error) => self.alert(&t("No se pudo leer el archivo"), &error),
        }
    }

    pub fn reload(&self) {
        if self.path().is_none() {
            return;
        }
        if !self.is_dirty() {
            self.reload_from_disk();
            return;
        }
        let dialog = adw::AlertDialog::new(Some(&t("¿Descartar tus cambios y volver a cargar el archivo?")), None);
        dialog.add_responses(&[("cancel", &t("Cancelar")), ("reload", &t("Volver a cargar"))]);
        dialog.set_response_appearance("reload", adw::ResponseAppearance::Destructive);
        dialog.set_close_response("cancel");
        dialog.choose(Some(self), None::<&gio::Cancellable>, glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |response| {
                if response == "reload" {
                    page.reload_from_disk();
                }
            }
        ));
    }

    // MARK: Format

    pub fn format(&self, action: FormatAction) {
        if self.kind() == Kind::Blank {
            return;
        }
        if self.mode() == Mode::Read {
            self.set_mode(self.imp().last_edit_mode.get());
        }
        self.editor().perform(action);
    }

    // MARK: Find

    pub fn find(&self) {
        let imp = self.imp();
        let bar = imp.search_bar.get().unwrap();
        bar.set_search_mode(true);
        let entry = imp.search_entry.get().unwrap();
        // Prefill with the selection, like most editors.
        let view: gtk::TextView = if self.mode() == Mode::Read { self.reader().clone().upcast() } else { self.editor().view.clone().upcast() };
        if let Some((a, b)) = view.buffer().selection_bounds() {
            let text = view.buffer().text(&a, &b, false);
            if !text.contains('\n') && text.len() < 80 {
                entry.set_text(&text);
            }
        }
        entry.grab_focus();
        entry.select_region(0, -1);
    }

    fn search_view(&self) -> gtk::TextView {
        if self.mode() == Mode::Read { self.reader().clone().upcast() } else { self.editor().view.clone().upcast() }
    }

    fn clear_search(&self) {
        for view in [self.reader().clone().upcast::<gtk::TextView>(), self.editor().view.clone().upcast()] {
            let buffer = view.buffer();
            let (s, e) = buffer.bounds();
            buffer.remove_tag_by_name("md-search", &s, &e);
            buffer.remove_tag_by_name("md-search-current", &s, &e);
        }
        self.imp().matches.borrow_mut().clear();
        self.imp().search_label.get().unwrap().set_text("");
    }

    /// Closes the find bar when it is open. Returns whether it was.
    pub fn close_search_if_open(&self) -> bool {
        if self.imp().search_bar.get().unwrap().is_search_mode() {
            self.close_search();
            return true;
        }
        false
    }

    fn close_search(&self) {
        self.imp().search_bar.get().unwrap().set_search_mode(false);
        self.clear_search();
        self.search_view().grab_focus();
    }

    fn run_search(&self) {
        let imp = self.imp();
        self.clear_search();
        let query = imp.search_entry.get().unwrap().text().to_string();
        if query.is_empty() {
            return;
        }
        let view = self.search_view();
        let buffer = view.buffer();
        let (s, e) = buffer.bounds();
        let text = buffer.slice(&s, &e, true).to_string();
        let haystack: Vec<char> = text.chars().map(fold).collect();
        let needle: Vec<char> = query.chars().map(fold).collect();
        let mut matches = Vec::new();
        if needle.len() <= haystack.len() {
            let mut i = 0;
            while i + needle.len() <= haystack.len() {
                if haystack[i..i + needle.len()] == needle[..] {
                    matches.push((i, i + needle.len()));
                    i += needle.len();
                } else {
                    i += 1;
                }
            }
        }
        for (a, b) in &matches {
            buffer.apply_tag_by_name("md-search", &buffer.iter_at_offset(*a as i32), &buffer.iter_at_offset(*b as i32));
        }
        let cursor = buffer.iter_at_mark(&buffer.get_insert()).offset() as usize;
        let top = if self.mode() == Mode::Read { self.reader().top_offset() } else { cursor };
        let first = matches.iter().position(|(a, _)| *a >= top).unwrap_or(0);
        *imp.matches.borrow_mut() = matches;
        imp.current_match.set(first);
        self.show_match();
    }

    pub fn find_next(&self, delta: i32) {
        let imp = self.imp();
        if !imp.search_bar.get().unwrap().is_search_mode() {
            self.find();
            return;
        }
        let count = imp.matches.borrow().len();
        if count == 0 {
            return;
        }
        let current = imp.current_match.get() as i32;
        imp.current_match.set(((current + delta).rem_euclid(count as i32)) as usize);
        self.show_match();
    }

    fn show_match(&self) {
        let imp = self.imp();
        let matches = imp.matches.borrow();
        let label = imp.search_label.get().unwrap();
        if matches.is_empty() {
            label.set_text(&t("Sin coincidencias"));
            return;
        }
        let index = imp.current_match.get().min(matches.len() - 1);
        label.set_text(&tf("%d de %d", &[&(index + 1).to_string(), &matches.len().to_string()]));
        let view = self.search_view();
        let buffer = view.buffer();
        let (s, e) = buffer.bounds();
        buffer.remove_tag_by_name("md-search-current", &s, &e);
        let (a, b) = matches[index];
        let start = buffer.iter_at_offset(a as i32);
        let end = buffer.iter_at_offset(b as i32);
        buffer.apply_tag_by_name("md-search-current", &start, &end);
        if view.is_editable() {
            buffer.select_range(&start, &end);
        }
        let mut target = start;
        view.scroll_to_iter(&mut target, 0.2, true, 0.0, 0.35);
    }

    // MARK: Export and print

    pub fn export_html(&self) {
        let dialog = gtk::FileDialog::new();
        dialog.set_title(&t("Exportar HTML"));
        let base = self.suggested_name();
        dialog.set_initial_name(Some(&format!("{}.html", base.trim_end_matches(".md"))));
        let window = self.root().and_downcast::<gtk::Window>();
        let page_html = export::page(&self.source(), &self.title(), crate::i18n::language(), false);
        dialog.save(window.as_ref(), None::<&gio::Cancellable>, glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |result| {
                if let Some(path) = result.ok().and_then(|f| f.path()) {
                    match std::fs::write(&path, page_html) {
                        Ok(()) => page.emit_by_name::<()>("toast", &[&t("Exportado")]),
                        Err(error) => page.alert(&t("No se pudo exportar"), &error.to_string()),
                    }
                }
            }
        ));
    }

    /// A hidden web view holding the printable page. Remote images stay blocked unless the
    /// reader allowed them for this document.
    fn print_view(&self, ready: impl FnOnce(&webkit6::WebView) + 'static) {
        let manager = webkit6::UserContentManager::new();
        let session = webkit6::NetworkSession::new_ephemeral();
        let view = webkit6::WebView::builder().user_content_manager(&manager).network_session(&session).build();
        let html = export::page(&self.source(), &self.title(), crate::i18n::language(), true);
        let base = self.path().and_then(|p| p.parent().map(|d| crate::markdown::render::file_uri(d) + "/"));
        let ready = RefCell::new(Some(ready));
        view.connect_load_changed(move |view, event| {
            if event == webkit6::LoadEvent::Finished {
                if let Some(ready) = ready.borrow_mut().take() {
                    ready(view);
                }
            }
        });
        let load = glib::clone!(
            #[weak]
            view,
            move || view.load_html(&html, base.as_deref())
        );
        if self.imp().remote_allowed.get() {
            load();
        } else {
            mermaid::block_network(&manager, load);
        }
        *self.imp().print_view.borrow_mut() = Some(view);
    }

    pub fn export_pdf(&self) {
        let dialog = gtk::FileDialog::new();
        dialog.set_title(&t("Exportar PDF"));
        let base = self.suggested_name();
        dialog.set_initial_name(Some(&format!("{}.pdf", base.trim_end_matches(".md"))));
        let window = self.root().and_downcast::<gtk::Window>();
        dialog.save(window.as_ref(), None::<&gio::Cancellable>, glib::clone!(
            #[weak(rename_to = page)]
            self,
            move |result| {
                let Some(file) = result.ok() else { return };
                page.export_pdf_to(&file.uri());
            }
        ));
    }

    /// Prints the document to a PDF at `uri` without a dialog.
    pub fn export_pdf_to(&self, uri: &str) {
        let uri = uri.to_string();
        let weak = self.downgrade();
        self.print_view(move |view| {
            let operation = webkit6::PrintOperation::new(view);
            let settings = gtk::PrintSettings::new();
            settings.set_printer("Print to File");
            settings.set(gtk::PRINT_SETTINGS_OUTPUT_FILE_FORMAT, Some("pdf"));
            settings.set(gtk::PRINT_SETTINGS_OUTPUT_URI, Some(&uri));
            operation.set_print_settings(&settings);
            operation.connect_finished(move |_| {
                if let Some(page) = weak.upgrade() {
                    page.imp().print_view.borrow_mut().take();
                    page.emit_by_name::<()>("toast", &[&t("Exportado")]);
                }
            });
            operation.connect_failed(|_, error| eprintln!("PDF export failed: {error}"));
            operation.print();
        });
    }

    pub fn print(&self) {
        let weak = self.downgrade();
        self.print_view(move |view| {
            let Some(page) = weak.upgrade() else { return };
            let operation = webkit6::PrintOperation::new(view);
            let window = page.root().and_downcast::<gtk::Window>();
            operation.connect_finished(glib::clone!(
                #[weak]
                page,
                move |_| {
                    page.imp().print_view.borrow_mut().take();
                }
            ));
            operation.run_dialog(window.as_ref());
        });
    }

    /// Development aid: types text into the editor as keystrokes would, Return included.
    #[cfg(debug_assertions)]
    pub fn debug_type(&self, text: &str) {
        if self.mode() == Mode::Read {
            self.set_mode(Mode::Edit);
        }
        self.editor().debug_type(text);
    }

    /// Development aid for screenshots: scrolls the visible view to a fraction of its height.
    #[cfg(debug_assertions)]
    pub fn debug_scroll(&self, fraction: f64) {
        let imp = self.imp();
        let scroll = if self.mode() == Mode::Read { imp.reader_scroll.get() } else { imp.editor_scroll.get() };
        if let Some(scroll) = scroll {
            let adjustment = scroll.vadjustment();
            adjustment.set_value(fraction * (adjustment.upper() - adjustment.page_size()));
        }
    }

    fn alert(&self, title: &str, body: &str) {
        let dialog = adw::AlertDialog::new(Some(title), Some(body));
        dialog.add_response("ok", &t("Entendido"));
        dialog.present(Some(self));
    }
}

fn scroller(view: &MdTextView) -> (gtk::ScrolledWindow, adw::ClampScrollable) {
    let scroll = gtk::ScrolledWindow::new();
    scroll.set_hscrollbar_policy(gtk::PolicyType::Never);
    scroll.set_vexpand(true);
    scroll.set_hexpand(true);
    let clamp = adw::ClampScrollable::new();
    clamp.set_maximum_size(780);
    clamp.set_tightening_threshold(780);
    clamp.set_child(Some(view));
    view.set_margin_start(32);
    view.set_margin_end(32);
    scroll.set_child(Some(&clamp));
    (scroll, clamp)
}

fn fold(c: char) -> char {
    let mut lower = c.to_lowercase();
    match (lower.next(), lower.next()) {
        (Some(l), None) => l,
        _ => c,
    }
}

fn group(n: usize) -> String {
    let digits = n.to_string();
    let mut out = String::new();
    for (i, c) in digits.chars().enumerate() {
        if i > 0 && (digits.len() - i) % 3 == 0 {
            out.push(if crate::i18n::language() == "es" { '.' } else { ',' });
        }
        out.push(c);
    }
    out
}

pub fn markdown_filters() -> gio::ListStore {
    let filters = gio::ListStore::new::<gtk::FileFilter>();
    let markdown = gtk::FileFilter::new();
    markdown.set_name(Some(&t("Archivos Markdown")));
    for pattern in ["*.md", "*.markdown", "*.mdown", "*.mkd", "*.txt"] {
        markdown.add_pattern(pattern);
    }
    markdown.add_mime_type("text/markdown");
    filters.append(&markdown);
    let all = gtk::FileFilter::new();
    all.set_name(Some(&t("Todos los archivos")));
    all.add_pattern("*");
    filters.append(&all);
    filters
}

/// "name copy.md", "name copy 2.md", … next to the original.
pub fn duplicate_path(path: &Path) -> PathBuf {
    let folder = path.parent().map(Path::to_path_buf).unwrap_or_default();
    let base = path.file_stem().map(|s| s.to_string_lossy().to_string()).unwrap_or_default();
    let ext = path.extension().map(|e| e.to_string_lossy().to_string()).unwrap_or_else(|| "md".into());
    let word = t("copia");
    let mut candidate = folder.join(format!("{base} {word}.{ext}"));
    let mut number = 2;
    while candidate.exists() {
        candidate = folder.join(format!("{base} {word} {number}.{ext}"));
        number += 1;
    }
    candidate
}
