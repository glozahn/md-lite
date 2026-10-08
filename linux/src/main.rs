mod app;
mod dialogs;
mod document;
mod i18n;
mod images;
mod markdown;
mod mermaid;
mod prefs;
mod sidebar;
mod ui;
mod window;

fn main() -> gtk::glib::ExitCode {
    app::run()
}
