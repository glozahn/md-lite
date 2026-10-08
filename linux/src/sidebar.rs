//! The sidebar: the document outline, the working folder as a tree, favorites and recent files.

use crate::i18n::t;
use crate::markdown::render::OutlineItem;
use crate::prefs;
use adw::prelude::*;
use gtk::{gdk, gio, glib};
use std::cell::{Cell, RefCell};
use std::path::{Path, PathBuf};
use std::rc::Rc;

#[derive(Clone, Debug)]
pub struct FileNode {
    pub name: String,
    pub path: PathBuf,
    pub dir: bool,
    pub children: Vec<FileNode>,
}

const SKIPPED: &[&str] = &[
    "node_modules", ".git", ".build", "build", "dist", "DerivedData", "Pods", ".next", "target", "vendor", ".venv", "venv",
    "__pycache__", ".swiftpm", "Carthage", "bin", ".cache", ".flatpak-builder",
];
pub const MARKDOWN: &[&str] = &["md", "markdown", "mdown", "mkd"];

pub fn is_markdown(path: &Path) -> bool {
    path.extension().is_some_and(|e| MARKDOWN.contains(&e.to_string_lossy().to_lowercase().as_str()))
}

/// Markdown files under a folder, skipping hidden and generated folders. Folders without
/// Markdown files are left out.
pub fn scan(folder: &Path, depth: usize, budget: &mut usize) -> Vec<FileNode> {
    if depth >= 10 || *budget == 0 {
        return Vec::new();
    }
    let Ok(entries) = std::fs::read_dir(folder) else { return Vec::new() };
    let mut dirs = Vec::new();
    let mut files = Vec::new();
    for entry in entries.flatten() {
        if *budget == 0 {
            break;
        }
        let name = entry.file_name().to_string_lossy().to_string();
        if name.starts_with('.') || SKIPPED.contains(&name.as_str()) {
            continue;
        }
        let path = entry.path();
        let Ok(kind) = entry.file_type() else { continue };
        if kind.is_dir() {
            let children = scan(&path, depth + 1, budget);
            if !children.is_empty() {
                dirs.push(FileNode { name, path, dir: true, children });
            }
        } else if is_markdown(&path) {
            *budget -= 1;
            files.push(FileNode { name, path, dir: false, children: Vec::new() });
        }
    }
    let key = |n: &FileNode| n.name.to_lowercase();
    dirs.sort_by_key(key);
    files.sort_by_key(key);
    dirs.extend(files);
    dirs
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum OpenTarget {
    Here,
    NewTab,
    Right,
}

pub struct Sidebar {
    pub root: gtk::Box,
    stack: gtk::Stack,
    switches: Vec<gtk::ToggleButton>,
    outline_list: gtk::ListBox,
    outline_filter: gtk::SearchEntry,
    outline_empty: gtk::Label,
    outline: RefCell<Vec<OutlineItem>>,
    updating: Cell<bool>,
    folder_title: gtk::Label,
    folder_stack: gtk::Stack,
    folder_view: gtk::ListView,
    folder_spinner: gtk::Spinner,
    recent_box: gtk::Box,
    pub on_heading: RefCell<Option<Rc<dyn Fn(usize)>>>,
    pub on_open: RefCell<Option<Rc<dyn Fn(PathBuf, OpenTarget)>>>,
}

impl Sidebar {
    pub fn new() -> Rc<Sidebar> {
        let root = gtk::Box::new(gtk::Orientation::Vertical, 0);
        root.add_css_class("md-sidebar");
        let switcher = gtk::Box::new(gtk::Orientation::Horizontal, 0);
        switcher.add_css_class("linked");
        switcher.set_margin_top(8);
        switcher.set_margin_bottom(6);
        switcher.set_margin_start(10);
        switcher.set_margin_end(10);
        switcher.set_homogeneous(true);
        let stack = gtk::Stack::new();
        stack.set_transition_type(gtk::StackTransitionType::Crossfade);
        stack.set_vexpand(true);

        // Outline
        let outline_page = gtk::Box::new(gtk::Orientation::Vertical, 6);
        let outline_filter = gtk::SearchEntry::new();
        outline_filter.set_placeholder_text(Some(&t("Filtrar títulos")));
        outline_filter.set_margin_start(10);
        outline_filter.set_margin_end(10);
        let outline_list = gtk::ListBox::new();
        outline_list.add_css_class("navigation-sidebar");
        outline_list.add_css_class("md-outline");
        outline_list.set_selection_mode(gtk::SelectionMode::Single);
        let outline_empty = gtk::Label::new(Some(&t("Los títulos aparecerán aquí.")));
        outline_empty.add_css_class("dim-label");
        outline_empty.set_margin_top(18);
        outline_empty.set_wrap(true);
        let outline_scroll = gtk::ScrolledWindow::new();
        outline_scroll.set_vexpand(true);
        outline_scroll.set_hscrollbar_policy(gtk::PolicyType::Never);
        let outline_column = gtk::Box::new(gtk::Orientation::Vertical, 0);
        outline_column.append(&outline_list);
        outline_column.append(&outline_empty);
        outline_scroll.set_child(Some(&outline_column));
        outline_page.append(&outline_filter);
        outline_page.append(&outline_scroll);

        // Folder
        let folder_page = gtk::Box::new(gtk::Orientation::Vertical, 0);
        let folder_header = gtk::Box::new(gtk::Orientation::Horizontal, 2);
        folder_header.set_margin_start(14);
        folder_header.set_margin_end(6);
        let folder_title = gtk::Label::new(None);
        folder_title.add_css_class("heading");
        folder_title.set_xalign(0.0);
        folder_title.set_hexpand(true);
        folder_title.set_ellipsize(gtk::pango::EllipsizeMode::Middle);
        let folder_spinner = gtk::Spinner::new();
        let refresh = gtk::Button::from_icon_name("view-refresh-symbolic");
        refresh.add_css_class("flat");
        refresh.set_tooltip_text(Some(&t("Actualizar carpeta")));
        refresh.set_action_name(Some("win.refresh-folder"));
        let close = gtk::Button::from_icon_name("window-close-symbolic");
        close.add_css_class("flat");
        close.set_tooltip_text(Some(&t("Cerrar carpeta")));
        close.set_action_name(Some("win.close-folder"));
        folder_header.append(&folder_title);
        folder_header.append(&folder_spinner);
        folder_header.append(&refresh);
        folder_header.append(&close);
        let folder_view = gtk::ListView::new(None::<gtk::NoSelection>, None::<gtk::ListItemFactory>);
        folder_view.add_css_class("navigation-sidebar");
        let folder_scroll = gtk::ScrolledWindow::new();
        folder_scroll.set_vexpand(true);
        folder_scroll.set_hscrollbar_policy(gtk::PolicyType::Never);
        folder_scroll.set_child(Some(&folder_view));
        let empty_folder = gtk::Label::new(Some(&t("Sin archivos Markdown")));
        empty_folder.add_css_class("dim-label");
        empty_folder.set_valign(gtk::Align::Start);
        empty_folder.set_margin_top(18);
        let folder_stack = gtk::Stack::new();
        let open_folder = adw::StatusPage::new();
        open_folder.set_icon_name(Some("folder-open-symbolic"));
        open_folder.set_description(Some(&t("Abrir carpeta de trabajo")));
        open_folder.add_css_class("compact");
        let open_button = gtk::Button::with_label(&t("Abrir carpeta…"));
        open_button.add_css_class("pill");
        open_button.set_halign(gtk::Align::Center);
        open_button.set_action_name(Some("win.open-folder"));
        open_folder.set_child(Some(&open_button));
        let tree_page = gtk::Box::new(gtk::Orientation::Vertical, 0);
        tree_page.append(&folder_header);
        let tree_stack = gtk::Stack::new();
        tree_stack.add_named(&folder_scroll, Some("tree"));
        tree_stack.add_named(&empty_folder, Some("empty"));
        tree_stack.set_vexpand(true);
        tree_page.append(&tree_stack);
        folder_stack.add_named(&open_folder, Some("none"));
        folder_stack.add_named(&tree_page, Some("folder"));
        folder_page.append(&folder_stack);

        // Recent and favorites
        let recent_scroll = gtk::ScrolledWindow::new();
        recent_scroll.set_hscrollbar_policy(gtk::PolicyType::Never);
        recent_scroll.set_vexpand(true);
        let recent_box = gtk::Box::new(gtk::Orientation::Vertical, 6);
        recent_scroll.set_child(Some(&recent_box));

        stack.add_named(&outline_page, Some("outline"));
        stack.add_named(&folder_page, Some("folder"));
        stack.add_named(&recent_scroll, Some("recent"));

        let mut switches = Vec::new();
        let mut group: Option<gtk::ToggleButton> = None;
        for (name, label) in [("outline", "Contenido"), ("folder", "Carpeta"), ("recent", "Recientes")] {
            let button = gtk::ToggleButton::with_label(&t(label));
            button.set_widget_name(name);
            if let Some(first) = &group {
                button.set_group(Some(first));
            } else {
                group = Some(button.clone());
            }
            switcher.append(&button);
            switches.push(button);
        }
        root.append(&switcher);
        root.append(&stack);

        let sidebar = Rc::new(Sidebar {
            root,
            stack,
            switches,
            outline_list,
            outline_filter,
            outline_empty,
            outline: RefCell::new(Vec::new()),
            updating: Cell::new(false),
            folder_title,
            folder_stack,
            folder_view,
            folder_spinner,
            recent_box,
            on_heading: RefCell::new(None),
            on_open: RefCell::new(None),
        });
        sidebar.connect(tree_stack);
        sidebar.show_page(&prefs::with(|p| p.sidebar_page.clone()));
        sidebar.refresh_recent();
        sidebar
    }

    fn connect(self: &Rc<Self>, tree_stack: gtk::Stack) {
        for button in &self.switches {
            let weak = Rc::downgrade(self);
            button.connect_toggled(move |button| {
                if button.is_active() {
                    if let Some(sidebar) = weak.upgrade() {
                        let name = button.widget_name().to_string();
                        sidebar.stack.set_visible_child_name(&name);
                        prefs::update_quietly(|p| p.sidebar_page = name);
                    }
                }
            });
        }
        let weak = Rc::downgrade(self);
        self.outline_list.connect_row_activated(move |_, row| {
            if let Some(sidebar) = weak.upgrade() {
                if let Some(f) = sidebar.on_heading.borrow().clone() {
                    f(row.widget_name().parse().unwrap_or(0));
                }
            }
        });
        let weak = Rc::downgrade(self);
        self.outline_list.connect_row_selected(move |_, row| {
            let Some(sidebar) = weak.upgrade() else { return };
            if sidebar.updating.get() {
                return;
            }
            let handler = sidebar.on_heading.borrow().clone();
            if let (Some(row), Some(f)) = (row, handler) {
                f(row.widget_name().parse().unwrap_or(0));
            }
        });
        let weak = Rc::downgrade(self);
        self.outline_filter.connect_search_changed(move |_| {
            if let Some(sidebar) = weak.upgrade() {
                sidebar.filter_outline();
            }
        });

        // Folder tree rows: an expander with an icon and a name.
        let factory = gtk::SignalListItemFactory::new();
        let weak = Rc::downgrade(self);
        factory.connect_setup(move |_, item| {
            let item = item.downcast_ref::<gtk::ListItem>().unwrap();
            let expander = gtk::TreeExpander::new();
            let row = gtk::Box::new(gtk::Orientation::Horizontal, 6);
            let icon = gtk::Image::new();
            let label = gtk::Label::new(None);
            label.set_xalign(0.0);
            label.set_ellipsize(gtk::pango::EllipsizeMode::End);
            row.append(&icon);
            row.append(&label);
            expander.set_child(Some(&row));
            item.set_child(Some(&expander));
            let click = gtk::GestureClick::new();
            click.set_button(0);
            let weak = weak.clone();
            let item_weak = item.downgrade();
            click.connect_pressed(move |gesture, _, x, y| {
                let (Some(sidebar), Some(item)) = (weak.upgrade(), item_weak.upgrade()) else { return };
                let Some(node) = node_of(&item) else { return };
                let button = gesture.current_button();
                let ctrl = gesture.current_event_state().contains(gdk::ModifierType::CONTROL_MASK);
                if button == gdk::BUTTON_SECONDARY {
                    let widget = gesture.widget().unwrap();
                    file_menu(&widget, &node.path, node.dir, x, y);
                    gesture.set_state(gtk::EventSequenceState::Claimed);
                } else if !node.dir && (button == gdk::BUTTON_MIDDLE || (button == gdk::BUTTON_PRIMARY && ctrl)) {
                    if let Some(f) = sidebar.on_open.borrow().clone() {
                        f(node.path.clone(), OpenTarget::NewTab);
                    }
                    gesture.set_state(gtk::EventSequenceState::Claimed);
                }
            });
            expander.add_controller(click);
        });
        factory.connect_bind(|_, item| {
            let item = item.downcast_ref::<gtk::ListItem>().unwrap();
            let Some(row) = item.item().and_downcast::<gtk::TreeListRow>() else { return };
            let expander = item.child().and_downcast::<gtk::TreeExpander>().unwrap();
            expander.set_list_row(Some(&row));
            let Some(node) = row.item().and_downcast::<glib::BoxedAnyObject>() else { return };
            let node = node.borrow::<FileNode>();
            let content = expander.child().and_downcast::<gtk::Box>().unwrap();
            let icon = content.first_child().and_downcast::<gtk::Image>().unwrap();
            let label = icon.next_sibling().and_downcast::<gtk::Label>().unwrap();
            icon.set_icon_name(Some(if node.dir { "folder-symbolic" } else { "text-x-generic-symbolic" }));
            label.set_text(&node.name);
            expander.set_tooltip_text(Some(&node.path.to_string_lossy()));
        });
        self.folder_view.set_factory(Some(&factory));
        self.folder_view.set_single_click_activate(true);
        let weak = Rc::downgrade(self);
        self.folder_view.connect_activate(move |view, position| {
            let Some(sidebar) = weak.upgrade() else { return };
            let Some(model) = view.model() else { return };
            let Some(row) = model.item(position).and_downcast::<gtk::TreeListRow>() else { return };
            let Some(node) = row.item().and_downcast::<glib::BoxedAnyObject>() else { return };
            let node = node.borrow::<FileNode>().clone();
            if node.dir {
                row.set_expanded(!row.is_expanded());
            } else if let Some(f) = sidebar.on_open.borrow().clone() {
                f(node.path, OpenTarget::Here);
            }
        });
        let _ = tree_stack;
    }

    pub fn show_page(&self, name: &str) {
        for button in &self.switches {
            if button.widget_name() == name {
                button.set_active(true);
            }
        }
        self.stack.set_visible_child_name(name);
    }

    // MARK: Outline

    pub fn set_outline(&self, outline: Vec<OutlineItem>, current: Option<usize>) {
        if *self.outline.borrow() == outline {
            self.set_current(current);
            return;
        }
        self.updating.set(true);
        while let Some(child) = self.outline_list.first_child() {
            self.outline_list.remove(&child);
        }
        let min_level = outline.iter().map(|o| o.level).min().unwrap_or(1);
        for (index, item) in outline.iter().enumerate() {
            let label = gtk::Label::new(Some(&item.title));
            label.set_xalign(0.0);
            label.set_ellipsize(gtk::pango::EllipsizeMode::End);
            label.set_tooltip_text(Some(&item.title));
            let depth = (item.level - min_level) as i32;
            label.set_margin_start(depth * 14);
            if item.level == min_level {
                label.add_css_class("md-outline-top");
            } else if depth >= 2 {
                label.add_css_class("dim-label");
            }
            let row = gtk::ListBoxRow::new();
            row.set_child(Some(&label));
            row.set_widget_name(&index.to_string());
            self.outline_list.append(&row);
        }
        self.outline_empty.set_visible(outline.is_empty());
        *self.outline.borrow_mut() = outline;
        self.filter_outline();
        self.updating.set(false);
        self.set_current(current);
    }

    pub fn set_current(&self, current: Option<usize>) {
        self.updating.set(true);
        match current.and_then(|i| self.outline_list.row_at_index(i as i32)) {
            Some(row) => {
                self.outline_list.select_row(Some(&row));
            }
            None => self.outline_list.unselect_all(),
        }
        self.updating.set(false);
    }

    fn filter_outline(&self) {
        let query = self.outline_filter.text().to_lowercase();
        let outline = self.outline.borrow();
        let mut index = 0;
        while let Some(row) = self.outline_list.row_at_index(index) {
            let visible = query.is_empty() || outline.get(index as usize).is_some_and(|o| o.title.to_lowercase().contains(&query));
            row.set_visible(visible);
            index += 1;
        }
    }

    // MARK: Folder

    pub fn set_folder(&self, folder: Option<&Path>, tree: Option<Vec<FileNode>>, scanning: bool) {
        self.folder_spinner.set_spinning(scanning);
        self.folder_spinner.set_visible(scanning);
        let Some(folder) = folder else {
            self.folder_stack.set_visible_child_name("none");
            self.folder_view.set_model(None::<&gtk::NoSelection>);
            return;
        };
        self.folder_stack.set_visible_child_name("folder");
        self.folder_title.set_text(&folder.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_else(|| folder.to_string_lossy().to_string()));
        self.folder_title.set_tooltip_text(Some(&folder.to_string_lossy()));
        let Some(tree) = tree else { return };
        let tree_stack = self.folder_view.parent().and_then(|p| p.parent()).and_downcast::<gtk::Stack>();
        if let Some(stack) = &tree_stack {
            stack.set_visible_child_name(if tree.is_empty() { "empty" } else { "tree" });
        }
        let root = store(&tree);
        let model = gtk::TreeListModel::new(root, false, false, |item| {
            let node = item.downcast_ref::<glib::BoxedAnyObject>()?;
            let node = node.borrow::<FileNode>();
            node.dir.then(|| store(&node.children).upcast::<gio::ListModel>())
        });
        self.folder_view.set_model(Some(&gtk::NoSelection::new(Some(model))));
    }

    // MARK: Recent and favorites

    pub fn refresh_recent(&self) {
        while let Some(child) = self.recent_box.first_child() {
            self.recent_box.remove(&child);
        }
        let (favorites, recent) = prefs::with(|p| (p.favorites.clone(), p.recent.clone()));
        if !favorites.is_empty() {
            self.recent_box.append(&section_title(&t("FAVORITOS"), None));
            self.recent_box.append(&self.file_list(&favorites, false));
        }
        let clear = gtk::Button::from_icon_name("edit-clear-all-symbolic");
        clear.add_css_class("flat");
        clear.set_tooltip_text(Some(&t("Vaciar la lista de recientes")));
        clear.set_action_name(Some("win.clear-recent"));
        clear.set_sensitive(!recent.is_empty());
        self.recent_box.append(&section_title(&t("RECIENTES"), Some(&clear)));
        if recent.is_empty() {
            let empty = gtk::Label::new(Some("—"));
            empty.add_css_class("dim-label");
            self.recent_box.append(&empty);
        } else {
            self.recent_box.append(&self.file_list(&recent, true));
        }
    }

    fn file_list(&self, paths: &[String], recent: bool) -> gtk::ListBox {
        let list = gtk::ListBox::new();
        list.add_css_class("navigation-sidebar");
        list.set_selection_mode(gtk::SelectionMode::None);
        for path in paths {
            let path_buf = PathBuf::from(path);
            let row = gtk::ListBoxRow::new();
            let column = gtk::Box::new(gtk::Orientation::Vertical, 1);
            let name = gtk::Label::new(Some(&path_buf.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default()));
            name.set_xalign(0.0);
            name.set_ellipsize(gtk::pango::EllipsizeMode::End);
            let parent = gtk::Label::new(Some(&shorten(path_buf.parent().unwrap_or(Path::new("")))));
            parent.set_xalign(0.0);
            parent.add_css_class("dim-label");
            parent.add_css_class("caption");
            parent.set_ellipsize(gtk::pango::EllipsizeMode::Middle);
            column.append(&name);
            column.append(&parent);
            row.set_child(Some(&column));
            row.set_tooltip_text(Some(path));
            row.set_widget_name(path);
            if !path_buf.exists() {
                row.set_sensitive(false);
            }
            let click = gtk::GestureClick::new();
            click.set_button(0);
            let target = path_buf.clone();
            click.connect_released(move |gesture, _, x, y| {
                let button = gesture.current_button();
                let ctrl = gesture.current_event_state().contains(gdk::ModifierType::CONTROL_MASK);
                let Some(widget) = gesture.widget() else { return };
                if button == gdk::BUTTON_SECONDARY {
                    file_menu_with(&widget, &target, false, x, y, recent);
                    return;
                }
                let action = if button == gdk::BUTTON_MIDDLE || ctrl { "win.open-path-tab" } else { "win.open-path" };
                let _ = widget.activate_action(action, Some(&target.to_string_lossy().to_string().to_variant()));
            });
            row.add_controller(click);
            list.append(&row);
        }
        list
    }
}

fn node_of(item: &gtk::ListItem) -> Option<FileNode> {
    let row = item.item().and_downcast::<gtk::TreeListRow>()?;
    let node = row.item().and_downcast::<glib::BoxedAnyObject>()?;
    let node = node.borrow::<FileNode>().clone();
    Some(node)
}

fn store(nodes: &[FileNode]) -> gio::ListStore {
    let store = gio::ListStore::new::<glib::BoxedAnyObject>();
    for node in nodes {
        store.append(&glib::BoxedAnyObject::new(node.clone()));
    }
    store
}

fn section_title(text: &str, extra: Option<&gtk::Button>) -> gtk::Widget {
    let row = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    row.set_margin_start(16);
    row.set_margin_end(8);
    row.set_margin_top(8);
    let label = gtk::Label::new(Some(text));
    label.add_css_class("md-section-title");
    label.set_xalign(0.0);
    label.set_hexpand(true);
    row.append(&label);
    if let Some(extra) = extra {
        row.append(extra);
    }
    row.upcast()
}

pub fn shorten(path: &Path) -> String {
    let text = path.to_string_lossy().to_string();
    match std::env::var("HOME") {
        Ok(home) if !home.is_empty() && text.starts_with(&home) => format!("~{}", &text[home.len()..]),
        _ => text,
    }
}

fn file_menu(widget: &gtk::Widget, path: &Path, dir: bool, x: f64, y: f64) {
    file_menu_with(widget, path, dir, x, y, false);
}

/// Context menu for a file or folder in the sidebar.
pub fn file_menu_with(widget: &gtk::Widget, path: &Path, dir: bool, x: f64, y: f64, recent: bool) {
    let target = path.to_string_lossy().to_string().to_variant();
    let menu = gio::Menu::new();
    let item = |label: &str, action: &str| {
        let item = gio::MenuItem::new(Some(&t(label)), None);
        item.set_action_and_target_value(Some(action), Some(&target));
        item
    };
    if dir {
        menu.append_item(&item("Usar como carpeta de trabajo", "win.use-folder"));
    } else {
        let open = gio::Menu::new();
        open.append_item(&item("Abrir en una pestaña nueva", "win.open-path-tab"));
        open.append_item(&item("Abrir a la derecha", "win.open-path-right"));
        menu.append_section(None, &open);
        let edit = gio::Menu::new();
        edit.append_item(&item("Duplicar", "win.duplicate-path"));
        let favorite = if prefs::is_favorite(path) { "Quitar de favoritos" } else { "Añadir a favoritos" };
        edit.append_item(&item(favorite, "win.toggle-favorite"));
        menu.append_section(None, &edit);
    }
    let more = gio::Menu::new();
    more.append_item(&item("Mostrar en la carpeta", "win.reveal-path"));
    more.append_item(&item("Copiar ruta", "win.copy-path"));
    if recent {
        more.append_item(&item("Quitar de recientes", "win.remove-recent"));
    }
    menu.append_section(None, &more);
    let popover = gtk::PopoverMenu::from_model(Some(&menu));
    popover.set_parent(widget);
    popover.set_has_arrow(false);
    popover.set_pointing_to(Some(&gdk::Rectangle::new(x as i32, y as i32, 1, 1)));
    popover.connect_closed(|popover| {
        let popover = popover.clone();
        glib::idle_add_local_once(move || popover.unparent());
    });
    popover.popup();
}
