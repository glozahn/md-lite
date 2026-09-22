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

/// The document passed on the command line (double-click in the file manager).
#[tauri::command]
fn initial_file() -> Option<String> {
    std::env::args()
        .skip(1)
        .find(|arg| !arg.starts_with('-') && Path::new(arg).is_file())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_opener::init())
        .invoke_handler(tauri::generate_handler![read_text, write_text, modified, read_image, initial_file])
        .run(tauri::generate_context!())
        .expect("error while running MD Lite");
}
