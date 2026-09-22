import SwiftUI
import AppKit

@main
struct MDLiteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var prefs = AppPreferences.shared

    var body: some Scene {
        WindowGroup("MD Lite", id: "reader", for: DocumentTarget.self) { $target in
            DocumentScene(target: target)
        } defaultValue: {
            let last = UserDefaults.standard.string(forKey: "lastWorkspace").map { URL(fileURLWithPath: $0, isDirectory: true) }
            return DocumentTarget(workspace: last.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil })
        }
        .defaultSize(width: 1180, height: 820)
        .windowStyle(.hiddenTitleBar)
        // Files from Finder go through DocumentRouter (reuse an empty tab or add one), not a new window.
        .handlesExternalEvents(matching: [])
        .commands { AppCommands(prefs: prefs) }

        Window("About MD Lite", id: "about") {
            AboutView(prefs: prefs)
                .frame(width: 420, height: 390)
                .preferredColorScheme(prefs.colorScheme)
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView(prefs: prefs)
                .preferredColorScheme(prefs.colorScheme)
        }
    }
}

/// One tab: its own document, editor, undo history, and workspace.
struct DocumentScene: View {
    let target: DocumentTarget
    @StateObject private var store = ReaderStore()
    @Environment(\.openWindow) private var openWindow
    @State private var loaded = false

    var body: some View {
        ReaderWindow(store: store)
            .frame(minWidth: 760, minHeight: 480)
            .environment(\.locale, Locale(identifier: store.resolvedLanguage))
            .preferredColorScheme(store.prefs.colorScheme)
            .navigationTitle(store.title)
            .focusedSceneObject(store)
            .background(WindowAccessor { store.attach($0) })
            .onAppear {
                DocumentRouter.shared.openWindow = { openWindow(value: $0) }
                guard !loaded else { return }
                loaded = true
                if let folder = target.workspace, FileManager.default.fileExists(atPath: folder.path) { store.setWorkspace(folder) }
                if let url = target.url { store.open(url, quiet: true) }
                DocumentRouter.shared.register(store)
            }
    }
}

struct AppCommands: Commands {
    @ObservedObject var prefs: AppPreferences
    @FocusedObject private var store: ReaderStore?
    @Environment(\.openWindow) private var openWindow

    private func t(_ key: String) -> String { prefs.t(key) }

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button(t("Acerca de MD Lite")) { openWindow(id: "about") }
            Button(t("Buscar actualizaciones…")) { UpdateChecker.check(prefs, userInitiated: true) }
            Divider()
            Button(t("Usar MD Lite para abrir .md…")) { (store ?? DocumentRouter.shared.keyStore)?.showDefaultAppGuide = true }
        }
        CommandGroup(replacing: .newItem) {
            Button(t("Nueva pestaña")) { DocumentRouter.shared.newTab(from: store) }.keyboardShortcut("t")
            Button(t("Nueva nota")) {
                if let store, store.canReuseForNewDocument { store.newNote() }
                else {
                    DocumentRouter.shared.newTab(from: store)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { DocumentRouter.shared.keyStore?.newNote() }
                }
            }.keyboardShortcut("n")
            Button(t("Abrir Markdown…")) { (store ?? DocumentRouter.shared.keyStore)?.openPanel() }.keyboardShortcut("o")
            Button(t("Abrir carpeta…")) { (store ?? DocumentRouter.shared.keyStore)?.openWorkspacePanel() }.keyboardShortcut("o", modifiers: [.command, .shift])
            Menu(t("Abrir reciente")) {
                ForEach(prefs.recent, id: \.self) { url in
                    Button(url.lastPathComponent) { DocumentRouter.shared.open(url, from: store) }
                }
            }
            Divider()
            Button(t("Pegar y leer")) { store?.readClipboard() }.keyboardShortcut("v", modifiers: [.command, .shift]).disabled(store == nil)
            Button(t("Pegar Markdown…")) { store?.presentPasteEditor() }.disabled(store == nil)
        }
        CommandGroup(replacing: .saveItem) {
            Button(t("Cerrar")) {
                DocumentRouter.shared.closeFrontmost(focused: store)
            }.keyboardShortcut("w")
            Divider()
            Button(t("Guardar")) { store?.save() }.keyboardShortcut("s").disabled(store == nil)
            Button(t("Guardar como…")) { store?.saveAs() }.keyboardShortcut("s", modifiers: [.command, .shift]).disabled(store == nil)
            Button(t("Volver a cargar")) { store?.reload() }.keyboardShortcut("r").disabled(store?.fileURL == nil)
        }
        CommandGroup(after: .textEditing) {
            Divider()
            Button(t("Buscar…")) { store?.find(.showFindInterface) }.keyboardShortcut("f")
            Button(t("Buscar siguiente")) { store?.find(.nextMatch) }.keyboardShortcut("g")
            Button(t("Buscar anterior")) { store?.find(.previousMatch) }.keyboardShortcut("g", modifiers: [.command, .shift])
        }
        CommandMenu(t("Formato")) {
            Group {
                format("Negrita", .bold, "b")
                format("Cursiva", .italic, "i")
                format("Tachado", .strikethrough, "x", [.command, .shift])
                format("Código en línea", .code, "k", [.command, .shift])
                format("Enlace", .link, "k")
            }
            Divider()
            Group {
                format("Título 1", .heading1, "1", [.command, .option])
                format("Título 2", .heading2, "2", [.command, .option])
                format("Título 3", .heading3, "3", [.command, .option])
                format("Texto normal", .paragraph, "0", [.command, .option])
            }
            Divider()
            Group {
                format("Lista", .bulletList, "7", [.command, .shift])
                format("Lista numerada", .numberedList, "9", [.command, .shift])
                format("Lista de tareas", .taskList, "l", [.command, .shift])
                format("Cita", .quote, "'")
                format("Bloque de código", .codeBlock, "m", [.command, .shift])
                format("Tabla", .table, "t", [.command, .option])
                format("Separador", .rule, "-", [.command, .option])
            }
        }
        CommandGroup(replacing: .sidebar) {
            Button(prefs.sidebarVisible ? t("Ocultar barra lateral") : t("Mostrar barra lateral")) {
                withAnimation(.snappy(duration: 0.24)) { prefs.sidebarVisible.toggle() }
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
        }
        CommandGroup(before: .toolbar) {
            modeToggle(.read, t("Lectura")).keyboardShortcut("1")
            modeToggle(.edit, t("Editor")).keyboardShortcut("2")
            modeToggle(.source, t("Código")).keyboardShortcut("3")
            modeToggle(.split, t("Dividida")).keyboardShortcut("4")
            Button(t("Alternar lectura y edición")) { store?.toggleEditing() }.keyboardShortcut("e").disabled(store == nil)
            Divider()
            Button(store?.focusMode == true ? t("Salir del modo enfoque") : t("Modo enfoque")) {
                withAnimation(.snappy(duration: 0.24)) { store?.focusMode.toggle() }
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            Divider()
            Button(t("Aumentar texto")) { prefs.fontSize = min(28, prefs.fontSize + 1) }.keyboardShortcut("+")
            Button(t("Reducir texto")) { prefs.fontSize = max(12, prefs.fontSize - 1) }.keyboardShortcut("-")
            Button(t("Tamaño original")) { prefs.fontSize = 17 }.keyboardShortcut("0")
            Divider()
            Button(t("Título anterior")) { store?.navigateRelative(-1) }.keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button(t("Título siguiente")) { store?.navigateRelative(1) }.keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Divider()
        }
        CommandGroup(replacing: .help) {
            Button(t("Atajos de teclado")) { store?.showShortcuts = true }.keyboardShortcut("/").disabled(store == nil)
            Button(t("Bienvenida")) { store?.welcome() }.disabled(store == nil)
            Divider()
            Link(t("Guía de Markdown"), destination: URL(string: "https://www.markdownguide.org/basic-syntax/")!)
            Link(t("Especificación GFM"), destination: URL(string: "https://github.github.com/gfm/")!)
            Link(t("Informar de un problema"), destination: URL(string: "https://github.com/glozahn/md-lite/issues")!)
        }
    }

    private func format(_ title: String, _ action: FormatAction, _ key: KeyEquivalent, _ modifiers: EventModifiers = .command) -> some View {
        Button(t(title)) { store?.format(action) }.keyboardShortcut(key, modifiers: modifiers).disabled(store == nil)
    }

    private func modeToggle(_ mode: DocumentMode, _ title: String) -> some View {
        Toggle(title, isOn: Binding(get: { store?.mode == mode }, set: { _ in store?.setMode(mode) })).disabled(store == nil)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = true
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor in
            AppPreferences.shared.applyWindowAppearance()
            UpdateChecker.checkAutomaticallyIfNeeded(AppPreferences.shared)
        }
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in DocumentRouter.shared.enqueue(urls) }
        application.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated { DocumentRouter.shared.confirmQuit() } ? .terminateNow : .terminateCancel
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
