//! Settings, shortcuts, about, default-app and update dialogs, and the typography popover.

use crate::app::APP_ID;
use crate::i18n::{t, tf};
use crate::prefs;
use adw::prelude::*;
use gtk::{gio, glib};
use std::rc::Rc;

pub fn alert(parent: &impl IsA<gtk::Widget>, title: &str, body: &str) {
    let dialog = adw::AlertDialog::new(Some(title), Some(body));
    dialog.add_response("ok", &t("Entendido"));
    dialog.present(Some(parent));
}

const ACCENTS: &[(&str, &str)] = &[
    ("system", "Sistema"),
    ("teal", "Verde agua"),
    ("blue", "Azul"),
    ("purple", "Violeta"),
    ("pink", "Rosa"),
    ("orange", "Naranja"),
    ("green", "Verde"),
];
const WIDTHS: &[(&str, &str)] = &[("narrow", "Estrecho"), ("normal", "Normal"), ("wide", "Ancho"), ("full", "Completo")];
const APPEARANCES: &[(&str, &str)] = &[("system", "Sistema"), ("light", "Claro"), ("dark", "Oscuro")];
const LANGUAGES: &[(&str, &str)] = &[("system", "Sistema"), ("en", "Inglés"), ("es", "Español")];

fn labelled(label: &str, control: &impl IsA<gtk::Widget>) -> gtk::Box {
    let row = gtk::Box::new(gtk::Orientation::Horizontal, 12);
    let text = gtk::Label::new(Some(label));
    text.set_xalign(0.0);
    text.set_hexpand(true);
    text.add_css_class("md-setting-label");
    row.append(&text);
    row.append(control);
    row
}

/// A row of linked toggle buttons bound to a string preference.
fn choice(options: &[(&str, &str)], current: String, set: impl Fn(&str) + 'static) -> gtk::Box {
    let row = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    row.add_css_class("linked");
    let set = Rc::new(set);
    let mut first: Option<gtk::ToggleButton> = None;
    for (value, label) in options {
        let button = gtk::ToggleButton::with_label(&t(label));
        if let Some(first) = &first {
            button.set_group(Some(first));
        } else {
            first = Some(button.clone());
        }
        button.set_active(current == *value);
        let value = value.to_string();
        let set = set.clone();
        button.connect_toggled(move |b| {
            if b.is_active() {
                set(&value);
            }
        });
        row.append(&button);
    }
    row
}

pub fn quick_settings() -> gtk::Popover {
    let popover = gtk::Popover::new();
    let column = gtk::Box::new(gtk::Orientation::Vertical, 12);
    column.set_margin_top(12);
    column.set_margin_bottom(12);
    column.set_margin_start(12);
    column.set_margin_end(12);
    column.set_width_request(330);

    let size = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    size.add_css_class("linked");
    let smaller = gtk::Button::with_label("A−");
    smaller.set_action_name(Some("win.zoom-out"));
    let value = gtk::Button::with_label("17");
    value.set_action_name(Some("win.zoom-reset"));
    value.set_tooltip_text(Some(&t("Tamaño original")));
    let larger = gtk::Button::with_label("A+");
    larger.set_action_name(Some("win.zoom-in"));
    size.append(&smaller);
    size.append(&value);
    size.append(&larger);
    column.append(&labelled(&t("Tamaño del texto"), &size));

    let width = gtk::DropDown::from_strings(&WIDTHS.iter().map(|(_, l)| t(l)).collect::<Vec<_>>().iter().map(String::as_str).collect::<Vec<_>>());
    column.append(&labelled(&t("Ancho del texto"), &width));
    width.connect_selected_notify(|d| {
        let value = WIDTHS[d.selected() as usize].0.to_string();
        if prefs::with(|p| p.text_width != value) {
            prefs::update(|p| p.text_width = value);
        }
    });

    let appearance = choice(APPEARANCES, prefs::with(|p| p.appearance.clone()), |v| {
        let v = v.to_string();
        prefs::update(|p| p.appearance = v);
    });
    column.append(&labelled(&t("Apariencia"), &appearance));

    let swatches = gtk::Box::new(gtk::Orientation::Horizontal, 6);
    let mut first: Option<gtk::ToggleButton> = None;
    let current = prefs::with(|p| p.accent.clone());
    for (value, label) in ACCENTS {
        let button = gtk::ToggleButton::new();
        button.add_css_class("md-swatch");
        button.add_css_class(&format!("md-swatch-{value}"));
        button.set_tooltip_text(Some(&t(label)));
        if let Some(first) = &first {
            button.set_group(Some(first));
        } else {
            first = Some(button.clone());
        }
        button.set_active(current == *value);
        let value = value.to_string();
        button.connect_toggled(move |b| {
            if b.is_active() {
                let value = value.clone();
                prefs::update(|p| p.accent = value);
            }
        });
        swatches.append(&button);
    }
    column.append(&labelled(&t("Color de acento"), &swatches));

    let settings = gtk::Button::with_label(&t("Ajustes…"));
    settings.add_css_class("flat");
    settings.set_action_name(Some("win.preferences"));
    column.append(&settings);
    popover.set_child(Some(&column));

    let refresh = glib::clone!(
        #[weak]
        value,
        #[weak]
        width,
        move || {
            let p = prefs::get();
            value.set_label(&format!("{}", p.font_size as i32));
            let index = WIDTHS.iter().position(|(v, _)| *v == p.text_width).unwrap_or(1) as u32;
            if width.selected() != index {
                width.set_selected(index);
            }
        }
    );
    refresh();
    let listener: Rc<dyn Fn()> = Rc::new(refresh);
    prefs::add_listener(&listener);
    // The popover keeps its listener alive.
    unsafe {
        popover.set_data("prefs-listener", listener);
    }
    popover
}

fn combo(title: &str, options: &[(&str, &str)], current: &str, set: impl Fn(&str) + 'static) -> adw::ComboRow {
    let row = adw::ComboRow::new();
    row.set_title(title);
    let labels: Vec<String> = options.iter().map(|(_, l)| t(l)).collect();
    row.set_model(Some(&gtk::StringList::new(&labels.iter().map(String::as_str).collect::<Vec<_>>())));
    row.set_selected(options.iter().position(|(v, _)| *v == current).unwrap_or(0) as u32);
    let values: Vec<String> = options.iter().map(|(v, _)| v.to_string()).collect();
    row.connect_selected_notify(move |row| {
        if let Some(value) = values.get(row.selected() as usize) {
            set(value);
        }
    });
    row
}

pub fn preferences(parent: &impl IsA<gtk::Widget>) {
    let p = prefs::get();
    let dialog = adw::PreferencesDialog::new();
    dialog.set_title(&t("Ajustes"));
    let page = adw::PreferencesPage::new();
    page.set_title(&t("Lectura y edición"));
    page.set_icon_name(Some("preferences-system-symbolic"));

    let look = adw::PreferencesGroup::new();
    look.set_title(&t("Apariencia"));
    look.add(&combo(&t("Apariencia"), APPEARANCES, &p.appearance, |v| {
        let v = v.to_string();
        prefs::update(|p| p.appearance = v);
    }));
    look.add(&combo(&t("Color de acento"), ACCENTS, &p.accent, |v| {
        let v = v.to_string();
        prefs::update(|p| p.accent = v);
    }));
    look.add(&combo(&t("Idioma"), LANGUAGES, &p.language, |v| {
        let v = v.to_string();
        prefs::update(|p| p.language = v);
    }));
    page.add(&look);

    let text = adw::PreferencesGroup::new();
    text.set_title(&t("Lectura"));
    let size = adw::SpinRow::with_range(12.0, 28.0, 1.0);
    size.set_title(&t("Tamaño del texto"));
    size.set_value(f64::from(p.font_size));
    size.connect_value_notify(|row| {
        let value = row.value() as f32;
        if prefs::with(|p| p.font_size != value) {
            prefs::update(|p| p.font_size = value);
        }
    });
    text.add(&size);
    text.add(&combo(&t("Ancho del texto"), WIDTHS, &p.text_width, |v| {
        let v = v.to_string();
        prefs::update(|p| p.text_width = v);
    }));
    page.add(&text);

    let privacy = adw::PreferencesGroup::new();
    privacy.set_title(&t("Privacidad"));
    privacy.set_description(Some(&t("Las imágenes de internet se bloquean hasta que pulsas Mostrar.")));
    let remote = adw::SwitchRow::new();
    remote.set_title(&t("Cargar siempre imágenes remotas"));
    remote.set_active(p.always_load_remote_images);
    remote.connect_active_notify(|row| {
        let value = row.is_active();
        prefs::update(|p| p.always_load_remote_images = value);
    });
    privacy.add(&remote);
    page.add(&privacy);

    let application = adw::PreferencesGroup::new();
    application.set_title(&t("Aplicación"));
    let updates = adw::SwitchRow::new();
    updates.set_title(&t("Buscar actualizaciones automáticamente"));
    updates.set_active(p.check_updates);
    updates.connect_active_notify(|row| {
        let value = row.is_active();
        prefs::update_quietly(|p| p.check_updates = value);
    });
    application.add(&updates);
    let default_app = adw::ButtonRow::new();
    default_app.set_title(&t("Usar MD Lite para abrir .md…"));
    default_app.set_action_name(Some("win.default-app"));
    application.add(&default_app);
    page.add(&application);

    dialog.add(&page);
    dialog.present(Some(parent));
}

pub fn shortcuts(parent: &impl IsA<gtk::Widget>) {
    let groups: &[(&str, &[(&str, &str)])] = &[
        (
            "Vista",
            &[
                ("Lectura / Editor / Código / Dividida", "Ctrl+1 · Ctrl+2 · Ctrl+3 · Ctrl+4"),
                ("Alternar lectura y edición", "Ctrl+E"),
                ("Mostrar u ocultar la barra lateral", "F9 · Ctrl+\\"),
                ("Modo enfoque", "Ctrl+Shift+F"),
                ("Aumentar / reducir texto", "Ctrl++ · Ctrl+0 · Ctrl+−"),
                ("Título anterior", "Ctrl+Alt+↑"),
                ("Título siguiente", "Ctrl+Alt+↓"),
            ],
        ),
        (
            "Archivo",
            &[
                ("Nueva nota", "Ctrl+N"),
                ("Nueva pestaña", "Ctrl+T"),
                ("Nueva ventana", "Ctrl+Shift+N"),
                ("Abrir Markdown…", "Ctrl+O"),
                ("Abrir carpeta…", "Ctrl+Shift+O"),
                ("Guardar", "Ctrl+S"),
                ("Guardar como…", "Ctrl+Shift+S"),
                ("Pegar y leer", "Ctrl+Shift+V"),
                ("Volver a cargar", "Ctrl+R"),
                ("Imprimir…", "Ctrl+P"),
                ("Cerrar", "Ctrl+W"),
            ],
        ),
        (
            "Pestañas",
            &[
                ("Pestaña siguiente", "Ctrl+Shift+] · Ctrl+RePág"),
                ("Pestaña anterior", "Ctrl+Shift+[ · Ctrl+AvPág"),
                ("Mover al panel izquierdo", "Ctrl+Alt+←"),
                ("Mover al panel derecho", "Ctrl+Alt+→"),
                ("Cerrar panel: sus pestañas pasan al otro", "Ctrl+Alt+W"),
                ("Mover la pestaña a una ventana nueva", "Ctrl+Alt+N"),
            ],
        ),
        (
            "Edición",
            &[
                ("Deshacer", "Ctrl+Z"),
                ("Rehacer", "Ctrl+Shift+Z"),
                ("Buscar", "Ctrl+F"),
                ("Buscar siguiente / anterior", "Ctrl+G · Ctrl+Shift+G"),
                ("Continuar lista o cita", "↩"),
                ("Sangrar / quitar sangría", "⇥ · Shift+⇥"),
                ("Abrir enlace en el editor", "Ctrl+clic"),
            ],
        ),
        (
            "Formato",
            &[
                ("Negrita", "Ctrl+B"),
                ("Cursiva", "Ctrl+I"),
                ("Tachado", "Ctrl+Shift+X"),
                ("Código en línea", "Ctrl+Shift+K"),
                ("Enlace", "Ctrl+K"),
                ("Título 1, 2, 3", "Ctrl+Alt+1–3"),
                ("Texto normal", "Ctrl+Alt+0"),
                ("Lista", "Ctrl+Shift+7"),
                ("Lista numerada", "Ctrl+Shift+9"),
                ("Lista de tareas", "Ctrl+Shift+L"),
                ("Cita", "Ctrl+'"),
                ("Bloque de código", "Ctrl+Shift+M"),
                ("Tabla", "Ctrl+Alt+T"),
                ("Separador", "Ctrl+Alt+−"),
            ],
        ),
    ];
    let dialog = adw::Dialog::new();
    dialog.set_title(&t("Atajos de teclado"));
    dialog.set_content_width(560);
    dialog.set_content_height(640);
    let page = adw::PreferencesPage::new();
    page.set_description(&t("Todo MD Lite, sin soltar el teclado."));
    for (title, rows) in groups {
        let group = adw::PreferencesGroup::new();
        group.set_title(&t(title));
        for (label, keys) in rows.iter() {
            let row = adw::ActionRow::new();
            row.set_title(&t(label));
            let caps = gtk::Label::new(Some(keys));
            caps.add_css_class("md-keys");
            caps.add_css_class("dim-label");
            row.add_suffix(&caps);
            group.add(&row);
        }
        page.add(&group);
    }
    let toolbar = adw::ToolbarView::new();
    toolbar.add_top_bar(&adw::HeaderBar::new());
    toolbar.set_content(Some(&page));
    dialog.set_child(Some(&toolbar));
    dialog.present(Some(parent));
}

pub fn about(parent: &impl IsA<gtk::Widget>) {
    let dialog = adw::AboutDialog::new();
    dialog.set_application_name("MD Lite");
    dialog.set_application_icon(APP_ID);
    dialog.set_version(env!("CARGO_PKG_VERSION"));
    dialog.set_developer_name("MD Lite contributors");
    dialog.set_comments(&t("Un lector y editor Markdown nativo y ligero."));
    dialog.set_website("https://github.com/glozahn/md-lite");
    dialog.set_issue_url("https://github.com/glozahn/md-lite/issues");
    dialog.set_license_type(gtk::License::MitX11);
    dialog.add_link(&t("Dejar una estrella en GitHub"), "https://github.com/glozahn/md-lite");
    dialog.add_legal_section("Mermaid", Some("© Knut Sveidqvist and contributors"), gtk::License::MitX11, None);
    dialog.add_legal_section("pulldown-cmark", Some("© Raph Levien and contributors"), gtk::License::MitX11, None);
    dialog.present(Some(parent));
}

pub fn default_app(parent: &impl IsA<gtk::Widget>) {
    let desktop_id = format!("{APP_ID}.desktop");
    let current = gio::AppInfo::default_for_type("text/markdown", false).map(|a| a.display_name().to_string());
    let ours = gio::AppInfo::default_for_type("text/markdown", false).and_then(|a| a.id()).is_some_and(|id| id == desktop_id);
    let body = if ours {
        t("MD Lite ya es la app para tus archivos .md.")
    } else {
        format!(
            "{}\n\n{}",
            tf("Ahora se abren con: %@", &[&current.unwrap_or_else(|| t("ninguna app"))]),
            t("Así, al hacer doble clic en un archivo Markdown, se abrirá directamente aquí.")
        )
    };
    let dialog = adw::AlertDialog::new(Some(&t("Abre tus archivos .md con MD Lite")), Some(&body));
    if ours {
        dialog.add_response("ok", &t("Listo"));
    } else {
        dialog.add_responses(&[("later", &t("Ahora no")), ("use", &t("Usar MD Lite"))]);
        dialog.set_response_appearance("use", adw::ResponseAppearance::Suggested);
        dialog.set_default_response(Some("use"));
    }
    let parent_widget = parent.as_ref().clone();
    dialog.connect_response(None, move |_, response| {
        if response != "use" {
            return;
        }
        let info = gio::AppInfo::all().into_iter().find(|a| a.id().is_some_and(|id| id == desktop_id));
        let result: Result<(), String> = match info {
            None => Err("MD Lite is not installed as a desktop app.".to_string()),
            Some(info) => ["text/markdown", "text/x-markdown"]
                .iter()
                .try_for_each(|mime| info.set_as_default_for_type(mime).map_err(|e| e.to_string())),
        };
        match result {
            Ok(()) => alert(&parent_widget, &t("MD Lite abre tus .md"), &t("Listo. MD Lite ya abre tus archivos .md y .markdown.")),
            Err(message) => alert(&parent_widget, &t("No se pudo asociar Markdown"), &message),
        }
    });
    dialog.present(Some(parent));
}

fn newer(latest: &str, current: &str) -> bool {
    let parse = |v: &str| -> Vec<u64> { v.trim_start_matches('v').split(['.', '-']).filter_map(|p| p.parse().ok()).collect() };
    parse(latest) > parse(current)
}

pub fn check_updates(parent: &impl IsA<gtk::Widget>, user_initiated: bool) {
    let parent = parent.as_ref().clone();
    glib::MainContext::default().spawn_local(async move {
        let json = crate::images::fetch_text("https://api.github.com/repos/glozahn/md-lite/releases/latest").await;
        let release = json.as_deref().and_then(|j| serde_json::from_str::<serde_json::Value>(j).ok());
        let version = env!("CARGO_PKG_VERSION");
        let Some(release) = release else {
            if user_initiated {
                alert(&parent, &t("No se pudo buscar actualizaciones"), &t("Revisa tu conexión e inténtalo de nuevo."));
            }
            return;
        };
        let tag = release["tag_name"].as_str().unwrap_or_default().trim_start_matches('v').to_string();
        let url = release["html_url"].as_str().unwrap_or("https://github.com/glozahn/md-lite/releases/latest").to_string();
        if newer(&tag, version) {
            let dialog = adw::AlertDialog::new(
                Some(&tf("MD Lite %@ está disponible", &[&tag])),
                Some(&format!("{} {}", tf("Tienes la versión %@.", &[version]), t("Descarga la versión nueva desde GitHub."))),
            );
            dialog.add_responses(&[("later", &t("Más tarde")), ("open", &t("Ver en GitHub"))]);
            dialog.set_response_appearance("open", adw::ResponseAppearance::Suggested);
            let window = parent.root().and_downcast::<gtk::Window>();
            dialog.connect_response(None, move |_, response| {
                if response == "open" {
                    gtk::UriLauncher::new(&url).launch(window.as_ref(), None::<&gio::Cancellable>, |_| {});
                }
            });
            dialog.present(Some(&parent));
        } else if user_initiated {
            alert(&parent, &t("MD Lite está al día"), &tf("Tienes la versión más reciente (%@).", &[version]));
        }
    });
}

#[cfg(test)]
mod tests {
    #[test]
    fn compares_versions() {
        assert!(super::newer("0.4.0", "0.3.5"));
        assert!(super::newer("v0.3.10", "0.3.9"));
        assert!(!super::newer("0.3.5", "0.3.5"));
    }
}
