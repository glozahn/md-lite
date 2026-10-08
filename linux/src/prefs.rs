//! Preferences, recent files and favorites, stored as JSON in the user's config folder.
//! Nothing leaves the machine.

use serde::{Deserialize, Serialize};
use std::cell::RefCell;
use std::path::{Path, PathBuf};
use std::rc::{Rc, Weak};

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct Prefs {
    pub appearance: String,
    pub language: String,
    pub accent: String,
    pub font_size: f32,
    pub text_width: String,
    pub sidebar_visible: bool,
    pub sidebar_page: String,
    pub always_load_remote_images: bool,
    pub check_updates: bool,
    pub recent: Vec<String>,
    pub favorites: Vec<String>,
    pub split_ratio: f64,
    pub window_width: i32,
    pub window_height: i32,
    pub maximized: bool,
    pub last_version: String,
    /// Files and working folder open when the app last quit, per window.
    pub session: Vec<SessionWindow>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Default)]
#[serde(default)]
pub struct SessionWindow {
    pub files: Vec<String>,
    pub workspace: Option<String>,
}

impl Default for Prefs {
    fn default() -> Prefs {
        Prefs {
            appearance: "system".into(),
            language: "system".into(),
            accent: "system".into(),
            font_size: 17.0,
            text_width: "normal".into(),
            sidebar_visible: true,
            sidebar_page: "outline".into(),
            always_load_remote_images: false,
            check_updates: false,
            recent: Vec::new(),
            favorites: Vec::new(),
            split_ratio: 0.5,
            window_width: 1180,
            window_height: 820,
            maximized: false,
            last_version: String::new(),
            session: Vec::new(),
        }
    }
}

impl Prefs {
    pub fn column_width(&self) -> i32 {
        match self.text_width.as_str() {
            "narrow" => 620,
            "wide" => 980,
            "full" => 100_000,
            _ => 780,
        }
    }

    pub fn resolved_language(&self) -> &'static str {
        crate::i18n::resolve(&self.language)
    }
}

fn path() -> PathBuf {
    glib::user_config_dir().join("md-lite").join("settings.json")
}

thread_local! {
    static PREFS: RefCell<Prefs> = RefCell::new(load());
    static LISTENERS: RefCell<Vec<Weak<dyn Fn()>>> = const { RefCell::new(Vec::new()) };
    static LIST_LISTENERS: RefCell<Vec<Weak<dyn Fn()>>> = const { RefCell::new(Vec::new()) };
}

fn load() -> Prefs {
    std::fs::read_to_string(path()).ok().and_then(|s| serde_json::from_str(&s).ok()).unwrap_or_default()
}

pub fn get() -> Prefs {
    PREFS.with(|p| p.borrow().clone())
}

pub fn with<R>(f: impl FnOnce(&Prefs) -> R) -> R {
    PREFS.with(|p| f(&p.borrow()))
}

/// Changes preferences, saves them, and tells every listener when something visible changed.
pub fn update(f: impl FnOnce(&mut Prefs)) {
    let (looks, lists) = PREFS.with(|p| {
        let before = p.borrow().clone();
        f(&mut p.borrow_mut());
        let after = p.borrow().clone();
        save(&after);
        (visible(&before) != visible(&after), (&before.recent, &before.favorites) != (&after.recent, &after.favorites))
    });
    if looks {
        notify(&LISTENERS);
    }
    if lists {
        notify(&LIST_LISTENERS);
    }
}

/// Silent update for bookkeeping (window size, session) that needs no redraw.
pub fn update_quietly(f: impl FnOnce(&mut Prefs)) {
    PREFS.with(|p| {
        f(&mut p.borrow_mut());
        save(&p.borrow());
    });
}

/// The preferences that change how documents look.
fn visible(p: &Prefs) -> (String, String, String, String, String, bool) {
    (
        p.appearance.clone(),
        p.language.clone(),
        p.accent.clone(),
        format!("{}", p.font_size),
        p.text_width.clone(),
        p.always_load_remote_images,
    )
}

fn save(prefs: &Prefs) {
    let file = path();
    if let Some(parent) = file.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    if let Ok(json) = serde_json::to_string_pretty(prefs) {
        let temporary = file.with_extension("json.tmp");
        if std::fs::write(&temporary, json).is_ok() {
            let _ = std::fs::rename(&temporary, &file);
        }
    }
}

/// Runs when a preference that changes how documents look changes.
pub fn add_listener(listener: &Rc<dyn Fn()>) {
    LISTENERS.with(|l| l.borrow_mut().push(Rc::downgrade(listener)));
}

/// Runs when the recent files or favorites change.
pub fn add_list_listener(listener: &Rc<dyn Fn()>) {
    LIST_LISTENERS.with(|l| l.borrow_mut().push(Rc::downgrade(listener)));
}

type Listeners = std::thread::LocalKey<RefCell<Vec<Weak<dyn Fn()>>>>;

fn notify(listeners: &'static Listeners) {
    let listeners: Vec<Rc<dyn Fn()>> = listeners.with(|l| {
        let mut l = l.borrow_mut();
        l.retain(|w| w.strong_count() > 0);
        l.iter().filter_map(Weak::upgrade).collect()
    });
    for listener in listeners {
        listener();
    }
}

pub fn add_recent(path: &Path) {
    let value = path.to_string_lossy().to_string();
    update(|p| {
        p.recent.retain(|r| *r != value);
        p.recent.insert(0, value);
        p.recent.truncate(12);
    });
}

pub fn remove_recent(path: &str) {
    update(|p| p.recent.retain(|r| r != path));
}

pub fn clear_recent() {
    update(|p| p.recent.clear());
}

pub fn is_favorite(path: &Path) -> bool {
    let value = path.to_string_lossy();
    with(|p| p.favorites.iter().any(|f| *f == value))
}

pub fn toggle_favorite(path: &Path) {
    let value = path.to_string_lossy().to_string();
    update(|p| {
        if let Some(index) = p.favorites.iter().position(|f| *f == value) {
            p.favorites.remove(index);
        } else {
            p.favorites.push(value);
        }
    });
}
