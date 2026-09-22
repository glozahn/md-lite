use std::fs;
use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;

const MAX_TEXT: u64 = 5_000_000;
const MAX_IMAGE: u64 = 20_000_000;
const IMAGE_EXTENSIONS: [&str; 9] = ["png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "ico", "avif"];

fn error(err: impl std::fmt::Display) -> String {
    err.to_string()
}

#[tauri::command]
fn read_text(path: String) -> Result<String, String> {
    let meta = fs::metadata(&path).map_err(error)?;
    if !meta.is_file() {
        return Err("not-a-file".into());
    }
    if meta.len() > MAX_TEXT {
        return Err("too-large".into());
    }
    let bytes = fs::read(&path).map_err(error)?;
    String::from_utf8(bytes).map_err(|_| "not-utf8".to_string())
}

/// Writes through a temporary file and a rename so a crash never leaves a half-written document.
#[tauri::command]
fn write_text(path: String, contents: String) -> Result<(), String> {
    let target = PathBuf::from(&path);
    let name = target.file_name().ok_or("invalid-path")?.to_string_lossy().to_string();
    let temporary = target.with_file_name(format!(".{name}.mdlite-tmp"));
    fs::write(&temporary, contents.as_bytes()).map_err(error)?;
    fs::rename(&temporary, &target).map_err(|err| {
        let _ = fs::remove_file(&temporary);
        error(err)
    })
}

#[tauri::command]
fn modified(path: String) -> Result<u64, String> {
    let meta = fs::metadata(&path).map_err(error)?;
    let time = meta.modified().map_err(error)?;
    Ok(time.duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0))
}

/// Local images referenced by a document. Only image files, only up to 20 MB.
#[tauri::command]
fn read_image(path: String) -> Result<tauri::ipc::Response, String> {
    let extension = Path::new(&path)
        .extension()
        .map(|e| e.to_string_lossy().to_lowercase())
        .unwrap_or_default();
    if !IMAGE_EXTENSIONS.contains(&extension.as_str()) {
        return Err("not-an-image".into());
    }
    let meta = fs::metadata(&path).map_err(error)?;
    if meta.len() > MAX_IMAGE {
        return Err("too-large".into());
    }
    Ok(tauri::ipc::Response::new(fs::read(&path).map_err(error)?))
}

#[derive(serde::Serialize)]
struct Node {
    name: String,
    path: String,
    dir: bool,
    children: Vec<Node>,
}

const SKIPPED: [&str; 16] = [
    "node_modules", ".git", ".build", "build", "dist", "DerivedData", "Pods", ".next", "target", "vendor",
    ".venv", "venv", "__pycache__", ".swiftpm", "Carthage", "bin",
];
const MARKDOWN: [&str; 4] = ["md", "markdown", "mdown", "mkd"];

fn scan(folder: &Path, depth: usize, budget: &mut usize) -> Vec<Node> {
    if depth >= 10 || *budget == 0 {
        return Vec::new();
    }
    let Ok(entries) = fs::read_dir(folder) else { return Vec::new() };
    let (mut folders, mut files) = (Vec::new(), Vec::new());
    for entry in entries.flatten() {
        if *budget == 0 {
            break;
        }
        let name = entry.file_name().to_string_lossy().to_string();
        if name.starts_with('.') {
            continue;
        }
        let Ok(kind) = entry.file_type() else { continue };
        let path = entry.path();
        if kind.is_dir() {
            if SKIPPED.contains(&name.as_str()) {
                continue;
            }
            let children = scan(&path, depth + 1, budget);
            if !children.is_empty() {
                folders.push(Node { name, path: path.to_string_lossy().to_string(), dir: true, children });
            }
        } else if kind.is_file() {
            let extension = path.extension().map(|e| e.to_string_lossy().to_lowercase()).unwrap_or_default();
            if MARKDOWN.contains(&extension.as_str()) {
                *budget -= 1;
                files.push(Node { name, path: path.to_string_lossy().to_string(), dir: false, children: Vec::new() });
            }
        }
    }
    folders.sort_by_key(|node| node.name.to_lowercase());
    files.sort_by_key(|node| node.name.to_lowercase());
    folders.extend(files);
    folders
}

/// Markdown files under a working folder, as a tree (hidden and generated folders skipped).
#[tauri::command]
fn list_markdown(path: String) -> Result<Vec<Node>, String> {
    if !Path::new(&path).is_dir() {
        return Err("not-a-folder".into());
    }
    let mut budget = 4000usize;
    Ok(scan(Path::new(&path), 0, &mut budget))
}

#[tauri::command]
fn is_dir(path: String) -> bool {
    Path::new(&path).is_dir()
}

/// The document passed on the command line (double-click in the file manager).
#[tauri::command]
fn initial_file() -> Option<String> {
    std::env::args()
        .skip(1)
        .find(|arg| !arg.starts_with('-') && Path::new(arg).exists())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_opener::init())
        .invoke_handler(tauri::generate_handler![read_text, write_text, modified, read_image, initial_file, list_markdown, is_dir])
        .run(tauri::generate_context!())
        .expect("error while running MD Lite");
}
