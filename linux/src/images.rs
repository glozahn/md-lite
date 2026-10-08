//! Image loading for documents: local files and data URLs right away, remote images only
//! when the reader allows them, downloaded in the background.

use gtk::prelude::*;
use gtk::{gdk, gio, glib};
use soup::prelude::*;
use std::cell::RefCell;
use std::collections::{HashMap, HashSet};

const MAX_BYTES: u64 = 20_000_000;

thread_local! {
    static CACHE: RefCell<HashMap<String, Option<gdk::Texture>>> = RefCell::new(HashMap::new());
    static LOADING: RefCell<HashSet<String>> = RefCell::new(HashSet::new());
    static SESSION: soup::Session = {
        let session = soup::Session::new();
        session.set_user_agent("MD Lite");
        session.set_timeout(20);
        session
    };
}

pub fn is_remote(url: &str) -> bool {
    let lower = url.to_lowercase();
    lower.starts_with("http://") || lower.starts_with("https://")
}

/// Local file or data URL, cached by path and modification time.
pub fn local(url: &str) -> Option<gdk::Texture> {
    let lower = url.to_lowercase();
    if lower.starts_with("data:") {
        return cached(url, || {
            let (meta, data) = url.split_once(',')?;
            if !meta.contains(";base64") || data.len() > 14_000_000 {
                return None;
            }
            let bytes = glib::base64_decode(data.trim());
            gdk::Texture::from_bytes(&glib::Bytes::from_owned(bytes)).ok()
        });
    }
    if !lower.starts_with("file:") {
        return None;
    }
    let file = gio::File::for_uri(url);
    let path = file.path()?;
    let meta = std::fs::metadata(&path).ok()?;
    if !meta.is_file() || meta.len() > MAX_BYTES {
        return None;
    }
    let stamp = meta.modified().ok().and_then(|m| m.duration_since(std::time::UNIX_EPOCH).ok()).map_or(0, |d| d.as_millis());
    cached(&format!("{url}#{stamp}"), || gdk::Texture::from_filename(&path).ok())
}

fn cached(key: &str, load: impl FnOnce() -> Option<gdk::Texture>) -> Option<gdk::Texture> {
    if let Some(found) = CACHE.with(|c| c.borrow().get(key).cloned()) {
        return found;
    }
    let texture = load();
    CACHE.with(|c| {
        let mut cache = c.borrow_mut();
        if cache.len() > 300 {
            cache.clear();
        }
        cache.insert(key.to_string(), texture.clone());
    });
    texture
}

/// A remote image that was already downloaded.
pub fn remote(url: &str) -> Option<gdk::Texture> {
    CACHE.with(|c| c.borrow().get(url).cloned().flatten())
}

pub fn remote_failed(url: &str) -> bool {
    CACHE.with(|c| matches!(c.borrow().get(url), Some(None)))
}

/// Downloads a remote image once; `done` runs on the main thread when it finishes.
pub fn fetch(url: &str, done: impl FnOnce() + 'static) {
    if CACHE.with(|c| c.borrow().contains_key(url)) || !LOADING.with(|l| l.borrow_mut().insert(url.to_string())) {
        return;
    }
    let url = url.to_string();
    glib::MainContext::default().spawn_local(async move {
        let texture = download(&url).await;
        CACHE.with(|c| c.borrow_mut().insert(url.clone(), texture));
        LOADING.with(|l| l.borrow_mut().remove(&url));
        done();
    });
}

async fn download(url: &str) -> Option<gdk::Texture> {
    let message = soup::Message::new("GET", url).ok()?;
    let session = SESSION.with(Clone::clone);
    let bytes = session.send_and_read_future(&message, glib::Priority::DEFAULT).await.ok()?;
    if message.status() != soup::Status::Ok || bytes.len() as u64 > MAX_BYTES {
        return None;
    }
    gdk::Texture::from_bytes(&bytes).ok()
}

/// Downloads text (used for the update check).
pub async fn fetch_text(url: &str) -> Option<String> {
    let message = soup::Message::new("GET", url).ok()?;
    message.request_headers()?.append("Accept", "application/vnd.github+json");
    let session = SESSION.with(Clone::clone);
    let bytes = session.send_and_read_future(&message, glib::Priority::DEFAULT).await.ok()?;
    if message.status() != soup::Status::Ok {
        return None;
    }
    String::from_utf8(bytes.to_vec()).ok()
}
