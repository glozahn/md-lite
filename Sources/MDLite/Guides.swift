import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct KeyCaps: View {
    let keys: String
    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(keys.split(separator: " ").enumerated()), id: \.offset) { _, key in
                Text(String(key))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .padding(.horizontal, 6).frame(minWidth: 20, minHeight: 20)
                    .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
                    .overlay { RoundedRectangle(cornerRadius: 5).stroke(.primary.opacity(0.08)) }
            }
        }
    }
}

struct ShortcutsView: View {
    @ObservedObject var store: ReaderStore

    private var sections: [(String, [(String, String)])] {
        [
            (store.t("Vista"), [
                (store.t("Lectura"), "⌘ 1"), (store.t("Editor"), "⌘ 2"), (store.t("Código"), "⌘ 3"),
                (store.t("Alternar lectura y edición"), "⌘ E"), (store.t("Mostrar u ocultar la barra lateral"), "⌃ ⌘ S"),
                (store.t("Modo enfoque"), "⇧ ⌘ F"), (store.t("Aumentar / reducir texto"), "⌘ + −"), (store.t("Tamaño original"), "⌘ 0")
            ]),
            (store.t("Archivo"), [
                (store.t("Nueva nota"), "⌘ N"), (store.t("Abrir"), "⌘ O"), (store.t("Guardar"), "⌘ S"),
                (store.t("Guardar como…"), "⇧ ⌘ S"), (store.t("Pegar y leer"), "⇧ ⌘ V"), (store.t("Volver a cargar"), "⌘ R")
            ]),
            (store.t("Edición"), [
                (store.t("Deshacer"), "⌘ Z"), (store.t("Rehacer"), "⇧ ⌘ Z"), (store.t("Buscar"), "⌘ F"),
                (store.t("Buscar siguiente / anterior"), "⌘ G ⇧⌘G"), (store.t("Continuar lista o cita"), "↩"),
                (store.t("Sangrar / quitar sangría"), "⇥ ⇧⇥"), (store.t("Abrir enlace en el editor"), "⌘ clic")
            ]),
            (store.t("Formato"), [
                (store.t("Negrita"), "⌘ B"), (store.t("Cursiva"), "⌘ I"), (store.t("Tachado"), "⇧ ⌘ X"),
                (store.t("Código en línea"), "⇧ ⌘ K"), (store.t("Enlace"), "⌘ K"), (store.t("Título 1, 2, 3"), "⌥ ⌘ 1–3"),
                (store.t("Texto normal"), "⌥ ⌘ 0"), (store.t("Lista"), "⇧ ⌘ 7"), (store.t("Lista numerada"), "⇧ ⌘ 9"),
                (store.t("Lista de tareas"), "⇧ ⌘ L"), (store.t("Cita"), "⌘ '"), (store.t("Bloque de código"), "⇧ ⌘ M"),
                (store.t("Tabla"), "⌥ ⌘ T"), (store.t("Separador"), "⌥ ⌘ −")
            ]),
            (store.t("Navegación"), [
                (store.t("Título anterior"), "⌥ ⌘ ↑"), (store.t("Título siguiente"), "⌥ ⌘ ↓"), (store.t("Atajos de teclado"), "⌘ /")
            ])
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.t("Atajos de teclado")).font(.system(size: 20, weight: .semibold))
                    Text(store.t("Todo MD Lite, sin soltar el teclado.")).foregroundStyle(.secondary)
                }
                Spacer()
                Button(store.t("Cerrar")) { store.showShortcuts = false }.keyboardShortcut(.cancelAction)
            }
            .padding(24)
            Divider()
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 18, alignment: .top), GridItem(.flexible(), spacing: 18, alignment: .top)], spacing: 18) {
                    ForEach(sections, id: \.0) { section in
                        VStack(alignment: .leading, spacing: 9) {
                            Text(section.0.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(1.2).foregroundStyle(.tertiary)
                            ForEach(section.1, id: \.0) { row in
                                HStack {
                                    Text(row.0).font(.system(size: 12.5))
                                    Spacer(minLength: 12)
                                    KeyCaps(keys: row.1)
                                }
                            }
                        }
                        .padding(16)
                        .background(.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 14))
                    }
                }
                .padding(24)
            }
        }
        .frame(width: 760, height: 600)
        .tint(store.accentColor)
    }
}

struct DefaultAppGuide: View {
    @ObservedObject var store: ReaderStore
    @State private var manual = false

    private var isDefault: Bool { store.defaultApp.isDefault == true }

    var body: some View {
        VStack(spacing: 20) {
            HStack(spacing: 18) {
                VStack(spacing: 6) {
                    Image(nsImage: NSWorkspace.shared.icon(for: UTType(filenameExtension: "md") ?? .plainText))
                        .resizable().frame(width: 58, height: 58)
                    Text("README.md").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                }
                Image(systemName: "arrow.right").font(.system(size: 18, weight: .semibold)).foregroundStyle(.tertiary)
                VStack(spacing: 6) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 62, height: 62)
                    Text("MD Lite").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                }
            }
            .padding(.top, 6)

            VStack(spacing: 7) {
                Text(store.t("Abre tus archivos .md con MD Lite")).font(.system(size: 19, weight: .semibold))
                Text(store.t("Así, al hacer doble clic en un archivo Markdown en Finder, se abrirá directamente aquí."))
                    .multilineTextAlignment(.center).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Image(systemName: isDefault ? "checkmark.circle.fill" : "info.circle")
                    .font(.system(size: 16)).foregroundStyle(isDefault ? Color.green : Color.secondary)
                if isDefault {
                    Text(store.t("Listo. MD Lite ya abre tus archivos .md y .markdown."))
                } else {
                    Text(String(format: store.t("Ahora se abren con: %@"), store.defaultApp.currentName ?? store.t("ninguna app")))
                }
                Spacer()
            }
            .font(.system(size: 12.5))
            .padding(12)
            .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            .animation(.snappy, value: isDefault)

            VStack(alignment: .leading, spacing: 10) {
                step(1, store.t("Pulsa “Usar MD Lite”."))
                step(2, store.t("macOS recordará la elección para .md y .markdown."))
                step(3, store.t("Haz doble clic en cualquier Markdown en Finder. Puedes cambiarlo cuando quieras."))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            DisclosureGroup(isExpanded: $manual) {
                VStack(alignment: .leading, spacing: 8) {
                    step(1, store.t("En Finder, selecciona un archivo .md y pulsa ⌘I (Obtener información)."))
                    step(2, store.t("En “Abrir con”, elige MD Lite."))
                    step(3, store.t("Pulsa “Cambiar todo…” y confirma."))
                }
                .padding(.top, 8)
            } label: {
                Text(store.t("Prefiero hacerlo a mano")).font(.system(size: 12, weight: .medium))
            }

            HStack {
                Button(store.t("Ahora no")) { store.showDefaultAppGuide = false }.keyboardShortcut(.cancelAction)
                Spacer()
                if isDefault {
                    Button(store.t("Listo")) { store.showDefaultAppGuide = false }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                } else {
                    Button(store.t("Usar MD Lite")) { store.makeDefaultMarkdownApp() }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(28)
        .frame(width: 470)
        .tint(store.accentColor)
        .onAppear { store.refreshDefaultApp() }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(store.accentColor)
                .frame(width: 20, height: 20)
                .background(store.accentColor.opacity(0.12), in: Circle())
            Text(text).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
        }
    }
}
