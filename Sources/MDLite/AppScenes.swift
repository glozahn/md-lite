import SwiftUI
import AppKit

@main
struct MDLiteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var prefs = AppPreferences.shared

    var body: some Scene {
        WindowGroup("MD Lite", id: "reader", for: DocumentTarget.self) { $target in
            WorkbenchScene(target: target)
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
                .background(WindowAccessor { $0.isRestorable = false })
        }
        .windowResizability(.contentSize)
        .commandsRemoved()
        // Files opened from Finder go to DocumentRouter; without this SwiftUI shows About for them.
        .handlesExternalEvents(matching: [])

        Settings {
            SettingsView(prefs: prefs)
                .preferredColorScheme(prefs.colorScheme)
                .background(WindowAccessor { $0.isRestorable = false })
        }
    }
}

/// One window: its panes, tabs and working folder.
struct WorkbenchScene: View {
    @StateObject private var bench: Workbench
    @Environment(\.openWindow) private var openWindow

    init(target: DocumentTarget) {
        _bench = StateObject(wrappedValue: Workbench(target: target))
    }

    var body: some View {
        WorkbenchView(bench: bench)
            .frame(minWidth: 760, minHeight: 480)
            .environment(\.locale, Locale(identifier: bench.focusedStore.resolvedLanguage))
            .preferredColorScheme(bench.focusedStore.prefs.colorScheme)
            .navigationTitle(bench.focusedStore.title)
            .focusedSceneObject(bench)
            .focusedSceneObject(bench.focusedStore)
            .background(WindowAccessor { window in
                // macOS would otherwise reopen yesterday's empty windows; MD Lite decides what opens.
                window.isRestorable = false
                bench.attach(window)
            })
            .onAppear { DocumentRouter.shared.openWindow = { openWindow(value: $0) } }
    }
}

struct AppCommands: Commands {
    @ObservedObject var prefs: AppPreferences
    @FocusedObject private var store: ReaderStore?
    @FocusedObject private var bench: Workbench?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    private func t(_ key: String) -> String { prefs.t(key) }

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button(t("Acerca de MD Lite")) {
                if !AppWindows.raise("about") {
                    openWindow(id: "about")
                    DispatchQueue.main.async { AppWindows.raise("about") }
                }
            }
            Button(t("Buscar actualizaciones…")) { UpdateChecker.check(prefs, userInitiated: true) }
            Divider()
            Button(t("Usar MD Lite para abrir .md…")) { (store ?? DocumentRouter.shared.keyStore)?.showDefaultAppGuide = true }
        }
        CommandGroup(replacing: .appSettings) {
            Button(t("Ajustes…")) { AppWindows.showSettings(openSettings) }.keyboardShortcut(",")
        }
        CommandGroup(replacing: .newItem) {
            Button(t("Nueva pestaña")) {
                if let target = bench ?? DocumentRouter.shared.keyBench {
                    target.newTab()
                    target.window?.makeKeyAndOrderFront(nil)
                } else {
                    openWindow(value: DocumentTarget())
                }
            }.keyboardShortcut("t")
            Button(t("Nueva ventana")) { openWindow(value: DocumentTarget(workspace: bench?.workspace)) }.keyboardShortcut("n", modifiers: [.command, .shift])
            Button(t("Nueva nota")) {
                guard let bench = bench ?? DocumentRouter.shared.keyBench else { return }
                let target = bench.focusedStore.canReuseForNewDocument ? bench.focusedStore : bench.newTab()
                target.newNote()
                bench.window?.makeKeyAndOrderFront(nil)
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
            Button(t("Duplicar")) { store?.duplicateDocument() }.disabled(store == nil)
            Menu(t("Exportar")) {
                Button(t("HTML…")) { store?.exportHTML() }
                Button(t("PDF…")) { store?.exportPDF() }
            }.disabled(store == nil)
            Button(t("Volver a cargar")) { store?.reload() }.keyboardShortcut("r").disabled(store?.fileURL == nil)
            Divider()
            Button(t("Imprimir…")) { store?.printDocument() }.keyboardShortcut("p").disabled(store == nil)
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
        CommandGroup(before: .windowList) {
            Button(t("Pestaña siguiente")) { bench?.cycleTab(1) }.keyboardShortcut("]", modifiers: [.command, .shift]).disabled(bench == nil)
            Button(t("Pestaña anterior")) { bench?.cycleTab(-1) }.keyboardShortcut("[", modifiers: [.command, .shift]).disabled(bench == nil)
            Divider()
            Button(t("Mover la pestaña a una ventana nueva")) {
                if let store = bench?.focusedStore ?? DocumentRouter.shared.keyStore { DocumentRouter.shared.detach(store) }
            }.keyboardShortcut("n", modifiers: [.command, .control])
            Toggle(t("Mantener encima"), isOn: Binding(
                get: { (bench ?? DocumentRouter.shared.keyBench)?.floating ?? false },
                set: { (bench ?? DocumentRouter.shared.keyBench)?.floating = $0 }
            ))
            Divider()
            Button(t("Cerrar panel")) { if let bench { bench.closePane(bench.focusedPane) } }
                .keyboardShortcut("w", modifiers: [.command, .option]).disabled((bench?.panes.count ?? 1) < 2)
            Button(t("Mover al panel izquierdo")) { if let store { bench?.place(store: store, side: .left) } }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .control]).disabled(bench == nil)
            Button(t("Mover al panel derecho")) { if let store { bench?.place(store: store, side: .right) } }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .control]).disabled(bench == nil)
            Divider()
        }
        CommandGroup(before: .toolbar) {
            modeToggle(.read, t("Lectura")).keyboardShortcut("1")
            modeToggle(.edit, t("Editor")).keyboardShortcut("2")
            modeToggle(.source, t("Código")).keyboardShortcut("3")
            modeToggle(.split, t("Dividida")).keyboardShortcut("4")
            Button(t("Alternar lectura y edición")) { store?.toggleEditing() }.keyboardShortcut("e").disabled(store == nil)
            Divider()
            Button(store?.focusMode == true ? t("Salir del modo enfoque") : t("Modo enfoque")) { store?.toggleFocus() }
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
            Button(t("Novedades")) { openChangelog() }
            Divider()
            Link(t("Guía de Markdown"), destination: URL(string: "https://www.markdownguide.org/basic-syntax/")!)
            Link(t("Especificación GFM"), destination: URL(string: "https://github.github.com/gfm/")!)
            Link(t("Informar de un problema"), destination: URL(string: "https://github.com/glozahn/md-lite/issues")!)
        }
    }

    /// The changelog opens in a tab of its own, unless the current one is free.
    private func openChangelog() {
        guard let bench = bench ?? DocumentRouter.shared.keyBench else { return }
        let target = bench.focusedStore.canReuseForNewDocument ? bench.focusedStore : bench.newTab()
        target.readChangelog()
        bench.window?.makeKeyAndOrderFront(nil)
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
        NSWindow.allowsAutomaticWindowTabbing = false
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor in
            AppPreferences.shared.applyWindowAppearance()
            UpdateChecker.checkAutomaticallyIfNeeded(AppPreferences.shared)
            Updater.shared.showChangelogAfterUpdate()
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
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { Updater.shared.installOnQuit() }
    }
}
