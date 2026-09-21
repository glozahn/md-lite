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
                .frame(minWidth: 720, minHeight: 480)
                .environment(\.locale, Locale(identifier: store.resolvedLanguage))
                .preferredColorScheme(store.appearance == "dark" ? .dark : store.appearance == "light" ? .light : nil)
        }
        .defaultSize(width: 1120, height: 800)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button(store.t("Acerca de MD Lite")) { openWindow(id: "about") }
            }
            CommandGroup(replacing: .newItem) {
                Button(store.t("Abrir Markdown…"), action: store.openPanel).keyboardShortcut("o")
                Button(store.t("Pegar y leer"), action: store.readClipboard).keyboardShortcut("v", modifiers: [.command, .shift])
                Button(store.t("Pegar Markdown"), action: store.presentPasteEditor)
                Button(store.t("Nueva nota"), action: store.newNote).keyboardShortcut("n")
                Menu(store.t("Abrir reciente")) {
                    ForEach(store.recent, id: \.self) { url in
                        Button(url.lastPathComponent) { store.open(url) }
                    }
                }
            }
            CommandGroup(after: .textEditing) {
                Button(store.t("Buscar en el documento")) { store.findRequest += 1 }.keyboardShortcut("f")
            }
            CommandMenu(store.t("Lectura")) {
                Button(store.focusMode ? store.t("Salir del modo enfoque") : store.t("Modo enfoque")) { store.focusMode.toggle() }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                Toggle(store.t("Ver código fuente"), isOn: $store.showSource).keyboardShortcut("s", modifiers: [.command, .shift])
                Divider()
                Button(store.t("Aumentar texto")) { store.zoom(1) }.keyboardShortcut("+")
                Button(store.t("Reducir texto")) { store.zoom(-1) }.keyboardShortcut("-")
                Button(store.t("Tamaño original")) { store.fontSize = 17; store.rebuild() }.keyboardShortcut("0")
                Divider()
                Button(store.t("Actualizar"), action: store.reload).keyboardShortcut("r")
            }
        }

        Window("About MD Lite", id: "about") {
            AboutView(store: store)
                .frame(width: 420, height: 360)
                .preferredColorScheme(store.appearance == "dark" ? .dark : store.appearance == "light" ? .light : nil)
        }
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first { ReaderStore.shared.open(url) }
        application.windows.first?.makeKeyAndOrderFront(nil)
        application.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct ReaderWindow: View {
    @ObservedObject var store: ReaderStore
    @State private var isDropTarget = false
    @State private var showQuickSettings = false
    @Environment(\.colorScheme) private var colorScheme

    private var paper: Color { colorScheme == .dark ? Color(red: 0.085, green: 0.095, blue: 0.11) : Color(red: 0.985, green: 0.981, blue: 0.967) }

    var body: some View {
        HStack(spacing: 0) {
            if !store.focusMode {
                sidebar.frame(width: 238)
                    .sidebarGlass()
                    .padding(.leading, 10).padding(.top, 10)
            }
            VStack(spacing: 0) {
                toolbar
                Rectangle().fill(.primary.opacity(0.07)).frame(height: 1)
                NativeReader(store: store)
                    .frame(maxWidth: 850)
                    .frame(maxWidth: .infinity)
                    .background(paper)
                footer
            }
            .background(paper)
        }
        .tint(store.accentColor)
        .background(.background)
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
        .sheet(isPresented: $store.showNoteEditor) { NoteEditor(store: store) }
        .alert(store.t("No se pudo leer el archivo"), isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button(store.t("Entendido"), role: .cancel) { store.error = nil }
        } message: { Text(store.error ?? "") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11).fill(store.accentColor.opacity(0.12)).frame(width: 37, height: 37)
                    Image(systemName: "text.book.closed.fill").font(.system(size: 18, weight: .medium)).foregroundStyle(store.accentColor)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("MD Lite").font(.system(size: 16, weight: .semibold))
                    Text(store.t("ESPACIO PARA LEER")).font(.system(size: 8, weight: .medium)).tracking(1.7).foregroundStyle(.secondary)
                }
            }.padding(.top, 48).padding(.horizontal, 22).padding(.bottom, 26)

            Button(action: store.openPanel) {
                HStack {
                    Image(systemName: "plus").font(.system(size: 12, weight: .medium))
                    Text(store.t("Abrir documento")).font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text("⌘O").font(.system(size: 10)).foregroundStyle(.tertiary)
                }.padding(11).background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
            }.buttonStyle(.plain).padding(.horizontal, 16)

            Button(action: store.presentPasteEditor) {
                Label(store.t("Pegar Markdown"), systemImage: "doc.on.clipboard")
                    .font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(11)
            }.buttonStyle(.plain).padding(.horizontal, 16).padding(.top, 5)
            Button(action: store.newNote) {
                Label(store.t("Nueva nota"), systemImage: "square.and.pencil")
                    .font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(11)
            }.buttonStyle(.plain).padding(.horizontal, 16)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    sectionLabel(store.t("DOCUMENTO"))
                    Button { store.welcome() } label: {
                        Label(store.t("Bienvenido"), systemImage: "sparkle").font(.system(size: 12))
                            .foregroundStyle(store.isWelcome ? store.accentColor : Color.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(9)
                            .background(store.isWelcome ? store.accentColor.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 7))
                    }.buttonStyle(.plain)
                    if !store.isWelcome {
                        Label(store.title, systemImage: "doc.text").font(.system(size: 12, weight: .medium))
                            .foregroundStyle(store.accentColor).lineLimit(1).padding(9)
                    }
                    sectionLabel(store.t("EN ESTA PÁGINA")).padding(.top, 16)
                    if store.rendered.outline.isEmpty {
                        Text(store.t("Los títulos aparecerán aquí.")).font(.system(size: 11)).foregroundStyle(.tertiary).padding(9)
                    }
                    ForEach(store.rendered.outline) { item in
                        Button { store.navigate(item) } label: {
                            HStack(alignment: .top, spacing: 9) {
                                RoundedRectangle(cornerRadius: 1).fill(store.selectedHeading == item.id ? store.accentColor : Color.secondary.opacity(0.25))
                                    .frame(width: 2, height: 12).padding(.top, 2)
                                Text(item.title).font(.system(size: 11, weight: store.selectedHeading == item.id ? .medium : .regular))
                                    .foregroundStyle(store.selectedHeading == item.id ? store.accentColor : Color.secondary)
                                    .lineLimit(2).multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                            }.padding(.vertical, 7).padding(.leading, 9 + CGFloat(max(0, item.level - 1)) * 9)
                        }.buttonStyle(.plain)
                    }
                    if !store.recent.isEmpty {
                        sectionLabel(store.t("RECIENTES")).padding(.top, 18)
                        ForEach(store.recent.prefix(5), id: \.self) { url in
                            Button { store.open(url) } label: {
                                Label(url.lastPathComponent, systemImage: "doc.plaintext")
                                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(9)
                            }.buttonStyle(.plain).help(url.path)
                        }
                    }
                }.padding(16)
            }
            if store.isWelcome {
                VStack(spacing: 9) {
                    Image(systemName: "arrow.down.doc").font(.system(size: 18, weight: .light))
                        .foregroundStyle(store.accentColor.opacity(0.75))
                    Text(store.t("Suelta un Markdown aquí"))
                        .font(.system(size: 11, weight: .medium))
                    Text(store.t("o crea una nota nueva"))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .readerGlass(cornerRadius: 16)
                .padding(.horizontal, 16).padding(.bottom, 16)
            } else {
                HStack(spacing: 8) {
                    Circle().fill(store.accentColor).frame(width: 6, height: 6)
                    Text(store.t("Lectura local"))
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 22).padding(.vertical, 18)
            }

        }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title).font(.system(size: 9, weight: .semibold)).tracking(1.3).foregroundStyle(.tertiary).padding(.horizontal, 9).padding(.bottom, 5)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            if store.focusMode { Spacer().frame(width: 60) }
            toolButton("sidebar.left", label: store.focusMode ? store.t("Mostrar barra lateral") : store.t("Modo enfoque")) { store.focusMode.toggle() }
            HStack(spacing: 7) {
                Image(systemName: "doc.text").foregroundStyle(.tertiary)
                Text(store.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(".md").font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            toolButton("magnifyingglass", label: store.t("Buscar · ⌘F")) { store.findRequest += 1 }
            toolButton("chevron.left.forwardslash.chevron.right", label: store.t("Ver código fuente · ⇧⌘S"), active: store.showSource) { store.showSource.toggle() }
            HStack(spacing: 0) {
                Button { store.zoom(-1) } label: {
                    Text("A−").font(.system(size: 12, weight: .medium)).frame(width: 32, height: 30)
                }.disabled(store.fontSize <= 12).help(store.t("Reducir texto"))
                    .accessibilityLabel(store.t("Reducir texto"))
                Button { store.fontSize = 17; store.rebuild() } label: {
                    Text("\(Int(store.fontSize))").font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary).frame(width: 24, height: 30)
                }.help(store.t("Tamaño original")).accessibilityLabel(store.t("Tamaño original"))
                Button { store.zoom(1) } label: {
                    Text("A+").font(.system(size: 15, weight: .medium)).frame(width: 32, height: 30)
                }.disabled(store.fontSize >= 28).help(store.t("Aumentar texto"))
                    .accessibilityLabel(store.t("Aumentar texto"))
            }.buttonStyle(.plain).readerGlass(cornerRadius: 12, interactive: true)
            Link(destination: URL(string: "https://github.com/glozahn/md-lite")!) {
                Image(systemName: "star.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(store.accentColor)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help(store.t("Dejar una estrella en GitHub"))
            .accessibilityLabel(store.t("Dejar una estrella en GitHub"))
            toolButton("doc.badge.gearshape", label: store.t("Asociar archivos Markdown")) {
                store.associateMarkdownFiles()
            }
            Button { showQuickSettings.toggle() } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 14))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 5)
            .readerGlass(cornerRadius: 12, interactive: true)
            .popover(isPresented: $showQuickSettings, arrowEdge: .top) {
                QuickSettingsView(store: store)
            }
            .help(store.t("Tipografía y apariencia"))
            .accessibilityLabel(store.t("Preferencias"))
        }.padding(.horizontal, 24).frame(height: 66)
    }

    private func toolButton(_ symbol: String, label: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(active ? store.accentColor : Color.secondary)
                .frame(width: 28, height: 28).background(active ? store.accentColor.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain).help(label).accessibilityLabel(label)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.alignleft").font(.system(size: 9))
            Text("\(store.wordCount) " + store.t("palabras"))
            Text("·")
            Text("\(store.readingMinutes) " + store.t("min de lectura"))
            Spacer()
            Text(store.showSource ? store.t("CÓDIGO FUENTE") : store.t("MARKDOWN")) .tracking(1.1)
            Circle().fill(store.accentColor.opacity(0.65)).frame(width: 4, height: 4)
            Text("UTF-8")
        }.font(.system(size: 9)).foregroundStyle(.tertiary)
            .padding(.horizontal, 28).frame(height: 34)
            .overlay(alignment: .top) { Rectangle().fill(.primary.opacity(0.05)).frame(height: 1) }
    }
}

struct QuickSettingsView: View {
    @ObservedObject var store: ReaderStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            quickPicker(store.t("Apariencia"), selection: $store.appearance, options: [
                ("system", store.t("Sistema")), ("light", store.t("Claro")), ("dark", store.t("Oscuro"))
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
        }
        .padding(18)
        .frame(width: 280)
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
        VStack(spacing: 18) {
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
                Text("Version 0.2.1 · MIT License").font(.caption).foregroundStyle(.tertiary)
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

struct NoteEditor: View {
    @ObservedObject var store: ReaderStore
    @State private var draft = ""
    @State private var preview = false
    @FocusState private var focused: Bool

    private var rendered: NSAttributedString {
        MarkdownRenderer(size: 16, accent: store.accentNSColor, language: store.resolvedLanguage).render(draft).text
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(store.t("Crear nota")).font(.title2.weight(.semibold))
                Spacer()
                Picker("", selection: $preview) {
                    Text(store.t("Escribir")).tag(false)
                    Text(store.t("Vista previa")).tag(true)
                }.pickerStyle(.segmented).frame(width: 180)
            }.padding(.horizontal, 22).padding(.vertical, 16)
            Divider()
            if preview {
                NativePreview(attributed: rendered)
                    .frame(maxWidth: 760).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 6) {
                        editorTool("textformat.size", store.t("Título")) { insert("# ") }
                        editorTool("textformat.size.smaller", store.t("Subtítulo")) { insert("## ") }
                        editorTool("bold", store.t("Negrita")) { insert("****", cursorOffset: -2) }
                        editorTool("list.bullet", store.t("Lista")) { insert("- ") }
                        editorTool("tablecells", store.t("Tabla")) { insert("| Column 1 | Column 2 |\n| --- | --- |\n| Value | Value |\n") }
                        Spacer()
                    }.padding(10).background(.primary.opacity(0.04))
                    TextEditor(text: $draft)
                        .font(.system(size: 16, design: .monospaced))
                        .focused($focused).padding(18)
                }
            }
            Divider()
            HStack {
                Text(store.t("Los títulos y tablas se guardan como Markdown estándar."))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(store.t("Cancelar")) { store.showNoteEditor = false }.keyboardShortcut(.cancelAction)
                Button(store.t("Guardar Markdown")) { store.saveNote(draft) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding(16)
        }
        .frame(width: 900, height: 640)
        .tint(store.accentColor)
        .onAppear { draft = store.noteDraft; focused = true }
    }

    private func insert(_ value: String, cursorOffset: Int = 0) {
        draft += value
    }

    private func editorTool(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).frame(width: 30, height: 28) }
            .buttonStyle(.plain).help(label).accessibilityLabel(label)
    }
}

struct NativePreview: NSViewRepresentable {
    let attributed: NSAttributedString
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let text = NSTextView(usingTextLayoutManager: false)
        text.isEditable = false
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 30, height: 26)
        scroll.documentView = text
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        (scroll.documentView as? NSTextView)?.textStorage?.setAttributedString(attributed)
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
