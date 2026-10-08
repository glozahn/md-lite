//! A window: its header, sidebar, one or two panes of tabs, and its working folder.

use crate::app;
use crate::dialogs;
use crate::document::{DocumentPage, Kind, Mode};
use crate::i18n::t;
use crate::prefs;
use crate::sidebar::{self, FileNode, OpenTarget, Sidebar};
use crate::ui::editor::FormatAction;
use adw::prelude::*;
use gtk::{gdk, gio, glib};
use std::cell::{Cell, RefCell};
use std::path::{Path, PathBuf};
use std::rc::Rc;

pub struct Pane {
    pub root: gtk::Box,
    pub bar: adw::TabBar,
    pub view: adw::TabView,
}

pub struct Workbench {
    pub window: adw::ApplicationWindow,
    toolbar: adw::ToolbarView,
    split: adw::OverlaySplitView,
    pub sidebar: Rc<Sidebar>,
    paned: gtk::Paned,
    panes: RefCell<Vec<Pane>>,
    focused: Cell<usize>,
    toasts: adw::ToastOverlay,
    mode_buttons: Vec<gtk::ToggleButton>,
    mode_box: gtk::Box,
    focus_mode: Cell<bool>,
    exit_focus: gtk::Button,
    workspace: RefCell<Option<PathBuf>>,
    tree: RefCell<Option<Vec<FileNode>>>,
    menu_page: RefCell<Option<adw::TabPage>>,
    handlers: RefCell<Vec<(glib::WeakRef<DocumentPage>, Vec<glib::SignalHandlerId>)>>,
    updating: Cell<bool>,
    open_menu: gio::Menu,
    listener: RefCell<Option<Rc<dyn Fn()>>>,
    lists_listener: RefCell<Option<Rc<dyn Fn()>>>,
    closing: Cell<bool>,
}

fn icon_toggle(icon: &str, label: &str) -> gtk::ToggleButton {
    let content = adw::ButtonContent::new();
    content.set_icon_name(icon);
    content.set_label(label);
    let button = gtk::ToggleButton::new();
    button.set_child(Some(&content));
    button
}

impl Workbench {
    /// A new window. With `welcome` it greets with the welcome page; otherwise it starts with one blank tab.
    pub fn new(application: &adw::Application, initial: Option<DocumentPage>) -> Rc<Workbench> {
        let window = adw::ApplicationWindow::new(application);
        let (width, height, maximized) = prefs::with(|p| (p.window_width, p.window_height, p.maximized));
        window.set_default_size(width.max(560), height.max(420));
        if maximized {
            window.maximize();
        }
        window.set_title(Some("MD Lite"));
        window.set_icon_name(Some(app::APP_ID));

        let header = adw::HeaderBar::new();
        let sidebar_button = gtk::ToggleButton::new();
        sidebar_button.set_icon_name("sidebar-show-symbolic");
        sidebar_button.set_tooltip_text(Some(&t("Mostrar u ocultar la barra lateral")));
        let open_menu = gio::Menu::new();
        let open = adw::SplitButton::new();
        open.set_icon_name("document-open-symbolic");
        open.set_tooltip_text(Some(&t("Abrir Markdown…")));
        open.set_action_name(Some("win.open"));
        open.set_menu_model(Some(&open_menu));
        let new_tab = gtk::Button::from_icon_name("tab-new-symbolic");
        new_tab.set_tooltip_text(Some(&t("Nueva pestaña")));
        new_tab.set_action_name(Some("win.new-tab"));
        header.pack_start(&sidebar_button);
        header.pack_start(&open);
        header.pack_start(&new_tab);

        let mode_box = gtk::Box::new(gtk::Orientation::Horizontal, 0);
        mode_box.add_css_class("linked");
        mode_box.add_css_class("md-modes");
        let mut mode_buttons = Vec::new();
        for (mode, icon, label, key) in [
            (Mode::Read, "view-paged-symbolic", "Lectura", "Ctrl+1"),
            (Mode::Edit, "document-edit-symbolic", "Editor", "Ctrl+2"),
            (Mode::Source, "text-editor-symbolic", "Código", "Ctrl+3"),
            (Mode::Split, "view-dual-symbolic", "Dividida", "Ctrl+4"),
        ] {
            let button = icon_toggle(icon, &t(label));
            button.set_tooltip_text(Some(&format!("{} · {key}", t(label))));
            button.set_widget_name(mode.name());
            if let Some(first) = mode_buttons.first() {
                button.set_group(Some(first));
            }
            mode_box.append(&button);
            mode_buttons.push(button);
        }
        header.set_title_widget(Some(&mode_box));

        let menu_button = gtk::MenuButton::new();
        menu_button.set_icon_name("open-menu-symbolic");
        menu_button.set_tooltip_text(Some(&t("Menú principal")));
        menu_button.set_menu_model(Some(&main_menu()));
        menu_button.set_primary(true);
        let typography = gtk::MenuButton::new();
        typography.set_label("Aa");
        typography.set_tooltip_text(Some(&t("Tipografía y apariencia")));
        typography.set_popover(Some(&dialogs::quick_settings()));
        let find = gtk::Button::from_icon_name("system-search-symbolic");
        find.set_tooltip_text(Some(&t("Buscar · Ctrl+F")));
        find.set_action_name(Some("win.find"));
        header.pack_end(&menu_button);
        header.pack_end(&typography);
        header.pack_end(&find);

        let sidebar = Sidebar::new();
        let paned = gtk::Paned::new(gtk::Orientation::Horizontal);
        paned.set_shrink_start_child(false);
        paned.set_shrink_end_child(false);
        paned.set_resize_start_child(true);
        paned.set_resize_end_child(true);
        let split = adw::OverlaySplitView::new();
        split.set_sidebar(Some(&sidebar.root));
        split.set_content(Some(&paned));
        split.set_min_sidebar_width(210.0);
        split.set_max_sidebar_width(300.0);
        split.set_sidebar_width_fraction(0.22);
        split.set_show_sidebar(prefs::with(|p| p.sidebar_visible));
        split.bind_property("show-sidebar", &sidebar_button, "active").bidirectional().sync_create().build();

        let toolbar = adw::ToolbarView::new();
        toolbar.add_top_bar(&header);
        toolbar.set_content(Some(&split));
        let overlay = gtk::Overlay::new();
        overlay.set_child(Some(&toolbar));
        let exit_focus = gtk::Button::with_label(&t("Salir del enfoque"));
        exit_focus.add_css_class("osd");
        exit_focus.add_css_class("pill");
        exit_focus.set_halign(gtk::Align::End);
        exit_focus.set_valign(gtk::Align::Start);
        exit_focus.set_margin_top(10);
        exit_focus.set_margin_end(14);
        exit_focus.set_visible(false);
        exit_focus.set_action_name(Some("win.focus-mode"));
        overlay.add_overlay(&exit_focus);
        let toasts = adw::ToastOverlay::new();
        toasts.set_child(Some(&overlay));
        window.set_content(Some(&toasts));

        let bench = Rc::new(Workbench {
            window,
            toolbar,
            split,
            sidebar,
            paned,
            panes: RefCell::new(Vec::new()),
            focused: Cell::new(0),
            toasts,
            mode_buttons,
            mode_box,
            focus_mode: Cell::new(false),
            exit_focus,
            workspace: RefCell::new(None),
            tree: RefCell::new(None),
            menu_page: RefCell::new(None),
            handlers: RefCell::new(Vec::new()),
            updating: Cell::new(false),
            open_menu,
            listener: RefCell::new(None),
            lists_listener: RefCell::new(None),
            closing: Cell::new(false),
        });
        app::register(&bench);
        bench.add_pane();
        bench.connect();
        bench.install_actions();
        bench.rebuild_open_menu();
        if let Some(page) = initial {
            bench.add_page(&page, 0, true);
        }
        bench
    }

    fn connect(self: &Rc<Self>) {
        let weak = Rc::downgrade(self);
        for button in &self.mode_buttons {
            let weak = weak.clone();
            button.connect_toggled(move |button| {
                let Some(bench) = weak.upgrade() else { return };
                if button.is_active() && !bench.updating.get() {
                    if let Some(page) = bench.current() {
                        page.set_mode(Mode::from_name(&button.widget_name()));
                    }
                }
            });
        }
        self.split.connect_show_sidebar_notify(glib::clone!(
            #[weak(rename_to = split)]
            self.split,
            move |_| {
                let visible = split.shows_sidebar();
                if prefs::with(|p| p.sidebar_visible) != visible {
                    prefs::update_quietly(|p| p.sidebar_visible = visible);
                }
            }
        ));
        let weak = Rc::downgrade(self);
        *self.sidebar.on_heading.borrow_mut() = Some(Rc::new(move |index| {
            if let Some(page) = weak.upgrade().and_then(|b| b.current()) {
                page.navigate_to(index);
            }
        }));
        let weak = Rc::downgrade(self);
        *self.sidebar.on_open.borrow_mut() = Some(Rc::new(move |path, target| {
            if let Some(bench) = weak.upgrade() {
                bench.open_path(&path, target);
            }
        }));
        let weak = Rc::downgrade(self);
        self.window.connect_close_request(move |window| {
            let Some(bench) = weak.upgrade() else { return glib::Propagation::Proceed };
            if bench.closing.get() {
                return glib::Propagation::Proceed;
            }
            let pages = bench.pages();
            let bench2 = bench.clone();
            confirm_all(pages, move |ok| {
                if ok {
                    bench2.closing.set(true);
                    if app::count() == 1 {
                        app::save_session();
                    }
                    bench2.remember_size();
                    app::unregister(&bench2);
                    bench2.window.close();
                }
            });
            let _ = window;
            glib::Propagation::Stop
        });
        let listener: Rc<dyn Fn()> = Rc::new(glib::clone!(
            #[weak(rename_to = bench)]
            self,
            move || {
                for page in bench.pages() {
                    page.apply_prefs();
                }
                bench.update_header();
            }
        ));
        prefs::add_listener(&listener);
        let lists: Rc<dyn Fn()> = Rc::new(glib::clone!(
            #[weak(rename_to = bench)]
            self,
            move || {
                bench.rebuild_open_menu();
                bench.sidebar.refresh_recent();
            }
        ));
        prefs::add_list_listener(&lists);
        *self.listener.borrow_mut() = Some(listener);
        *self.lists_listener.borrow_mut() = Some(lists);
        let keys = gtk::EventControllerKey::new();
        keys.connect_key_pressed(glib::clone!(
            #[weak(rename_to = bench)]
            self,
            #[upgrade_or]
            glib::Propagation::Proceed,
            move |_, key, _, _| {
                if key == gdk::Key::Escape && bench.focus_mode.get() {
                    bench.toggle_focus_mode();
                    return glib::Propagation::Stop;
                }
                glib::Propagation::Proceed
            }
        ));
        self.window.add_controller(keys);
    }

    fn remember_size(&self) {
        let maximized = self.window.is_maximized();
        let (w, h) = (self.window.width(), self.window.height());
        prefs::update_quietly(|p| {
            p.maximized = maximized;
            if !maximized && w > 0 {
                p.window_width = w;
                p.window_height = h;
            }
        });
    }

    // MARK: Panes and tabs

    fn add_pane(self: &Rc<Self>) -> usize {
        let view = adw::TabView::new();
        view.set_vexpand(true);
        let bar = adw::TabBar::new();
        bar.set_view(Some(&view));
        bar.set_autohide(false);
        bar.set_expand_tabs(true);
        let menu = gio::Menu::new();
        view.set_menu_model(Some(&tab_menu()));
        let _ = menu;
        let root = gtk::Box::new(gtk::Orientation::Vertical, 0);
        root.append(&bar);
        root.append(&view);
        let index = self.panes.borrow().len();
        if index == 0 {
            self.paned.set_start_child(Some(&root));
        } else {
            self.paned.set_end_child(Some(&root));
            let paned = self.paned.clone();
            glib::idle_add_local_once(move || paned.set_position(paned.width() / 2));
        }
        let weak = Rc::downgrade(self);
        view.connect_close_page(move |view, tab| {
            let Some(bench) = weak.upgrade() else { return glib::Propagation::Proceed };
            let Some(page) = tab.child().downcast::<DocumentPage>().ok() else { return glib::Propagation::Proceed };
            let view = view.clone();
            let tab = tab.clone();
            page.confirm_close(move |ok| {
                view.close_page_finish(&tab, ok);
                if ok {
                    let bench = bench.clone();
                    glib::idle_add_local_once(move || bench.prune_panes());
                }
            });
            glib::Propagation::Stop
        });
        let weak = Rc::downgrade(self);
        view.connect_page_attached(move |_, tab, _| {
            if let Some(bench) = weak.upgrade() {
                bench.attach(tab);
            }
        });
        let weak = Rc::downgrade(self);
        view.connect_page_detached(move |_, tab, _| {
            if let Some(bench) = weak.upgrade() {
                bench.detach(tab);
                let bench = bench.clone();
                glib::idle_add_local_once(move || bench.prune_panes());
            }
        });
        let weak = Rc::downgrade(self);
        view.connect_selected_page_notify(move |view| {
            let Some(bench) = weak.upgrade() else { return };
            if let Some(index) = bench.pane_index(view) {
                if view.selected_page().is_some() {
                    bench.focused.set(index);
                }
            }
            bench.update_header();
            bench.update_sidebar();
        });
        let weak = Rc::downgrade(self);
        view.connect_create_window(move |_| {
            let bench = weak.upgrade()?;
            let application = bench.window.application().and_downcast::<adw::Application>()?;
            let other = Workbench::new(&application, None);
            other.window.present();
            let view = other.panes.borrow()[0].view.clone();
            Some(view)
        });
        let weak = Rc::downgrade(self);
        view.connect_setup_menu(move |_, tab| {
            if let Some(bench) = weak.upgrade() {
                *bench.menu_page.borrow_mut() = tab.cloned();
            }
        });
        let focus = gtk::EventControllerFocus::new();
        let weak = Rc::downgrade(self);
        let view_ref = view.clone();
        focus.connect_enter(move |_| {
            if let Some(bench) = weak.upgrade() {
                if let Some(index) = bench.pane_index(&view_ref) {
                    if bench.focused.get() != index {
                        bench.focused.set(index);
                        bench.update_header();
                        bench.update_sidebar();
                    }
                }
            }
        });
        root.add_controller(focus);
        self.panes.borrow_mut().push(Pane { root, bar, view });
        index
    }

    fn pane_index(&self, view: &adw::TabView) -> Option<usize> {
        self.panes.borrow().iter().position(|p| p.view == *view)
    }

    fn view(&self, index: usize) -> adw::TabView {
        let panes = self.panes.borrow();
        panes[index.min(panes.len() - 1)].view.clone()
    }

    fn focused_view(&self) -> adw::TabView {
        self.view(self.focused.get())
    }

    pub fn current(&self) -> Option<DocumentPage> {
        let view = self.focused_view();
        view.selected_page().and_then(|p| p.child().downcast::<DocumentPage>().ok()).or_else(|| {
            self.panes.borrow().iter().find_map(|p| p.view.selected_page().and_then(|t| t.child().downcast::<DocumentPage>().ok()))
        })
    }

    pub fn pages(&self) -> Vec<DocumentPage> {
        let mut pages = Vec::new();
        for pane in self.panes.borrow().iter() {
            for i in 0..pane.view.n_pages() {
                if let Ok(page) = pane.view.nth_page(i).child().downcast::<DocumentPage>() {
                    pages.push(page);
                }
            }
        }
        pages
    }

    fn tab_of(&self, page: &DocumentPage) -> Option<(adw::TabView, adw::TabPage)> {
        // TabView::page() asserts the child belongs to that view, so look through the pages.
        let widget = page.upcast_ref::<gtk::Widget>();
        for pane in self.panes.borrow().iter() {
            for i in 0..pane.view.n_pages() {
                let tab = pane.view.nth_page(i);
                if tab.child() == *widget {
                    return Some((pane.view.clone(), tab));
                }
            }
        }
        None
    }

    pub fn add_page(self: &Rc<Self>, page: &DocumentPage, pane: usize, select: bool) -> adw::TabPage {
        let view = self.view(pane);
        let position = view.selected_page().map_or(view.n_pages(), |p| view.page_position(&p) + 1);
        let tab = view.insert(page, position);
        if select {
            view.set_selected_page(&tab);
            self.focused.set(pane.min(self.panes.borrow().len() - 1));
        }
        tab
    }

    fn attach(self: &Rc<Self>, tab: &adw::TabPage) {
        let Ok(page) = tab.child().downcast::<DocumentPage>() else { return };
        let mut ids = Vec::new();
        let weak = Rc::downgrade(self);
        ids.push(page.connect_local("state-changed", false, {
            let weak = weak.clone();
            move |args| {
                let page = args[0].get::<DocumentPage>().ok()?;
                let bench = weak.upgrade()?;
                bench.update_tab(&page);
                if bench.current().as_ref() == Some(&page) {
                    bench.update_header();
                }
                None
            }
        }));
        ids.push(page.connect_local("outline-changed", false, {
            let weak = weak.clone();
            move |args| {
                let page = args[0].get::<DocumentPage>().ok()?;
                let bench = weak.upgrade()?;
                if bench.current().as_ref() == Some(&page) {
                    bench.update_sidebar();
                }
                None
            }
        }));
        ids.push(page.connect_local("heading-changed", false, {
            let weak = weak.clone();
            move |args| {
                let page = args[0].get::<DocumentPage>().ok()?;
                let bench = weak.upgrade()?;
                if bench.current().as_ref() == Some(&page) {
                    bench.sidebar.set_current(page.current_heading());
                }
                None
            }
        }));
        ids.push(page.connect_local("open-path", false, {
            let weak = weak.clone();
            move |args| {
                let path = args[1].get::<String>().ok()?;
                let new_tab = args[2].get::<bool>().ok()?;
                let bench = weak.upgrade()?;
                bench.open_path(Path::new(&path), if new_tab { OpenTarget::NewTab } else { OpenTarget::Here });
                None
            }
        }));
        ids.push(page.connect_local("toast", false, {
            let weak = weak.clone();
            move |args| {
                let message = args[1].get::<String>().ok()?;
                weak.upgrade()?.toast(&message);
                None
            }
        }));
        self.handlers.borrow_mut().push((page.downgrade(), ids));
        self.update_tab(&page);
        page.apply_prefs();
    }

    fn detach(&self, tab: &adw::TabPage) {
        let Ok(page) = tab.child().downcast::<DocumentPage>() else { return };
        let mut handlers = self.handlers.borrow_mut();
        if let Some(index) = handlers.iter().position(|(w, _)| w.upgrade().as_ref() == Some(&page)) {
            let (_, ids) = handlers.remove(index);
            for id in ids {
                page.disconnect(id);
            }
        }
    }

    /// Removes an empty second pane, and closes the window when its last tab is gone.
    fn prune_panes(self: &Rc<Self>) {
        let empty: Vec<usize> = self.panes.borrow().iter().enumerate().filter(|(_, p)| p.view.n_pages() == 0).map(|(i, _)| i).collect();
        if empty.is_empty() {
            return;
        }
        let count = self.panes.borrow().len();
        if count == 2 && empty.len() == 1 {
            let index = empty[0];
            let pane = self.panes.borrow_mut().remove(index);
            if index == 0 {
                let remaining = self.panes.borrow()[0].root.clone();
                self.paned.set_end_child(None::<&gtk::Widget>);
                self.paned.set_start_child(Some(&remaining));
            } else {
                self.paned.set_end_child(None::<&gtk::Widget>);
            }
            drop(pane);
            self.focused.set(0);
            self.update_header();
            self.update_sidebar();
        } else if self.panes.borrow().iter().all(|p| p.view.n_pages() == 0) && !self.closing.get() {
            self.closing.set(true);
            if app::count() == 1 {
                app::save_session();
            }
            self.remember_size();
            app::unregister(self);
            self.window.close();
        }
    }

    fn update_tab(&self, page: &DocumentPage) {
        let Some((_, tab)) = self.tab_of(page) else { return };
        let mut title = page.title();
        if page.is_dirty() && page.kind() != Kind::File {
            title.push_str(" •");
        }
        tab.set_title(&title);
        let tooltip = page.path().map(|p| p.to_string_lossy().to_string()).unwrap_or_else(|| page.title());
        tab.set_tooltip(&glib::markup_escape_text(&tooltip));
        tab.set_icon(None::<&gio::Icon>);
    }

    pub fn new_tab(self: &Rc<Self>) -> DocumentPage {
        let page = DocumentPage::new();
        page.make_blank();
        self.add_page(&page, self.focused.get(), true);
        page
    }

    /// The current tab when it is free, otherwise a new one.
    pub fn reusable_page(self: &Rc<Self>) -> DocumentPage {
        match self.current() {
            Some(page) if page.can_reuse() => page,
            _ => self.new_tab(),
        }
    }

    pub fn focus_page(&self, page: &DocumentPage) {
        if let Some((view, tab)) = self.tab_of(page) {
            view.set_selected_page(&tab);
            if let Some(index) = self.pane_index(&view) {
                self.focused.set(index);
            }
            self.window.present();
        }
    }

    pub fn open_path(self: &Rc<Self>, path: &Path, target: OpenTarget) {
        if path.is_dir() {
            self.set_workspace(Some(path.to_path_buf()));
            return;
        }
        let canonical = std::fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf());
        if target != OpenTarget::Right {
            if let Some((bench, page)) = app::find_open(&canonical) {
                bench.focus_page(&page);
                return;
            }
        }
        let page = match target {
            OpenTarget::Here => self.reusable_page(),
            OpenTarget::NewTab => self.new_tab(),
            OpenTarget::Right => {
                let index = self.ensure_right_pane();
                let page = DocumentPage::new();
                page.make_blank();
                self.add_page(&page, index, true);
                page
            }
        };
        if let Err(message) = page.open_file(&canonical) {
            dialogs::alert(&self.window, &t("No se pudo abrir"), &message);
            if page.kind() == Kind::Blank && self.pages().len() > 1 && target != OpenTarget::Here {
                if let Some((view, tab)) = self.tab_of(&page) {
                    view.close_page(&tab);
                }
            }
        }
        self.update_header();
        self.update_sidebar();
    }

    fn ensure_right_pane(self: &Rc<Self>) -> usize {
        if self.panes.borrow().len() < 2 {
            self.add_pane();
        }
        1
    }

    fn move_page(self: &Rc<Self>, page: &DocumentPage, side: usize) {
        let Some((from, tab)) = self.tab_of(page) else { return };
        let target_index = if side == 1 { self.ensure_right_pane() } else { 0 };
        let target = self.view(target_index);
        if target == from {
            return;
        }
        if from.n_pages() == 1 && target_index == 0 && self.panes.borrow().len() == 1 {
            return;
        }
        from.transfer_page(&tab, &target, target.n_pages());
        target.set_selected_page(&tab);
        self.focused.set(target_index);
        self.update_header();
        self.update_sidebar();
    }

    fn close_pane(self: &Rc<Self>, index: usize) {
        if self.panes.borrow().len() < 2 {
            return;
        }
        let from = self.view(index);
        let to = self.view(1 - index);
        while from.n_pages() > 0 {
            let tab = from.nth_page(0);
            from.transfer_page(&tab, &to, to.n_pages());
        }
    }

    fn detach_to_window(self: &Rc<Self>, page: &DocumentPage) {
        let Some((from, tab)) = self.tab_of(page) else { return };
        if self.pages().len() == 1 {
            return;
        }
        let Some(application) = self.window.application().and_downcast::<adw::Application>() else { return };
        let other = Workbench::new(&application, None);
        let to = other.view(0);
        from.transfer_page(&tab, &to, 0);
        to.set_selected_page(&tab);
        other.window.present();
    }

    fn cycle_tab(&self, delta: i32) {
        let view = self.focused_view();
        let count = view.n_pages();
        if count < 2 {
            return;
        }
        let Some(selected) = view.selected_page() else { return };
        let index = (view.page_position(&selected) + delta).rem_euclid(count);
        view.set_selected_page(&view.nth_page(index));
    }

    fn close_others(&self, page: &DocumentPage) {
        if let Some((view, tab)) = self.tab_of(page) {
            view.close_other_pages(&tab);
        }
    }

    /// The page a tab menu was opened for, or the current one.
    fn target_page(&self) -> Option<DocumentPage> {
        if let Some(tab) = self.menu_page.borrow_mut().take() {
            if let Ok(page) = tab.child().downcast::<DocumentPage>() {
                return Some(page);
            }
        }
        self.current()
    }

    pub fn toast(&self, message: &str) {
        let toast = adw::Toast::new(message);
        toast.set_timeout(2);
        self.toasts.add_toast(toast);
    }

    // MARK: Header and sidebar

    pub fn update_header(&self) {
        let page = self.current();
        self.updating.set(true);
        let mode = page.as_ref().map(|p| p.mode()).unwrap_or_default();
        let blank = page.as_ref().is_none_or(|p| p.kind() == Kind::Blank);
        for button in &self.mode_buttons {
            button.set_active(button.widget_name() == mode.name());
        }
        self.mode_box.set_sensitive(!blank);
        self.updating.set(false);
        if let Some(action) = self.window.lookup_action("mode").and_downcast::<gio::SimpleAction>() {
            action.set_state(&mode.name().to_variant());
        }
        let title = page.as_ref().map(|p| p.title()).unwrap_or_default();
        self.window.set_title(Some(&if title.is_empty() { "MD Lite".to_string() } else { format!("{title} — MD Lite") }));
        let has_file = page.as_ref().is_some_and(|p| p.path().is_some());
        for (name, enabled) in [
            ("reload", has_file),
            ("duplicate", !blank),
            ("save", !blank),
            ("save-as", !blank),
            ("save-copy", !blank),
            ("export-html", !blank),
            ("export-pdf", !blank),
            ("print", !blank),
            ("find", !blank),
            ("close-pane", self.panes.borrow().len() > 1),
        ] {
            if let Some(action) = self.window.lookup_action(name).and_downcast::<gio::SimpleAction>() {
                action.set_enabled(enabled);
            }
        }
    }

    fn update_sidebar(&self) {
        match self.current() {
            Some(page) => self.sidebar.set_outline(page.outline(), page.current_heading()),
            None => self.sidebar.set_outline(Vec::new(), None),
        }
    }

    fn rebuild_open_menu(&self) {
        let menu = &self.open_menu;
        menu.remove_all();
        let top = gio::Menu::new();
        top.append(Some(&t("Nueva nota")), Some("win.new-note"));
        top.append(Some(&t("Abrir carpeta…")), Some("win.open-folder"));
        top.append(Some(&t("Pegar y leer")), Some("win.paste-read"));
        menu.append_section(None, &top);
        let recent = prefs::with(|p| p.recent.clone());
        if !recent.is_empty() {
            let section = gio::Menu::new();
            for path in recent.iter().take(8) {
                let name = Path::new(path).file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
                let item = gio::MenuItem::new(Some(&name.replace('_', "__")), None);
                item.set_action_and_target_value(Some("win.open-path"), Some(&path.to_variant()));
                section.append_item(&item);
            }
            menu.append_section(Some(&t("Abrir reciente")), &section);
        }
    }

    // MARK: Focus mode

    fn toggle_focus_mode(&self) {
        let on = !self.focus_mode.get();
        self.focus_mode.set(on);
        self.toolbar.set_reveal_top_bars(!on);
        self.exit_focus.set_visible(on);
        if on {
            self.split.set_show_sidebar(false);
            self.window.fullscreen();
        } else {
            self.split.set_show_sidebar(prefs::with(|p| p.sidebar_visible) || true);
            self.window.unfullscreen();
        }
        for (index, pane) in self.panes.borrow().iter().enumerate() {
            pane.bar.set_visible(!on);
            if index != self.focused.get() {
                pane.root.set_visible(!on);
            }
        }
        if let Some(action) = self.window.lookup_action("focus-mode").and_downcast::<gio::SimpleAction>() {
            action.set_state(&on.to_variant());
        }
    }

    // MARK: Working folder

    pub fn workspace(&self) -> Option<PathBuf> {
        self.workspace.borrow().clone()
    }

    pub fn set_workspace(self: &Rc<Self>, folder: Option<PathBuf>) {
        *self.workspace.borrow_mut() = folder.clone();
        *self.tree.borrow_mut() = None;
        self.sidebar.set_folder(folder.as_deref(), None, folder.is_some());
        if folder.is_some() {
            self.split.set_show_sidebar(true);
            self.sidebar.show_page("folder");
            self.refresh_workspace();
        }
    }

    fn refresh_workspace(self: &Rc<Self>) {
        let Some(folder) = self.workspace() else { return };
        self.sidebar.set_folder(Some(&folder), None, true);
        let weak = Rc::downgrade(self);
        glib::MainContext::default().spawn_local(async move {
            let scan_folder = folder.clone();
            let tree = gio::spawn_blocking(move || {
                let mut budget = 4000;
                sidebar::scan(&scan_folder, 0, &mut budget)
            })
            .await
            .unwrap_or_default();
            if let Some(bench) = weak.upgrade() {
                if bench.workspace().as_deref() == Some(folder.as_path()) {
                    bench.sidebar.set_folder(Some(&folder), Some(tree.clone()), false);
                    *bench.tree.borrow_mut() = Some(tree);
                }
            }
        });
    }

    // MARK: Actions

    fn install_actions(self: &Rc<Self>) {
        let window = &self.window;
        let weak = Rc::downgrade(self);
        let add = |name: &str, f: Box<dyn Fn(&Rc<Workbench>)>| {
            let action = gio::SimpleAction::new(name, None);
            let weak = weak.clone();
            action.connect_activate(move |_, _| {
                if let Some(bench) = weak.upgrade() {
                    f(&bench);
                }
            });
            window.add_action(&action);
        };
        let with_page = |f: fn(&DocumentPage)| -> Box<dyn Fn(&Rc<Workbench>)> {
            Box::new(move |bench: &Rc<Workbench>| {
                if let Some(page) = bench.current() {
                    f(&page);
                }
            })
        };
        add("new-tab", Box::new(|b| {
            b.new_tab();
        }));
        add("new-note", Box::new(|b| b.reusable_page().new_note()));
        add("open", Box::new(|b| b.open_dialog()));
        add("open-folder", Box::new(|b| b.open_folder_dialog()));
        add("paste-read", Box::new(|b| b.paste_and_read()));
        add("save", with_page(|p| p.save()));
        add("save-as", with_page(|p| p.save_as(|_| {})));
        add("save-copy", with_page(|p| p.save_copy()));
        add("duplicate", with_page(|p| p.duplicate()));
        add("export-html", with_page(|p| p.export_html()));
        add("export-pdf", with_page(|p| p.export_pdf()));
        add("print", with_page(|p| p.print()));
        add("reload", with_page(|p| p.reload()));
        add("find", with_page(|p| p.find()));
        add("find-next", with_page(|p| p.find_next(1)));
        add("find-previous", with_page(|p| p.find_next(-1)));
        add("toggle-editing", with_page(|p| p.toggle_editing()));
        add("previous-heading", with_page(|p| p.navigate_relative(-1)));
        add("next-heading", with_page(|p| p.navigate_relative(1)));
        add("close", Box::new(|b| b.close_innermost()));
        add("toggle-sidebar", Box::new(|b| b.split.set_show_sidebar(!b.split.shows_sidebar())));
        add("zoom-in", Box::new(|_| prefs::update(|p| p.font_size = (p.font_size + 1.0).min(28.0))));
        add("zoom-out", Box::new(|_| prefs::update(|p| p.font_size = (p.font_size - 1.0).max(12.0))));
        add("zoom-reset", Box::new(|_| prefs::update(|p| p.font_size = 17.0)));
        add("next-tab", Box::new(|b| b.cycle_tab(1)));
        add("previous-tab", Box::new(|b| b.cycle_tab(-1)));
        add("move-to-window", Box::new(|b| {
            if let Some(page) = b.target_page() {
                b.detach_to_window(&page);
            }
        }));
        add("close-pane", Box::new(|b| b.close_pane(b.focused.get())));
        add("move-left", Box::new(|b| {
            if let Some(page) = b.target_page() {
                b.move_page(&page, 0);
            }
        }));
        add("move-right", Box::new(|b| {
            if let Some(page) = b.target_page() {
                b.move_page(&page, 1);
            }
        }));
        add("close-others", Box::new(|b| {
            if let Some(page) = b.target_page() {
                b.close_others(&page);
            }
        }));
        add("tab-close", Box::new(|b| {
            if let Some(page) = b.target_page() {
                if let Some((view, tab)) = b.tab_of(&page) {
                    view.close_page(&tab);
                }
            }
        }));
        add("tab-reveal", Box::new(|b| {
            if let Some(path) = b.target_page().and_then(|p| p.path()) {
                reveal(&b.window, &path);
            }
        }));
        add("tab-copy-path", Box::new(|b| {
            if let Some(path) = b.target_page().and_then(|p| p.path()) {
                b.window.clipboard().set_text(&path.to_string_lossy());
                b.toast(&t("Ruta copiada"));
            }
        }));
        add("tab-favorite", Box::new(|b| {
            if let Some(path) = b.target_page().and_then(|p| p.path()) {
                prefs::toggle_favorite(&path);
            }
        }));
        add("preferences", Box::new(|b| dialogs::preferences(&b.window)));
        add("shortcuts", Box::new(|b| dialogs::shortcuts(&b.window)));
        add("about", Box::new(|b| dialogs::about(&b.window)));
        add("default-app", Box::new(|b| dialogs::default_app(&b.window)));
        add("check-updates", Box::new(|b| dialogs::check_updates(&b.window, true)));
        add("welcome", Box::new(|b| b.reusable_page().load_welcome()));
        add("whats-new", Box::new(|b| b.reusable_page().load_changelog()));
        add("clear-recent", Box::new(|_| prefs::clear_recent()));
        add("refresh-folder", Box::new(|b| b.refresh_workspace()));
        add("close-folder", Box::new(|b| b.set_workspace(None)));

        let mode = gio::SimpleAction::new_stateful("mode", Some(glib::VariantTy::STRING), &"read".to_variant());
        mode.connect_activate(glib::clone!(
            #[weak(rename_to = window)]
            self.window,
            move |action, value| {
                let Some(name) = value.and_then(|v| v.get::<String>()) else { return };
                if let Some(page) = app::bench_of(&window).and_then(|b| b.current()) {
                    page.set_mode(Mode::from_name(&name));
                    action.set_state(&name.to_variant());
                }
            }
        ));
        window.add_action(&mode);
        let focus = gio::SimpleAction::new_stateful("focus-mode", None, &false.to_variant());
        let weak_focus = weak.clone();
        focus.connect_activate(move |_, _| {
            if let Some(bench) = weak_focus.upgrade() {
                bench.toggle_focus_mode();
            }
        });
        window.add_action(&focus);
        let format = gio::SimpleAction::new("format", Some(glib::VariantTy::STRING));
        let weak_format = weak.clone();
        format.connect_activate(move |_, value| {
            let Some(action) = value.and_then(|v| v.get::<String>()).and_then(|n| FormatAction::from_name(&n)) else { return };
            if let Some(page) = weak_format.upgrade().and_then(|b| b.current()) {
                page.format(action);
            }
        });
        window.add_action(&format);

        let add_path = |name: &str, f: Box<dyn Fn(&Rc<Workbench>, PathBuf)>| {
            let action = gio::SimpleAction::new(name, Some(glib::VariantTy::STRING));
            let weak = weak.clone();
            action.connect_activate(move |_, value| {
                let Some(path) = value.and_then(|v| v.get::<String>()) else { return };
                if let Some(bench) = weak.upgrade() {
                    f(&bench, PathBuf::from(path));
                }
            });
            window.add_action(&action);
        };
        add_path("open-path", Box::new(|b, p| b.open_path(&p, OpenTarget::Here)));
        add_path("open-path-tab", Box::new(|b, p| b.open_path(&p, OpenTarget::NewTab)));
        add_path("open-path-right", Box::new(|b, p| b.open_path(&p, OpenTarget::Right)));
        add_path("reveal-path", Box::new(|b, p| reveal(&b.window, &p)));
        add_path("copy-path", Box::new(|b, p| {
            b.window.clipboard().set_text(&p.to_string_lossy());
            b.toast(&t("Ruta copiada"));
        }));
        add_path("toggle-favorite", Box::new(|_, p| prefs::toggle_favorite(&p)));
        add_path("remove-recent", Box::new(|_, p| prefs::remove_recent(&p.to_string_lossy())));
        add_path("use-folder", Box::new(|b, p| b.set_workspace(Some(p))));
        add_path("duplicate-path", Box::new(|b, p| {
            let target = crate::document::duplicate_path(&p);
            match std::fs::copy(&p, &target) {
                Ok(_) => {
                    b.refresh_workspace();
                    b.open_path(&target, OpenTarget::NewTab);
                }
                Err(error) => dialogs::alert(&b.window, &t("No se pudo guardar"), &error.to_string()),
            }
        }));
        let url = gio::SimpleAction::new("open-url", Some(glib::VariantTy::STRING));
        url.connect_activate(glib::clone!(
            #[weak(rename_to = window)]
            self.window,
            move |_, value| {
                if let Some(url) = value.and_then(|v| v.get::<String>()) {
                    gtk::UriLauncher::new(&url).launch(Some(&window), None::<&gio::Cancellable>, |_| {});
                }
            }
        ));
        window.add_action(&url);
    }

    /// Ctrl+W closes the innermost thing first: the find bar, then the tab.
    fn close_innermost(self: &Rc<Self>) {
        if self.focus_mode.get() {
            self.toggle_focus_mode();
            return;
        }
        if let Some(page) = self.current() {
            if page.close_search_if_open() {
                return;
            }
            if let Some((view, tab)) = self.tab_of(&page) {
                view.close_page(&tab);
            }
        } else {
            self.window.close();
        }
    }

    fn open_dialog(self: &Rc<Self>) {
        let dialog = gtk::FileDialog::new();
        dialog.set_title(&t("Abrir Markdown…"));
        dialog.set_filters(Some(&crate::document::markdown_filters()));
        if let Some(folder) = self.workspace().or_else(|| self.current().and_then(|p| p.path()).and_then(|p| p.parent().map(Path::to_path_buf))) {
            dialog.set_initial_folder(Some(&gio::File::for_path(folder)));
        }
        let weak = Rc::downgrade(self);
        dialog.open_multiple(Some(&self.window), None::<&gio::Cancellable>, move |result| {
            let (Some(bench), Ok(files)) = (weak.upgrade(), result) else { return };
            for (index, file) in files.iter::<gio::File>().flatten().enumerate() {
                if let Some(path) = file.path() {
                    bench.open_path(&path, if index == 0 { OpenTarget::Here } else { OpenTarget::NewTab });
                }
            }
        });
    }

    fn open_folder_dialog(self: &Rc<Self>) {
        let dialog = gtk::FileDialog::new();
        dialog.set_title(&t("Abrir carpeta"));
        let weak = Rc::downgrade(self);
        dialog.select_folder(Some(&self.window), None::<&gio::Cancellable>, move |result| {
            if let (Some(bench), Some(path)) = (weak.upgrade(), result.ok().and_then(|f| f.path())) {
                bench.set_workspace(Some(path));
            }
        });
    }

    fn paste_and_read(self: &Rc<Self>) {
        let clipboard = self.window.clipboard();
        let weak = Rc::downgrade(self);
        clipboard.read_text_async(None::<&gio::Cancellable>, move |result| {
            let (Some(bench), Ok(Some(text))) = (weak.upgrade(), result) else { return };
            if text.trim().is_empty() {
                return;
            }
            bench.reusable_page().load_pasted(&text);
        });
    }
}

fn reveal(window: &adw::ApplicationWindow, path: &Path) {
    let launcher = gtk::FileLauncher::new(Some(&gio::File::for_path(path)));
    launcher.open_containing_folder(Some(window), None::<&gio::Cancellable>, |_| {});
}

/// Asks about every document with unsaved changes, one after the other.
fn confirm_all(mut pages: Vec<DocumentPage>, done: impl FnOnce(bool) + 'static) {
    let Some(page) = pages.pop() else {
        done(true);
        return;
    };
    page.confirm_close(move |ok| {
        if ok {
            confirm_all(pages, done);
        } else {
            done(false);
        }
    });
}

fn section(items: &[(&str, &str)]) -> gio::Menu {
    let menu = gio::Menu::new();
    for (label, action) in items {
        let (name, target) = match action.split_once("::") {
            Some((n, t)) => (n, Some(t)),
            None => (*action, None),
        };
        let item = gio::MenuItem::new(Some(&t(label)), None);
        match target {
            Some(target) => item.set_action_and_target_value(Some(name), Some(&target.to_variant())),
            None => item.set_detailed_action(name),
        }
        menu.append_item(&item);
    }
    menu
}

fn main_menu() -> gio::Menu {
    let menu = gio::Menu::new();
    menu.append_section(None, &section(&[("Nueva ventana", "app.new-window"), ("Nueva pestaña", "win.new-tab"), ("Nueva nota", "win.new-note")]));
    let export = section(&[("HTML…", "win.export-html"), ("PDF…", "win.export-pdf")]);
    let file = section(&[("Guardar", "win.save"), ("Guardar como…", "win.save-as"), ("Guardar una copia como…", "win.save-copy"), ("Duplicar", "win.duplicate")]);
    file.append_submenu(Some(&t("Exportar")), &export);
    file.append_item(&gio::MenuItem::new(Some(&t("Imprimir…")), Some("win.print")));
    file.append_item(&gio::MenuItem::new(Some(&t("Volver a cargar")), Some("win.reload")));
    menu.append_section(None, &file);

    let view = gio::Menu::new();
    view.append_section(None, &section(&[("Lectura", "win.mode::read"), ("Editor", "win.mode::edit"), ("Código", "win.mode::source"), ("Dividida", "win.mode::split")]));
    view.append_section(None, &section(&[("Alternar lectura y edición", "win.toggle-editing"), ("Modo enfoque", "win.focus-mode"), ("Mostrar u ocultar la barra lateral", "win.toggle-sidebar")]));
    view.append_section(None, &section(&[("Aumentar texto", "win.zoom-in"), ("Reducir texto", "win.zoom-out"), ("Tamaño original", "win.zoom-reset")]));
    view.append_section(None, &section(&[("Título anterior", "win.previous-heading"), ("Título siguiente", "win.next-heading"), ("Buscar…", "win.find")]));
    let format = gio::Menu::new();
    format.append_section(None, &section(&[("Negrita", "win.format::bold"), ("Cursiva", "win.format::italic"), ("Tachado", "win.format::strikethrough"), ("Código en línea", "win.format::code"), ("Enlace", "win.format::link")]));
    format.append_section(None, &section(&[("Título 1", "win.format::heading1"), ("Título 2", "win.format::heading2"), ("Título 3", "win.format::heading3"), ("Texto normal", "win.format::paragraph")]));
    format.append_section(None, &section(&[("Lista", "win.format::bullet-list"), ("Lista numerada", "win.format::numbered-list"), ("Lista de tareas", "win.format::task-list"), ("Cita", "win.format::quote"), ("Bloque de código", "win.format::code-block"), ("Tabla", "win.format::table"), ("Separador", "win.format::rule")]));
    let window = gio::Menu::new();
    window.append_section(None, &section(&[("Pestaña siguiente", "win.next-tab"), ("Pestaña anterior", "win.previous-tab"), ("Mover la pestaña a una ventana nueva", "win.move-to-window")]));
    window.append_section(None, &section(&[("Mover al panel izquierdo", "win.move-left"), ("Mover al panel derecho", "win.move-right"), ("Cerrar panel", "win.close-pane")]));
    let help = gio::Menu::new();
    help.append_section(None, &section(&[("Bienvenida", "win.welcome"), ("Novedades", "win.whats-new")]));
    help.append_section(
        None,
        &section(&[
            ("Guía de Markdown", "win.open-url::https://www.markdownguide.org/basic-syntax/"),
            ("Especificación GFM", "win.open-url::https://github.github.com/gfm/"),
            ("Informar de un problema", "win.open-url::https://github.com/glozahn/md-lite/issues"),
        ]),
    );
    help.append_section(None, &section(&[("Usar MD Lite para abrir .md…", "win.default-app"), ("Buscar actualizaciones…", "win.check-updates")]));
    let submenus = gio::Menu::new();
    submenus.append_submenu(Some(&t("Vista")), &view);
    submenus.append_submenu(Some(&t("Formato")), &format);
    submenus.append_submenu(Some(&t("Ventana")), &window);
    submenus.append_submenu(Some(&t("Ayuda")), &help);
    menu.append_section(None, &submenus);
    menu.append_section(None, &section(&[("Ajustes…", "win.preferences"), ("Atajos de teclado", "win.shortcuts"), ("Acerca de MD Lite", "win.about")]));
    menu
}

fn tab_menu() -> gio::Menu {
    let menu = gio::Menu::new();
    menu.append_section(None, &section(&[("Mover a una ventana nueva", "win.move-to-window"), ("Mover al panel izquierdo", "win.move-left"), ("Mover al panel derecho", "win.move-right")]));
    menu.append_section(None, &section(&[("Mostrar en la carpeta", "win.tab-reveal"), ("Copiar ruta", "win.tab-copy-path"), ("Añadir a favoritos", "win.tab-favorite")]));
    menu.append_section(None, &section(&[("Cerrar las demás", "win.close-others"), ("Cerrar pestaña", "win.tab-close")]));
    menu
}
