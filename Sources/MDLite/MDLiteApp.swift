import SwiftUI
import AppKit

@main
struct MDLiteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = ReaderStore.shared
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("MD Lite", id: "reader") {
            ReaderWindow(store: store)
                .frame(minWidth: 760, minHeight: 480)
                .environment(\.locale, Locale(identifier: store.resolvedLanguage))
                .preferredColorScheme(store.appearance == "dark" ? .dark : store.appearance == "light" ? .light : nil)
        }
        .defaultSize(width: 1180, height: 820)
        .windowStyle(.hiddenTitleBar)
        .commands { commands }

        Window("About MD Lite", id: "about") {
            AboutView(store: store)
                .frame(width: 420, height: 390)
                .preferredColorScheme(store.appearance == "dark" ? .dark : store.appearance == "light" ? .light : nil)
        }
        .windowResizability(.contentSize)
    }

    @CommandsBuilder private var commands: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button(store.t("Acerca de MD Lite")) { openWindow(id: "about") }
            Button(store.t("Buscar actualizaciones…")) { UpdateChecker.check(store, userInitiated: true) }
            Divider()
            Button(store.t("Usar MD Lite para abrir .md…")) { store.showDefaultAppGuide = true }
        }
        CommandGroup(replacing: .newItem) {
            Button(store.t("Nueva nota"), action: store.newNote).keyboardShortcut("n")
            Button(store.t("Abrir Markdown…"), action: store.openPanel).keyboardShortcut("o")
            Menu(store.t("Abrir reciente")) {
                ForEach(store.recent, id: \.self) { url in
                    Button(url.lastPathComponent) { store.open(url) }
                }
            }
            Divider()
            Button(store.t("Pegar y leer"), action: store.readClipboard).keyboardShortcut("v", modifiers: [.command, .shift])
            Button(store.t("Pegar Markdown…"), action: store.presentPasteEditor)
        }
        CommandGroup(replacing: .saveItem) {
            Button(store.t("Guardar")) { store.save() }.keyboardShortcut("s")
            Button(store.t("Guardar como…")) { store.saveAs() }.keyboardShortcut("s", modifiers: [.command, .shift])
            Button(store.t("Volver a cargar")) { store.reload() }.keyboardShortcut("r").disabled(store.fileURL == nil)
        }
        CommandGroup(after: .textEditing) {
            Divider()
            Button(store.t("Buscar…")) { store.find(.showFindInterface) }.keyboardShortcut("f")
            Button(store.t("Buscar siguiente")) { store.find(.nextMatch) }.keyboardShortcut("g")
            Button(store.t("Buscar anterior")) { store.find(.previousMatch) }.keyboardShortcut("g", modifiers: [.command, .shift])
        }
        CommandMenu(store.t("Formato")) {
            Button(store.t("Negrita")) { store.format(.bold) }.keyboardShortcut("b")
            Button(store.t("Cursiva")) { store.format(.italic) }.keyboardShortcut("i")
            Button(store.t("Tachado")) { store.format(.strikethrough) }.keyboardShortcut("x", modifiers: [.command, .shift])
            Button(store.t("Código en línea")) { store.format(.code) }.keyboardShortcut("k", modifiers: [.command, .shift])
            Button(store.t("Enlace")) { store.format(.link) }.keyboardShortcut("k")
            Divider()
            Button(store.t("Título 1")) { store.format(.heading1) }.keyboardShortcut("1", modifiers: [.command, .option])
            Button(store.t("Título 2")) { store.format(.heading2) }.keyboardShortcut("2", modifiers: [.command, .option])
            Button(store.t("Título 3")) { store.format(.heading3) }.keyboardShortcut("3", modifiers: [.command, .option])
            Button(store.t("Texto normal")) { store.format(.paragraph) }.keyboardShortcut("0", modifiers: [.command, .option])
            Divider()
            Button(store.t("Lista")) { store.format(.bulletList) }.keyboardShortcut("7", modifiers: [.command, .shift])
            Button(store.t("Lista numerada")) { store.format(.numberedList) }.keyboardShortcut("9", modifiers: [.command, .shift])
            Button(store.t("Lista de tareas")) { store.format(.taskList) }.keyboardShortcut("l", modifiers: [.command, .shift])
            Button(store.t("Cita")) { store.format(.quote) }.keyboardShortcut("'")
            Button(store.t("Bloque de código")) { store.format(.codeBlock) }.keyboardShortcut("m", modifiers: [.command, .shift])
            Button(store.t("Tabla")) { store.format(.table) }.keyboardShortcut("t", modifiers: [.command, .option])
            Button(store.t("Separador")) { store.format(.rule) }.keyboardShortcut("-", modifiers: [.command, .option])
        }
        CommandGroup(replacing: .sidebar) {
            Button(store.sidebarVisible ? store.t("Ocultar barra lateral") : store.t("Mostrar barra lateral")) {
                withAnimation(.snappy(duration: 0.24)) { store.sidebarVisible.toggle() }
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
        }
        CommandGroup(before: .toolbar) {
            modeToggle(.read, store.t("Lectura")).keyboardShortcut("1")
            modeToggle(.edit, store.t("Editor")).keyboardShortcut("2")
            modeToggle(.source, store.t("Código")).keyboardShortcut("3")
            Button(store.t("Alternar lectura y edición")) { store.toggleEditing() }.keyboardShortcut("e")
            Divider()
            Button(store.focusMode ? store.t("Salir del modo enfoque") : store.t("Modo enfoque")) {
                withAnimation(.snappy(duration: 0.24)) { store.focusMode.toggle() }
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            Divider()
            Button(store.t("Aumentar texto")) { store.zoom(1) }.keyboardShortcut("+")
            Button(store.t("Reducir texto")) { store.zoom(-1) }.keyboardShortcut("-")
            Button(store.t("Tamaño original")) { store.resetZoom() }.keyboardShortcut("0")
            Divider()
            Button(store.t("Título anterior")) { store.navigateRelative(-1) }.keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button(store.t("Título siguiente")) { store.navigateRelative(1) }.keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Divider()
        }
        CommandGroup(replacing: .help) {
            Button(store.t("Atajos de teclado")) { store.showShortcuts = true }.keyboardShortcut("/")
            Divider()
            Link(store.t("Guía de Markdown"), destination: URL(string: "https://www.markdownguide.org/basic-syntax/")!)
            Link(store.t("Especificación GFM"), destination: URL(string: "https://github.github.com/gfm/")!)
            Link(store.t("Informar de un problema"), destination: URL(string: "https://github.com/glozahn/md-lite/issues")!)
        }
    }

    private func modeToggle(_ mode: DocumentMode, _ title: String) -> some View {
        Toggle(title, isOn: Binding(get: { store.mode == mode }, set: { _ in store.setMode(mode) }))
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first { Task { @MainActor in ReaderStore.shared.open(url) } }
        application.windows.first?.makeKeyAndOrderFront(nil)
        application.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated { ReaderStore.shared.confirmDiscard() } ? .terminateNow : .terminateCancel
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct ReaderWindow: View {
    @ObservedObject var store: ReaderStore
    @State private var isDropTarget = false
    @State private var showQuickSettings = false
    @Namespace private var modeNamespace
    @Environment(\.colorScheme) private var colorScheme

    private var paper: Color { colorScheme == .dark ? Color(red: 0.085, green: 0.095, blue: 0.11) : Color(red: 0.985, green: 0.981, blue: 0.967) }
    private var showSidebar: Bool { store.sidebarVisible && !store.focusMode }

    var body: some View {
        HStack(spacing: 0) {
            if showSidebar {
                Sidebar(store: store)
                    .frame(width: 252)
                    .sidebarGlass()
                    .padding(.leading, 10).padding(.top, 10)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            VStack(spacing: 0) {
                toolbar
                if store.mode != .read && !store.focusMode {
                    FormatBar(store: store)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                Rectangle().fill(.primary.opacity(0.07)).frame(height: 1)
                if store.mode == .read, store.blockedRemoteImages > 0 { remoteBanner }
                DocumentView(store: store)
                if !store.focusMode { footer }
            }
            .background(paper)
        }
        .animation(.snappy(duration: 0.24), value: showSidebar)
        .animation(.snappy(duration: 0.2), value: store.mode)
        .tint(store.accentColor)
        .background(.background)
        .background { hiddenShortcuts }
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 16).strokeBorder(store.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .padding(10).allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, url.isFileURL else { return false }
            store.open(url)
            return true
        } isTargeted: { isDropTarget = $0 }
        .sheet(isPresented: $store.showPasteEditor) { PasteEditor(store: store) }
        .sheet(isPresented: $store.showShortcuts) { ShortcutsView(store: store) }
        .sheet(isPresented: $store.showDefaultAppGuide) { DefaultAppGuide(store: store) }
        .alert(store.t("No se pudo leer el archivo"), isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button(store.t("Entendido"), role: .cancel) { store.error = nil }
        } message: { Text(store.error ?? "") }
        .onAppear {
            store.setDarkAppearance(colorScheme == .dark)
            store.renderNow()
            store.refreshDefaultApp()
            UpdateChecker.checkAutomaticallyIfNeeded(store)
        }
        .onChange(of: colorScheme) { _, scheme in store.setDarkAppearance(scheme == .dark) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in store.refreshDefaultApp() }
    }

    /// Extra shortcut aliases that do not need a menu item.
    private var hiddenShortcuts: some View {
        ZStack {
            Button("") { withAnimation(.snappy(duration: 0.24)) { store.sidebarVisible.toggle() } }.keyboardShortcut("\\")
            Button("") { store.zoom(1) }.keyboardShortcut("=")
        }
        .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            if !showSidebar { Spacer().frame(width: 62) }
            toolButton("sidebar.left", label: (showSidebar ? store.t("Ocultar barra lateral") : store.t("Mostrar barra lateral")) + " · ⌃⌘S") {
                if store.focusMode { store.focusMode = false } else { store.sidebarVisible.toggle() }
            }
            HStack(spacing: 7) {
                Image(systemName: store.isNewNote ? "square.and.pencil" : "doc.text").foregroundStyle(.tertiary)
                Text(store.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                if store.isDirty {
                    Circle().fill(store.accentColor).frame(width: 6, height: 6)
                        .help(store.fileURL == nil ? store.t("Sin guardar · ⌘S") : store.t("Guardando…"))
                } else {
                    Text(".md").font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            modeSwitcher
            toolButton("magnifyingglass", label: store.t("Buscar · ⌘F")) { store.find(.showFindInterface) }
            HStack(spacing: 0) {
                Button { store.zoom(-1) } label: {
                    Text("A−").font(.system(size: 12, weight: .medium)).frame(width: 30, height: 28)
                }.disabled(store.fontSize <= 12).help(store.t("Reducir texto") + " · ⌘−")
                    .accessibilityLabel(store.t("Reducir texto"))
                Button { store.resetZoom() } label: {
                    Text("\(Int(store.fontSize))").font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary).frame(width: 22, height: 28)
                }.help(store.t("Tamaño original") + " · ⌘0").accessibilityLabel(store.t("Tamaño original"))
                Button { store.zoom(1) } label: {
                    Text("A+").font(.system(size: 14, weight: .medium)).frame(width: 30, height: 28)
                }.disabled(store.fontSize >= 28).help(store.t("Aumentar texto") + " · ⌘+")
                    .accessibilityLabel(store.t("Aumentar texto"))
            }.buttonStyle(.plain).readerGlass(cornerRadius: 11, interactive: true)
            Link(destination: URL(string: "https://github.com/glozahn/md-lite")!) {
                Image(systemName: "star.fill").font(.system(size: 12, weight: .medium))
                    .foregroundStyle(store.accentColor).frame(width: 26, height: 28)
            }
            .buttonStyle(.plain)
            .help(store.t("Dejar una estrella en GitHub"))
            .accessibilityLabel(store.t("Dejar una estrella en GitHub"))
            Button { showQuickSettings.toggle() } label: {
                Image(systemName: "slider.horizontal.3").font(.system(size: 13.5)).frame(width: 30, height: 28)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 3)
            .readerGlass(cornerRadius: 11, interactive: true)
            .popover(isPresented: $showQuickSettings, arrowEdge: .top) { QuickSettingsView(store: store) }
            .help(store.t("Tipografía y apariencia"))
            .accessibilityLabel(store.t("Preferencias"))
        }
        .padding(.horizontal, 20).frame(height: 56)
    }

    private var modeSwitcher: some View {
        HStack(spacing: 2) {
            modeButton(.read, symbol: "book", label: store.t("Lectura"), keys: "⌘1")
            modeButton(.edit, symbol: "pencil.line", label: store.t("Editor"), keys: "⌘2")
            modeButton(.source, symbol: "chevron.left.forwardslash.chevron.right", label: store.t("Código"), keys: "⌘3")
        }
        .padding(3)
        .readerGlass(cornerRadius: 12, interactive: true)
    }

    private func modeButton(_ mode: DocumentMode, symbol: String, label: String, keys: String) -> some View {
        let selected = store.mode == mode
        return Button { store.setMode(mode) } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 11.5, weight: .medium))
                if selected { Text(label).font(.system(size: 11.5, weight: .medium)).lineLimit(1) }
            }
            .foregroundStyle(selected ? store.accentColor : Color.secondary)
            .padding(.horizontal, selected ? 10 : 8).frame(height: 24)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 8).fill(store.accentColor.opacity(0.13))
                        .matchedGeometryEffect(id: "mode", in: modeNamespace)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(label) · \(keys)")
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func toolButton(_ symbol: String, label: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(active ? store.accentColor : Color.secondary)
                .frame(width: 28, height: 28).background(active ? store.accentColor.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).help(label).accessibilityLabel(label)
    }

    private var remoteBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.secondary)
            Text(String(format: store.t("%d imágenes remotas bloqueadas para proteger tu privacidad."), store.blockedRemoteImages))
                .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Button(store.t("Mostrar")) { store.allowRemoteImages() }.controlSize(.small)
        }
        .padding(.horizontal, 22).padding(.vertical, 7)
        .background(.primary.opacity(0.03))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.alignleft").font(.system(size: 9))
            Text("\(store.wordCount) " + store.t("palabras"))
            Text("·")
            Text("\(store.readingMinutes) " + store.t("min de lectura"))
            Text("·")
            Text("\(Int((store.progress * 100).rounded()))%").monospacedDigit()
            Spacer()
            saveStatus
            Circle().fill(store.accentColor.opacity(0.65)).frame(width: 4, height: 4)
            Text(modeLabel).tracking(1.1)
            Text("UTF-8")
        }.font(.system(size: 9.5)).foregroundStyle(.tertiary)
            .padding(.horizontal, 24).frame(height: 30)
            .overlay(alignment: .top) { Rectangle().fill(.primary.opacity(0.05)).frame(height: 1) }
    }

    @ViewBuilder private var saveStatus: some View {
        if store.isDirty {
            Text(store.fileURL == nil ? store.t("Sin guardar · ⌘S") : store.t("Guardando…"))
        } else if store.lastSaved != nil, store.fileURL != nil {
            Label(store.t("Guardado"), systemImage: "checkmark").labelStyle(.titleAndIcon)
        }
    }

    private var modeLabel: String {
        switch store.mode {
        case .read: return store.t("LECTURA")
        case .edit: return store.t("EDITOR")
        case .source: return store.t("CÓDIGO FUENTE")
        }
    }
}

struct Sidebar: View {
    @ObservedObject var store: ReaderStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11).fill(store.accentColor.opacity(0.12)).frame(width: 36, height: 36)
                    Image(systemName: "text.book.closed.fill").font(.system(size: 17, weight: .medium)).foregroundStyle(store.accentColor)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("MD Lite").font(.system(size: 15.5, weight: .semibold))
                    Text(store.t("ESPACIO PARA LEER")).font(.system(size: 8, weight: .medium)).tracking(1.7).foregroundStyle(.secondary)
                }
            }.padding(.top, 46).padding(.horizontal, 20).padding(.bottom, 20)

            Button(action: store.openPanel) {
                HStack {
                    Image(systemName: "plus").font(.system(size: 12, weight: .medium))
                    Text(store.t("Abrir documento")).font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text("⌘O").font(.system(size: 10)).foregroundStyle(.tertiary)
                }.padding(10).background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9)).contentShape(Rectangle())
            }.buttonStyle(.plain).padding(.horizontal, 14)

            HStack(spacing: 6) {
                smallAction(store.t("Nueva nota"), symbol: "square.and.pencil", keys: "⌘N", action: store.newNote)
                smallAction(store.t("Pegar"), symbol: "doc.on.clipboard", keys: "⇧⌘V", action: store.presentPasteEditor)
            }.padding(.horizontal, 14).padding(.top, 6)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        sectionLabel(store.t("DOCUMENTO")).padding(.top, 4)
                        documentRow(store.t("Bienvenido"), symbol: "sparkle", selected: store.isWelcome) { store.welcome() }
                        if !store.isWelcome {
                            HStack(spacing: 6) {
                                Label(store.title, systemImage: store.isNewNote ? "square.and.pencil" : "doc.text")
                                    .font(.system(size: 12, weight: .medium)).lineLimit(1)
                                Spacer(minLength: 0)
                                if store.isDirty { Circle().fill(store.accentColor).frame(width: 5, height: 5) }
                            }
                            .foregroundStyle(store.accentColor).padding(8)
                            .background(store.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 7))
                        }
                        OutlineNavigator(store: store, proxy: proxy).padding(.top, 14)
                        if !store.recent.isEmpty {
                            sectionLabel(store.t("RECIENTES")).padding(.top, 16)
                            let recent = Array(store.recent.prefix(5))
                            ForEach(recent, id: \.self) { url in
                                let duplicate = recent.filter { $0.lastPathComponent == url.lastPathComponent }.count > 1
                                Button { store.open(url) } label: {
                                    HStack(spacing: 5) {
                                        Label(url.lastPathComponent, systemImage: "doc.plaintext").lineLimit(1)
                                        if duplicate {
                                            Text(url.deletingLastPathComponent().lastPathComponent)
                                                .foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                                        }
                                    }
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(7).contentShape(Rectangle())
                                }.buttonStyle(.plain).help(url.path)
                            }
                        }
                    }.padding(.horizontal, 14).padding(.vertical, 12)
                }
            }
            bottomCard
        }
    }

    @ViewBuilder private var bottomCard: some View {
        if store.defaultApp.isDefault == false {
            Button { store.showDefaultAppGuide = true } label: {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Image(systemName: "doc.badge.arrow.up").foregroundStyle(store.accentColor)
                        Text(store.t("Abre tus .md con MD Lite")).font(.system(size: 11.5, weight: .semibold))
                    }
                    Text(store.t("Doble clic en Finder y se abren aquí."))
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    Text(store.t("Ver cómo →")).font(.system(size: 10.5, weight: .medium)).foregroundStyle(store.accentColor)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .readerGlass(cornerRadius: 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14).padding(.bottom, 14)
        } else {
            HStack(spacing: 8) {
                Circle().fill(store.accentColor).frame(width: 6, height: 6)
                Text(store.t("Lectura local")).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Button { store.showShortcuts = true } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "command").font(.system(size: 9, weight: .semibold))
                        Text(store.t("Atajos")).font(.system(size: 10, weight: .medium))
                    }.foregroundStyle(.secondary)
                }.buttonStyle(.plain).help(store.t("Atajos de teclado") + " · ⌘/")
            }
            .padding(.horizontal, 20).padding(.vertical, 16)
        }
    }

    private func smallAction(_ title: String, symbol: String, keys: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 11))
                Text(title).font(.system(size: 11.5)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9).padding(.vertical, 8)
            .background(.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help("\(title) · \(keys)")
    }

    private func documentRow(_ title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.system(size: 12))
                .foregroundStyle(selected ? store.accentColor : Color.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                .background(selected ? store.accentColor.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title).font(.system(size: 9, weight: .semibold)).tracking(1.3).foregroundStyle(.tertiary).padding(.horizontal, 8).padding(.bottom, 4)
    }
}

/// "On this page" navigator: collapsible heading tree with a reading rail and scroll tracking.
struct OutlineNavigator: View {
    @ObservedObject var store: ReaderStore
    let proxy: ScrollViewProxy
    @State private var collapsed = Set<Int>()
    @State private var filter = ""
    @State private var hovered: Int?

    private var items: [OutlineItem] { store.outline }
    private var minLevel: Int { items.map(\.level).min() ?? 1 }

    private var visible: [OutlineItem] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            return items.filter { $0.title.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
        var result: [OutlineItem] = []
        var hiddenBelow: Int?
        for item in items {
            if let level = hiddenBelow, item.level > level { continue }
            hiddenBelow = collapsed.contains(item.id) ? item.level : nil
            result.append(item)
        }
        return result
    }

    private func hasChildren(_ item: OutlineItem) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == item.id }), index + 1 < items.count else { return false }
        return items[index + 1].level > item.level
    }

    /// The heading that owns the current position, even when it is folded away.
    private var activeVisible: Int? {
        guard let current = store.currentHeading else { return nil }
        let shown = Set(visible.map(\.id))
        if shown.contains(current) { return current }
        guard let index = items.firstIndex(where: { $0.id == current }) else { return nil }
        var level = items[index].level
        for candidate in items[..<index].reversed() where candidate.level < level {
            if shown.contains(candidate.id) { return candidate.id }
            level = candidate.level
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(store.t("EN ESTA PÁGINA")).font(.system(size: 9, weight: .semibold)).tracking(1.3).foregroundStyle(.tertiary)
                if !items.isEmpty {
                    Text("\(items.count)").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                        .padding(.horizontal, 5).padding(.vertical, 1).background(.primary.opacity(0.05), in: Capsule())
                }
                Spacer()
                if items.contains(where: hasChildren) {
                    Button {
                        withAnimation(.snappy(duration: 0.2)) {
                            collapsed = collapsed.isEmpty ? Set(items.filter(hasChildren).filter { $0.level > minLevel || items.filter { $0.level == minLevel }.count > 1 }.map(\.id)) : []
                        }
                    } label: {
                        Image(systemName: collapsed.isEmpty ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help(collapsed.isEmpty ? store.t("Contraer todo") : store.t("Expandir todo"))
                    .accessibilityLabel(collapsed.isEmpty ? store.t("Contraer todo") : store.t("Expandir todo"))
                }
            }
            .padding(.horizontal, 8).padding(.bottom, 5)

            if items.count > 10 {
                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal.decrease").font(.system(size: 10)).foregroundStyle(.tertiary)
                    TextField(store.t("Filtrar títulos"), text: $filter).textFieldStyle(.plain).font(.system(size: 11))
                    if !filter.isEmpty {
                        Button { filter = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 10)) }
                            .buttonStyle(.plain).foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
                .padding(.bottom, 6)
            }

            if items.isEmpty {
                Text(store.t("Los títulos aparecerán aquí.")).font(.system(size: 11)).foregroundStyle(.tertiary).padding(8)
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(visible) { item in row(item, active: activeVisible == item.id) }
                }
                .overlay(alignment: .leading) {
                    Rectangle().fill(.primary.opacity(0.08)).frame(width: 1).padding(.leading, 8).padding(.vertical, 6)
                }
            }
        }
        .onChange(of: store.contentVersion) { _, _ in collapsed = []; filter = "" }
        .onChange(of: store.currentHeading) { _, id in
            guard let id = activeVisible ?? id, hovered == nil else { return }
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id) }
        }
    }

    private func row(_ item: OutlineItem, active: Bool) -> some View {
        let depth = min(4, item.level - minLevel)
        let parent = hasChildren(item)
        return HStack(spacing: 3) {
            Capsule().fill(active ? store.accentColor : .clear).frame(width: 2.5, height: 16).padding(.leading, 7)
            Spacer().frame(width: CGFloat(depth) * 11 + 2)
            if parent && filter.isEmpty {
                Button {
                    withAnimation(.snappy(duration: 0.2)) {
                        if collapsed.contains(item.id) { collapsed.remove(item.id) } else { collapsed.insert(item.id) }
                    }
                } label: {
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(collapsed.contains(item.id) ? 0 : 90))
                        .foregroundStyle(.tertiary).frame(width: 12, height: 16).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Spacer().frame(width: 12)
            }
            Text(item.title)
                .font(.system(size: depth == 0 ? 12.5 : (depth == 1 ? 12 : 11.5), weight: active ? .semibold : (depth == 0 ? .medium : .regular)))
                .foregroundStyle(active ? store.accentColor : (depth == 0 ? Color.primary.opacity(0.85) : Color.secondary))
                .lineLimit(2).multilineTextAlignment(.leading)
            Spacer(minLength: 4)
        }
        .padding(.vertical, 5).padding(.trailing, 6)
        .background {
            RoundedRectangle(cornerRadius: 7)
                .fill(active ? store.accentColor.opacity(0.09) : (hovered == item.id ? Color.primary.opacity(0.045) : .clear))
        }
        .contentShape(Rectangle())
        .onTapGesture { store.navigate(item) }
        .onHover { inside in hovered = inside ? item.id : (hovered == item.id ? nil : hovered) }
        .help(item.title)
        .id(item.id)
        .animation(.easeOut(duration: 0.15), value: active)
    }
}

struct FormatBar: View {
    @ObservedObject var store: ReaderStore

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                textButton("H1", store.t("Título 1") + " · ⌥⌘1", .heading1)
                textButton("H2", store.t("Título 2") + " · ⌥⌘2", .heading2)
                textButton("H3", store.t("Título 3") + " · ⌥⌘3", .heading3)
                divider
                button("bold", store.t("Negrita") + " · ⌘B", .bold)
                button("italic", store.t("Cursiva") + " · ⌘I", .italic)
                button("strikethrough", store.t("Tachado") + " · ⇧⌘X", .strikethrough)
                button("chevron.left.forwardslash.chevron.right", store.t("Código en línea") + " · ⇧⌘K", .code)
                button("link", store.t("Enlace") + " · ⌘K", .link)
                divider
                button("list.bullet", store.t("Lista") + " · ⇧⌘7", .bulletList)
                button("list.number", store.t("Lista numerada") + " · ⇧⌘9", .numberedList)
                button("checklist", store.t("Lista de tareas") + " · ⇧⌘L", .taskList)
                button("text.quote", store.t("Cita") + " · ⌘'", .quote)
                divider
                button("curlybraces", store.t("Bloque de código") + " · ⇧⌘M", .codeBlock)
                button("tablecells", store.t("Tabla") + " · ⌥⌘T", .table)
                button("minus", store.t("Separador") + " · ⌥⌘−", .rule)
                divider
                symbolButton("arrow.uturn.backward", store.t("Deshacer") + " · ⌘Z") { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) }
                symbolButton("arrow.uturn.forward", store.t("Rehacer") + " · ⇧⌘Z") { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) }
            }
            .padding(.horizontal, 18)
        }
        .frame(height: 34)
    }

    private var divider: some View { Rectangle().fill(.primary.opacity(0.1)).frame(width: 1, height: 16).padding(.horizontal, 6) }

    private func textButton(_ title: String, _ help: String, _ action: FormatAction) -> some View {
        Button { store.format(action) } label: {
            Text(title).font(.system(size: 11.5, weight: .semibold, design: .rounded)).frame(width: 28, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(FormatButtonStyle()).help(help).accessibilityLabel(help)
    }

    private func button(_ symbol: String, _ help: String, _ action: FormatAction) -> some View {
        symbolButton(symbol, help) { store.format(action) }
    }

    private func symbolButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium)).frame(width: 28, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(FormatButtonStyle()).help(help).accessibilityLabel(help)
    }
}

private struct FormatButtonStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.secondary)
            .background(RoundedRectangle(cornerRadius: 6).fill(.primary.opacity(configuration.isPressed ? 0.12 : (hovering ? 0.06 : 0))))
            .onHover { hovering = $0 }
    }
}

struct QuickSettingsView: View {
    @ObservedObject var store: ReaderStore

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            quickPicker(store.t("Apariencia"), selection: $store.appearance, options: [
                ("system", store.t("Sistema")), ("light", store.t("Claro")), ("dark", store.t("Oscuro"))
            ])
            quickPicker(store.t("Ancho del texto"), selection: $store.textWidth, options: [
                ("narrow", store.t("Estrecho")), ("normal", store.t("Normal")), ("wide", store.t("Ancho")), ("full", store.t("Completo"))
            ])
            quickPicker(store.t("Idioma"), selection: $store.language, options: [
                ("system", store.t("Sistema")), ("en", "English"), ("es", "Español")
            ])
            VStack(alignment: .leading, spacing: 8) {
                Text(store.t("Color de acento")).font(.system(size: 12, weight: .medium))
                HStack(spacing: 10) {
                    ForEach(AccentChoice.allCases) { choice in
                        Button { store.accent = choice.rawValue } label: {
                            Circle().fill(Color(nsColor: choice.color))
                                .frame(width: 20, height: 20)
                                .overlay { if store.accent == choice.rawValue { Circle().stroke(.primary, lineWidth: 2) } }
                        }
                        .buttonStyle(.plain)
                        .help(store.t(choice.label))
                    }
                }
            }
            Divider()
            Toggle(store.t("Cargar siempre imágenes remotas"), isOn: $store.alwaysLoadRemoteImages).font(.system(size: 12))
            Toggle(store.t("Buscar actualizaciones automáticamente"), isOn: $store.checkForUpdatesAutomatically).font(.system(size: 12))
            HStack {
                Image(systemName: store.defaultApp.isDefault == true ? "checkmark.circle.fill" : "doc.badge.gearshape")
                    .foregroundStyle(store.defaultApp.isDefault == true ? Color.green : Color.secondary)
                Text(store.defaultApp.isDefault == true ? store.t("MD Lite abre tus .md") : store.t("App para archivos .md"))
                    .font(.system(size: 12))
                Spacer()
                if store.defaultApp.isDefault != true {
                    Button(store.t("Configurar…")) { store.showDefaultAppGuide = true }.controlSize(.small)
                }
            }
            HStack {
                Button(store.t("Atajos de teclado")) { store.showShortcuts = true }.buttonStyle(.link)
                Spacer()
                Button(store.t("Buscar actualizaciones")) { UpdateChecker.check(store, userInitiated: true) }.buttonStyle(.link)
            }
            .font(.system(size: 11.5))
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(18)
        .frame(width: 320)
    }

    @ViewBuilder
    private func quickPicker(_ title: String, selection: Binding<String>, options: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .medium))
            Picker(title, selection: selection) {
                ForEach(options, id: \.0) { option in Text(option.1).tag(option.0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }
}

struct AboutView: View {
    @ObservedObject var store: ReaderStore
    private let githubURL = URL(string: "https://github.com/glozahn/md-lite")!

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 22)
                    .fill(store.accentColor.gradient)
                    .frame(width: 76, height: 76)
                Image(systemName: "text.book.closed.fill")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(.white)
            }
            VStack(spacing: 5) {
                Text("MD Lite").font(.system(size: 24, weight: .semibold))
                Text("A little space to read.").foregroundStyle(.secondary)
                Text("Version \(UpdateChecker.currentVersion) · MIT License").font(.caption).foregroundStyle(.tertiary)
            }
            Text(store.t("Un lector Markdown nativo y ligero para macOS."))
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
                .padding(.horizontal, 28)
            Link(destination: githubURL) {
                Label(store.t("Visitar GitHub y dejar una estrella"), systemImage: "star.fill")
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .background(store.accentColor, in: Capsule())
                    .foregroundStyle(.white)
            }
            Button(store.t("Buscar actualizaciones")) { UpdateChecker.check(store, userInitiated: true) }.buttonStyle(.link)
            Text("github.com/glozahn/md-lite")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tint(store.accentColor)
    }
}

struct PasteEditor: View {
    @ObservedObject var store: ReaderStore
    @FocusState private var editorFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(store.t("Pegar Markdown")).font(.title2.weight(.semibold))
            Text(store.t("Pega o escribe tu Markdown aquí.")).foregroundStyle(.secondary)
            TextEditor(text: $store.pasteDraft)
                .font(.system(size: 14, design: .monospaced))
                .padding(8)
                .background(.background, in: RoundedRectangle(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.2)) }
                .focused($editorFocused)
                .accessibilityLabel(store.t("Pegar Markdown"))
            Text(store.t("Este texto es temporal y no se guarda al cerrar la app."))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(store.t("Cancelar")) { store.showPasteEditor = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(store.t("Vista de lectura")) { store.readPastedText(store.pasteDraft) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(store.pasteDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 620, height: 470)
            .tint(store.accentColor)
            .onAppear { editorFocused = true }
    }
}

extension View {
    @ViewBuilder
    func sidebarGlass() -> some View {
        let shape = UnevenRoundedRectangle(cornerRadii: .init(topLeading: 18, bottomLeading: 0, bottomTrailing: 0, topTrailing: 18))
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
    }

    @ViewBuilder
    func readerGlass(cornerRadius: CGFloat, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular.interactive(interactive), in: RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }
}
