//! Renders Mermaid diagrams offline in a hidden WebKit view, only when a document contains one.
//! The library ships xz-compressed inside the binary and network access is blocked.

use crate::markdown::render::MermaidState;
use gtk::{gdk, glib};
use std::cell::RefCell;
use std::collections::{HashMap, VecDeque};
use std::rc::{Rc, Weak};
use webkit6::prelude::*;

static LIBRARY: &[u8] = include_bytes!("../../Resources/Mermaid/mermaid.min.js.xz");

#[derive(Clone)]
pub enum Diagram {
    Image { texture: gdk::Texture, width: i32 },
    Failure(String),
}

#[derive(Default)]
struct State {
    view: Option<webkit6::WebView>,
    ready: bool,
    booting: bool,
    working: bool,
    queue: VecDeque<(String, String, bool)>,
    results: HashMap<String, Diagram>,
    order: VecDeque<String>,
    listeners: Vec<Weak<dyn Fn()>>,
}

thread_local! {
    static STATE: RefCell<State> = RefCell::new(State::default());
}

fn key(code: &str, dark: bool) -> String {
    format!("{}:{code}", if dark { "d" } else { "l" })
}

/// Called whenever a diagram finishes; listeners re-render documents that show diagrams.
pub fn add_listener(listener: &Rc<dyn Fn()>) {
    STATE.with(|s| s.borrow_mut().listeners.push(Rc::downgrade(listener)));
}

pub fn result(code: &str, dark: bool) -> Option<Diagram> {
    STATE.with(|s| s.borrow().results.get(&key(code, dark)).cloned())
}

/// The state for the renderer; starts drawing the diagram when it is new.
pub fn state(code: &str, dark: bool) -> MermaidState {
    let k = key(code, dark);
    let queued = STATE.with(|s| {
        let mut s = s.borrow_mut();
        match s.results.get(&k) {
            Some(Diagram::Image { .. }) => return Some(MermaidState::Ready),
            Some(Diagram::Failure(message)) => return Some(MermaidState::Failed(message.clone())),
            None => {}
        }
        if !s.queue.iter().any(|(q, _, _)| *q == k) {
            s.queue.push_back((k.clone(), code.to_string(), dark));
        }
        None
    });
    if let Some(state) = queued {
        return state;
    }
    glib::idle_add_local_once(start);
    MermaidState::Pending
}

fn start() {
    let (needs_boot, job) = STATE.with(|s| {
        let mut s = s.borrow_mut();
        if s.view.is_none() {
            if s.booting {
                return (false, None);
            }
            s.booting = true;
            return (true, None);
        }
        if !s.ready || s.working {
            return (false, None);
        }
        let job = s.queue.pop_front();
        s.working = job.is_some();
        (false, job)
    });
    if needs_boot {
        boot();
        return;
    }
    if let Some(job) = job {
        render(job);
    }
}

fn boot() {
    let script = match decompress() {
        Some(script) => script,
        None => {
            fail_all("Unable to load Mermaid.");
            return;
        }
    };
    let manager = webkit6::UserContentManager::new();
    manager.add_script(&webkit6::UserScript::new(
        &script,
        webkit6::UserContentInjectedFrames::TopFrame,
        webkit6::UserScriptInjectionTime::Start,
        &[],
        &[],
    ));
    let session = webkit6::NetworkSession::new_ephemeral();
    let view = webkit6::WebView::builder().user_content_manager(&manager).network_session(&session).build();
    if let Some(settings) = webkit6::prelude::WebViewExt::settings(&view) {
        settings.set_enable_javascript(true);
        settings.set_auto_load_images(false);
        settings.set_enable_page_cache(false);
    }
    view.connect_load_changed(|_, event| {
        if event == webkit6::LoadEvent::Finished {
            STATE.with(|s| s.borrow_mut().ready = true);
            start();
        }
    });
    // Block every network request: diagrams render from the bundled library only.
    let page = "<!doctype html><html><head><meta charset=utf-8><style>html,body{margin:0;background:transparent}#c{display:inline-block}</style></head><body><div id=c></div></body></html>";
    let pending_view = view.clone();
    block_network(&manager, move || pending_view.load_html(page, Some("about:blank")));
    STATE.with(|s| s.borrow_mut().view = Some(view));
}

/// Adds a content filter that blocks every network request to a web view's content manager,
/// then calls `ready`.
pub fn block_network(manager: &webkit6::UserContentManager, ready: impl FnOnce() + 'static) {
    let filters = glib::user_cache_dir().join("md-lite").join("filters");
    let store = webkit6::UserContentFilterStore::new(&filters.to_string_lossy());
    let rules = br#"[{"trigger":{"url-filter":"^https?:"},"action":{"type":"block"}},{"trigger":{"url-filter":"^wss?:"},"action":{"type":"block"}},{"trigger":{"url-filter":"^ftp:"},"action":{"type":"block"}}]"#;
    let manager = manager.clone();
    store.save("mdlite-offline", &glib::Bytes::from_static(rules), None::<&gtk::gio::Cancellable>, move |filter| {
        if let Ok(filter) = filter {
            manager.add_filter(&filter);
        }
        ready();
    });
}

fn decompress() -> Option<String> {
    let mut reader = std::io::BufReader::new(LIBRARY);
    let mut out = Vec::new();
    lzma_rs::xz_decompress(&mut reader, &mut out).ok()?;
    String::from_utf8(out).ok()
}

const RENDER: &str = r#"
mermaid.initialize({startOnLoad: false, securityLevel: 'strict', theme: dark === '1' ? 'dark' : 'neutral',
  fontFamily: '"Adwaita Sans", Cantarell, "Noto Sans", sans-serif', htmlLabels: false,
  flowchart: {htmlLabels: false}, themeVariables: {background: 'transparent'}});
const host = document.getElementById('c');
host.innerHTML = '';
const {svg} = await mermaid.render('m' + Math.random().toString(36).slice(2), code);
host.innerHTML = svg;
const el = host.querySelector('svg');
el.style.maxWidth = 'none';
const box = el.viewBox.baseVal;
let w = box && box.width ? box.width : el.getBoundingClientRect().width;
let h = box && box.height ? box.height : el.getBoundingClientRect().height;
el.setAttribute('width', w);
el.setAttribute('height', h);
const xml = new XMLSerializer().serializeToString(el);
try {
  const img = new Image();
  await new Promise((ok, fail) => { img.onload = ok; img.onerror = () => fail(new Error('image')); img.src = 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(xml); });
  const scale = 2;
  const canvas = document.createElement('canvas');
  canvas.width = Math.ceil(w * scale);
  canvas.height = Math.ceil(h * scale);
  const ctx = canvas.getContext('2d');
  ctx.scale(scale, scale);
  ctx.drawImage(img, 0, 0, w, h);
  return JSON.stringify({png: canvas.toDataURL('image/png'), w: Math.ceil(w), h: Math.ceil(h)});
} catch (e) {
  return JSON.stringify({svg: xml, w: Math.ceil(w), h: Math.ceil(h)});
}
"#;

fn render(job: (String, String, bool)) {
    let Some(view) = STATE.with(|s| s.borrow().view.clone()) else { return };
    let (k, code, dark) = job;
    let arguments = glib::VariantDict::new(None);
    arguments.insert("code", &code);
    arguments.insert("dark", if dark { "1" } else { "0" });
    view.call_async_javascript_function(RENDER, Some(&arguments.end()), None, None, None::<&gtk::gio::Cancellable>, move |result| {
        let outcome = match result {
            Ok(value) => decode(&value.to_str()).unwrap_or_else(|| Diagram::Failure("Unable to draw the diagram.".into())),
            Err(error) => Diagram::Failure(error.message().replace("Error: ", "").trim().to_string()),
        };
        STATE.with(|s| {
            let mut s = s.borrow_mut();
            s.results.insert(k.clone(), outcome);
            s.order.push_back(k);
            if s.order.len() > 60 {
                if let Some(old) = s.order.pop_front() {
                    s.results.remove(&old);
                }
            }
            s.working = false;
        });
        notify();
        start();
    });
}

fn decode(json: &str) -> Option<Diagram> {
    let value: serde_json::Value = serde_json::from_str(json).ok()?;
    let width = value["w"].as_f64()? as i32;
    let height = value["h"].as_f64()? as i32;
    let bytes = if let Some(png) = value["png"].as_str() {
        glib::base64_decode(png.split_once(',')?.1)
    } else {
        value["svg"].as_str()?.as_bytes().to_vec()
    };
    let texture = gdk::Texture::from_bytes(&glib::Bytes::from_owned(bytes)).ok()?;
    (width > 0 && height > 0).then_some(Diagram::Image { texture, width })
}

fn fail_all(message: &str) {
    STATE.with(|s| {
        let mut s = s.borrow_mut();
        let jobs: Vec<String> = s.queue.drain(..).map(|(k, _, _)| k).collect();
        for k in jobs {
            s.results.insert(k, Diagram::Failure(message.to_string()));
        }
    });
    notify();
}

fn notify() {
    let listeners: Vec<Rc<dyn Fn()>> = STATE.with(|s| {
        let mut s = s.borrow_mut();
        s.listeners.retain(|l| l.strong_count() > 0);
        s.listeners.iter().filter_map(Weak::upgrade).collect()
    });
    for listener in listeners {
        listener();
    }
}
