//! The application: windows, session, styles, accelerators and command-line files.

use crate::document::DocumentPage;
use crate::prefs;
use crate::window::Workbench;
use adw::prelude::*;
use gtk::{gdk, gio, glib};
use std::cell::RefCell;
use std::path::{Path, PathBuf};
use std::rc::Rc;

pub const APP_ID: &str = "io.github.glozahn.MDLite";

thread_local! {
    static BENCHES: RefCell<Vec<Rc<Workbench>>> = const { RefCell::new(Vec::new()) };
    static ACCENT: gtk::CssProvider = gtk::CssProvider::new();
    static LISTENER: RefCell<Option<Rc<dyn Fn()>>> = const { RefCell::new(None) };
}

pub fn register(bench: &Rc<Workbench>) {
    BENCHES.with(|b| b.borrow_mut().push(bench.clone()));
}

pub fn unregister(bench: &Rc<Workbench>) {
    BENCHES.with(|b| b.borrow_mut().retain(|x| !Rc::ptr_eq(x, bench)));
}

pub fn count() -> usize {
    BENCHES.with(|b| b.borrow().len())
}

pub fn benches() -> Vec<Rc<Workbench>> {
    BENCHES.with(|b| b.borrow().clone())
}

pub fn bench_of(window: &impl IsA<gtk::Window>) -> Option<Rc<Workbench>> {
    let window = window.as_ref();
    benches().into_iter().find(|b| b.window.upcast_ref::<gtk::Window>() == window)
}

/// The window in front, if any.
fn active_bench(app: &adw::Application) -> Option<Rc<Workbench>> {
    app.active_window().and_then(|w| bench_of(&w)).or_else(|| benches().into_iter().last())
}

/// The tab that already shows a file, in any window.
pub fn find_open(path: &Path) -> Option<(Rc<Workbench>, DocumentPage)> {
    for bench in benches() {
        for page in bench.pages() {
            if page.path().as_deref() == Some(path) {
                return Some((bench, page));
            }
        }
    }
    None
}

pub fn save_session() {
    let windows: Vec<prefs::SessionWindow> = benches()
        .iter()
        .map(|bench| prefs::SessionWindow {
            files: bench.pages().iter().filter_map(|p| p.path()).map(|p| p.to_string_lossy().to_string()).collect(),
            workspace: bench.workspace().map(|w| w.to_string_lossy().to_string()),
        })
        .filter(|w| !w.files.is_empty() || w.workspace.is_some())
        .collect();
    prefs::update_quietly(|p| p.session = windows);
}

fn apply_appearance() {
    let (appearance, accent, language) = prefs::with(|p| (p.appearance.clone(), p.accent.clone(), p.resolved_language()));
    crate::i18n::set_language(language);
    let manager = adw::StyleManager::default();
    manager.set_color_scheme(match appearance.as_str() {
        "light" => adw::ColorScheme::ForceLight,
        "dark" => adw::ColorScheme::ForceDark,
        _ => adw::ColorScheme::Default,
    });
    let dark = manager.is_dark();
    let mut css = String::new();
    let named = |name: &str| match name {
        "teal" => Some(adw::AccentColor::Teal),
        "blue" => Some(adw::AccentColor::Blue),
        "purple" => Some(adw::AccentColor::Purple),
        "pink" => Some(adw::AccentColor::Pink),
        "orange" => Some(adw::AccentColor::Orange),
        "green" => Some(adw::AccentColor::Green),
        _ => None,
    };
    if let Some(color) = named(&accent) {
        let bg = color.to_rgba();
        let fg = color.to_standalone_rgba(dark);
        css.push_str(&format!(":root {{ --accent-bg-color: {}; --accent-color: {}; }}\n", bg, fg));
    }
    let system = manager.accent_color().to_rgba();
    css.push_str(&format!(".md-swatch-system {{ background: conic-gradient(from 45deg, {}, #33b2a4, #3584e4, #9141ac, #e66191, #ff7800, #3a944a, {}); }}\n", system, system));
    for name in ["teal", "blue", "purple", "pink", "orange", "green"] {
        if let Some(color) = named(name) {
            css.push_str(&format!(".md-swatch-{name} {{ background: {}; }}\n", color.to_rgba()));
        }
    }
    ACCENT.with(|p| p.load_from_string(&css));
}

fn install_styles() {
    let Some(display) = gdk::Display::default() else { return };
    let provider = gtk::CssProvider::new();
    provider.load_from_string(include_str!("../data/style.css"));
    gtk::style_context_add_provider_for_display(&display, &provider, gtk::STYLE_PROVIDER_PRIORITY_APPLICATION);
    ACCENT.with(|p| gtk::style_context_add_provider_for_display(&display, p, gtk::STYLE_PROVIDER_PRIORITY_APPLICATION + 1));
    let theme = gtk::IconTheme::for_display(&display);
    let local = concat!(env!("CARGO_MANIFEST_DIR"), "/data/icons");
    if Path::new(local).exists() {
        theme.add_search_path(local);
    }
}

fn set_accels(app: &adw::Application) {
    let accels: &[(&str, &[&str])] = &[
        ("app.new-window", &["<Ctrl><Shift>n"]),
        ("app.quit", &["<Ctrl>q"]),
        ("win.new-tab", &["<Ctrl>t"]),
        ("win.new-note", &["<Ctrl>n"]),
        ("win.open", &["<Ctrl>o"]),
        ("win.open-folder", &["<Ctrl><Shift>o"]),
        ("win.paste-read", &["<Ctrl><Shift>v"]),
        ("win.save", &["<Ctrl>s"]),
        ("win.save-as", &["<Ctrl><Shift>s"]),
        ("win.reload", &["<Ctrl>r"]),
        ("win.print", &["<Ctrl>p"]),
        ("win.close", &["<Ctrl>w"]),
        ("win.find", &["<Ctrl>f"]),
        ("win.find-next", &["<Ctrl>g", "F3"]),
        ("win.find-previous", &["<Ctrl><Shift>g", "<Shift>F3"]),
        ("win.mode::read", &["<Ctrl>1"]),
        ("win.mode::edit", &["<Ctrl>2"]),
        ("win.mode::source", &["<Ctrl>3"]),
        ("win.mode::split", &["<Ctrl>4"]),
        ("win.toggle-editing", &["<Ctrl>e"]),
        ("win.focus-mode", &["<Ctrl><Shift>f", "F11"]),
        ("win.toggle-sidebar", &["F9", "<Ctrl>backslash"]),
        ("win.zoom-in", &["<Ctrl>plus", "<Ctrl>equal", "<Ctrl>KP_Add"]),
        ("win.zoom-out", &["<Ctrl>minus", "<Ctrl>KP_Subtract"]),
        ("win.zoom-reset", &["<Ctrl>0", "<Ctrl>KP_0"]),
        ("win.previous-heading", &["<Ctrl><Alt>Up"]),
        ("win.next-heading", &["<Ctrl><Alt>Down"]),
        ("win.format::bold", &["<Ctrl>b"]),
        ("win.format::italic", &["<Ctrl>i"]),
        ("win.format::strikethrough", &["<Ctrl><Shift>x"]),
        ("win.format::code", &["<Ctrl><Shift>k"]),
        ("win.format::link", &["<Ctrl>k"]),
        ("win.format::heading1", &["<Ctrl><Alt>1"]),
        ("win.format::heading2", &["<Ctrl><Alt>2"]),
        ("win.format::heading3", &["<Ctrl><Alt>3"]),
        ("win.format::paragraph", &["<Ctrl><Alt>0"]),
        ("win.format::bullet-list", &["<Ctrl><Shift>7", "<Ctrl><Shift>ampersand", "<Ctrl><Shift>slash"]),
        ("win.format::numbered-list", &["<Ctrl><Shift>9", "<Ctrl><Shift>parenleft", "<Ctrl><Shift>parenright"]),
        ("win.format::task-list", &["<Ctrl><Shift>l"]),
        ("win.format::quote", &["<Ctrl>apostrophe"]),
        ("win.format::code-block", &["<Ctrl><Shift>m"]),
        ("win.format::table", &["<Ctrl><Alt>t"]),
        ("win.format::rule", &["<Ctrl><Alt>minus"]),
        ("win.next-tab", &["<Ctrl><Shift>bracketright", "<Ctrl>braceright"]),
        ("win.previous-tab", &["<Ctrl><Shift>bracketleft", "<Ctrl>braceleft"]),
        ("win.move-to-window", &["<Ctrl><Alt>n"]),
        ("win.close-pane", &["<Ctrl><Alt>w"]),
        ("win.move-left", &["<Ctrl><Alt>Left"]),
        ("win.move-right", &["<Ctrl><Alt>Right"]),
        ("win.preferences", &["<Ctrl>comma"]),
        ("win.shortcuts", &["<Ctrl>slash", "<Ctrl>question"]),
    ];
    for (action, keys) in accels {
        app.set_accels_for_action(action, keys);
    }
}

/// A window showing a page: the welcome page when nothing else asks to open.
pub fn new_window(app: &adw::Application, page: Option<DocumentPage>, workspace: Option<PathBuf>) -> Rc<Workbench> {
    let page = page.unwrap_or_else(|| {
        let page = DocumentPage::new();
        if count() == 0 {
            page.load_welcome();
        }
        page
    });
    let bench = Workbench::new(app, Some(page));
    if workspace.is_some() {
        bench.set_workspace(workspace);
    }
    bench.window.present();
    bench
}

fn restore_session(app: &adw::Application) -> bool {
    let session = prefs::with(|p| p.session.clone());
    let mut restored = false;
    for window in session {
        let files: Vec<PathBuf> = window.files.iter().map(PathBuf::from).filter(|p| p.is_file()).collect();
        let workspace = window.workspace.map(PathBuf::from).filter(|w| w.is_dir());
        if files.is_empty() && workspace.is_none() {
            continue;
        }
        let first = DocumentPage::new();
        first.make_blank();
        let bench = new_window(app, Some(first), workspace);
        for path in files {
            bench.open_path(&path, crate::sidebar::OpenTarget::Here);
        }
        if let Some(first) = bench.pages().first() {
            if bench.pages().len() > 1 && first.kind() == crate::document::Kind::Blank {
                bench.focus_page(&bench.pages()[1]);
            }
        }
        restored = true;
    }
    restored
}

pub fn run() -> glib::ExitCode {
    let app = adw::Application::builder().application_id(APP_ID).flags(gio::ApplicationFlags::HANDLES_OPEN).build();
    app.connect_startup(|app| {
        apply_appearance();
        install_styles();
        set_accels(app);
        let listener: Rc<dyn Fn()> = Rc::new(apply_appearance);
        prefs::add_listener(&listener);
        LISTENER.with(|l| *l.borrow_mut() = Some(listener));
        adw::StyleManager::default().connect_dark_notify(|_| {
            apply_appearance();
            for bench in benches() {
                for page in bench.pages() {
                    page.apply_prefs();
                }
            }
        });
        let new_window_action = gio::SimpleAction::new("new-window", None);
        new_window_action.connect_activate(glib::clone!(
            #[weak]
            app,
            move |_, _| {
                let page = DocumentPage::new();
                page.make_blank();
                let workspace = active_bench(&app).and_then(|b| b.workspace());
                new_window(&app, Some(page), workspace);
            }
        ));
        app.add_action(&new_window_action);
        let quit = gio::SimpleAction::new("quit", None);
        quit.connect_activate(glib::clone!(
            #[weak]
            app,
            move |_, _| {
                save_session();
                for bench in benches() {
                    bench.window.close();
                }
                let _ = &app;
            }
        ));
        app.add_action(&quit);
    });
    app.connect_activate(|app| {
        if let Some(bench) = active_bench(app) {
            bench.window.present();
            return;
        }
        if !restore_session(app) {
            new_window(app, None, None);
        }
        let version = env!("CARGO_PKG_VERSION");
        let (last, check) = prefs::with(|p| (p.last_version.clone(), p.check_updates));
        if !last.is_empty() && last != version {
            if let Some(bench) = active_bench(app) {
                bench.reusable_page().load_changelog();
            }
        }
        prefs::update_quietly(|p| p.last_version = version.to_string());
        if check {
            if let Some(bench) = active_bench(app) {
                crate::dialogs::check_updates(&bench.window, false);
            }
        }
        #[cfg(debug_assertions)]
        debug_screenshot(app);
    });
    app.connect_open(|app, files, _| {
        let bench = match active_bench(app) {
            Some(bench) => bench,
            None => {
                let page = DocumentPage::new();
                page.make_blank();
                new_window(app, Some(page), None)
            }
        };
        for file in files {
            if let Some(path) = file.path() {
                bench.open_path(&path, crate::sidebar::OpenTarget::Here);
            }
        }
        bench.window.present();
        #[cfg(debug_assertions)]
        debug_screenshot(app);
    });
    app.run()
}

/// Development aid: MDLITE_SCREENSHOT=out.png renders the window to a PNG and quits.
/// MDLITE_ACTIONS runs window actions first (comma separated, `name` or `name:value`).
#[cfg(debug_assertions)]
fn debug_screenshot(app: &adw::Application) {
    let Ok(path) = std::env::var("MDLITE_SCREENSHOT") else { return };
    // Stock GNOME look for documentation screenshots.
    if std::env::var("MDLITE_STOCK").is_ok() {
        if let Some(settings) = gtk::Settings::default() {
            settings.set_gtk_icon_theme_name(Some("Adwaita"));
            settings.set_gtk_decoration_layout(Some(":minimize,maximize,close"));
        }
    }
    let app = app.clone();
    let actions = std::env::var("MDLITE_ACTIONS").unwrap_or_default();
    glib::timeout_add_local_once(std::time::Duration::from_millis(1500), move || {
        if let Some(bench) = active_bench(&app) {
            for action in actions.split(',').filter(|a| !a.is_empty()) {
                let (name, value) = match action.split_once(':') {
                    Some((n, v)) => (n, Some(v.to_variant())),
                    None => (action, None),
                };
                if let Some(target) = name.strip_prefix("scroll=") {
                    let _ = target;
                }
                let _ = gtk::prelude::WidgetExt::activate_action(&bench.window, &format!("win.{name}"), value.as_ref());
            }
        }
        if let (Ok(pdf), Some(bench)) = (std::env::var("MDLITE_PDF"), active_bench(&app)) {
            if let Some(page) = bench.current() {
                page.export_pdf_to(&gio::File::for_path(pdf).uri());
            }
        }
        if let (Ok(_), Some(bench)) = (std::env::var("MDLITE_CLICK_TASK"), active_bench(&app)) {
            if let Some(page) = bench.current() {
                let mut child = page.reader().first_child();
                while let Some(widget) = child {
                    if let Ok(check) = widget.clone().downcast::<gtk::CheckButton>() {
                        check.set_active(!check.is_active());
                        break;
                    }
                    child = widget.next_sibling();
                }
            }
        }
        if let (Ok(text), Some(bench)) = (std::env::var("MDLITE_TYPE"), active_bench(&app)) {
            if let Some(page) = bench.current() {
                page.debug_type(&text.replace("\\n", "\n").replace("\\t", "\t"));
            }
        }
        let scroll = std::env::var("MDLITE_SCROLL").ok().and_then(|s| s.parse::<f64>().ok());
        let wait = std::env::var("MDLITE_WAIT").ok().and_then(|w| w.parse::<u64>().ok()).unwrap_or(0);
        let delay = wait + if scroll.is_some() { 1200 } else { 1500 };
        if let (Some(fraction), Some(bench)) = (scroll, active_bench(&app)) {
            if let Some(page) = bench.current() {
                page.debug_scroll(fraction);
            }
        }
        let attempts = std::cell::Cell::new(0);
        glib::timeout_add_local(std::time::Duration::from_millis(delay), move || {
            attempts.set(attempts.get() + 1);
            let mut written = false;
            if let Some(bench) = active_bench(&app) {
                // The whole window shows dialogs; some frames only render through the content.
                let candidates: Vec<gtk::Widget> = [Some(bench.window.clone().upcast()), bench.window.content()].into_iter().flatten().collect();
                for widget in candidates {
                    let paintable = gtk::WidgetPaintable::new(Some(&widget));
                    let snapshot = gtk::Snapshot::new();
                    paintable.snapshot(&snapshot, widget.width() as f64, widget.height() as f64);
                    if let (Some(node), Some(renderer)) = (snapshot.to_node(), bench.window.renderer()) {
                        let texture = renderer.render_texture(&node, None);
                        written = std::fs::write(&path, texture.save_to_png_bytes()).is_ok();
                        break;
                    }
                }
            }
            if !written && attempts.get() < 8 {
                return glib::ControlFlow::Continue;
            }
            for bench in benches() {
                bench.window.destroy();
            }
            app.quit();
            glib::ControlFlow::Break
        });
    });
}
