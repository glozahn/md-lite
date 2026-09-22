import SwiftUI
import AppKit

struct ReaderWindow: View {
    @ObservedObject var store: ReaderStore
    @State private var isDropTarget = false
    @Namespace private var modeNamespace
    @Environment(\.colorScheme) private var colorScheme

    private var paper: Color { colorScheme == .dark ? Color(red: 0.085, green: 0.095, blue: 0.11) : Color(red: 0.985, green: 0.981, blue: 0.967) }
    private var showSidebar: Bool { store.sidebarVisible && !store.focusMode }

    var body: some View {
        HStack(spacing: 0) {
            if showSidebar {
                Sidebar(store: store)
                    .frame(width: 262)
                    .background { sidebarBackground }
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
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            for url in files {
                var isFolder: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue {
                    store.setWorkspace(url)
                } else {
                    DocumentRouter.shared.open(url, from: store)
                }
            }
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
        }
        .onChange(of: colorScheme) { _, scheme in store.setDarkAppearance(scheme == .dark) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in store.refreshDefaultApp() }
    }

    private var sidebarBackground: some View {
        let palette = SidebarPalette(scheme: colorScheme)
        return LinearGradient(colors: [palette.top, palette.bottom], startPoint: .top, endPoint: .bottom)
            .overlay(alignment: .trailing) { Rectangle().fill(palette.rail).frame(width: 1) }
            .ignoresSafeArea()
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
            Button { store.showQuickSettings.toggle() } label: {
                Image(systemName: "slider.horizontal.3").font(.system(size: 13.5)).frame(width: 30, height: 28)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 3)
            .readerGlass(cornerRadius: 11, interactive: true)
            .popover(isPresented: $store.showQuickSettings, arrowEdge: .top) { QuickSettingsView(prefs: store.prefs, store: store) }
            .help(store.t("Tipografía y apariencia"))
            .accessibilityLabel(store.t("Preferencias"))
        }
        .padding(.horizontal, 20).frame(height: 56)
    }

    private var modeSwitcher: some View {
        ViewThatFits(in: .horizontal) {
            modeButtons(labels: true)
            modeButtons(labels: false)
        }
    }

    private func modeButtons(labels: Bool) -> some View {
        HStack(spacing: 2) {
            modeButton(.read, symbol: "book", label: store.t("Lectura"), keys: "⌘1", showLabel: labels)
            modeButton(.edit, symbol: "pencil.line", label: store.t("Editor"), keys: "⌘2", showLabel: labels)
            modeButton(.source, symbol: "chevron.left.forwardslash.chevron.right", label: store.t("Código"), keys: "⌘3", showLabel: labels)
            modeButton(.split, symbol: "rectangle.split.2x1", label: store.t("Dividida"), keys: "⌘4", showLabel: labels)
        }
        .padding(3)
        .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 11))
    }

    private func modeButton(_ mode: DocumentMode, symbol: String, label: String, keys: String, showLabel: Bool) -> some View {
        let selected = store.mode == mode
        return Button { store.setMode(mode) } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 11.5, weight: .medium))
                if showLabel || selected { Text(label).font(.system(size: 12, weight: .medium)).lineLimit(1).fixedSize() }
            }
            .foregroundStyle(selected ? store.accentColor : Color.secondary)
            .padding(.horizontal, 10).frame(height: 26)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 8).fill(colorScheme == .dark ? Color.white.opacity(0.12) : Color.white)
                        .shadow(color: .black.opacity(0.1), radius: 1.5, y: 1)
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
        case .split: return store.t("DIVIDIDA")
        }
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

/// Reading preferences shared by the toolbar popover and the Settings window (Command-comma).
struct QuickSettingsView: View {
    @ObservedObject var prefs: AppPreferences
    var store: ReaderStore?
    var wide = false

    private func t(_ key: String) -> String { prefs.t(key) }
    private var target: ReaderStore? { store ?? DocumentRouter.shared.keyStore }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            quickPicker(t("Apariencia"), selection: $prefs.appearance, options: [
                ("system", t("Sistema")), ("light", t("Claro")), ("dark", t("Oscuro"))
            ])
            quickPicker(t("Ancho del texto"), selection: $prefs.textWidth, options: [
                ("narrow", t("Estrecho")), ("normal", t("Normal")), ("wide", t("Ancho")), ("full", t("Completo"))
            ])
            quickPicker(t("Idioma"), selection: $prefs.language, options: [
                ("system", t("Sistema")), ("en", "English"), ("es", "Español")
            ])
            VStack(alignment: .leading, spacing: 8) {
                Text(t("Color de acento")).font(.system(size: 12, weight: .medium))
                HStack(spacing: 10) {
                    ForEach(AccentChoice.allCases) { choice in
                        Button { prefs.accent = choice.rawValue } label: {
                            Circle().fill(Color(nsColor: choice.color))
                                .frame(width: 20, height: 20)
                                .overlay { if prefs.accent == choice.rawValue { Circle().stroke(.primary, lineWidth: 2) } }
                        }
                        .buttonStyle(.plain)
                        .help(t(choice.label))
                    }
                }
            }
            if wide {
                VStack(alignment: .leading, spacing: 8) {
                    Text(t("Tamaño del texto")).font(.system(size: 12, weight: .medium))
                    HStack {
                        Slider(value: $prefs.fontSize, in: 12...28, step: 1)
                        Text("\(Int(prefs.fontSize)) pt").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).frame(width: 44)
                    }
                }
            }
            Divider()
            Toggle(t("Cargar siempre imágenes remotas"), isOn: $prefs.alwaysLoadRemoteImages).font(.system(size: 12))
            Toggle(t("Buscar actualizaciones automáticamente"), isOn: $prefs.checkForUpdatesAutomatically).font(.system(size: 12))
            HStack {
                Image(systemName: prefs.defaultApp.isDefault == true ? "checkmark.circle.fill" : "doc.badge.gearshape")
                    .foregroundStyle(prefs.defaultApp.isDefault == true ? Color.green : Color.secondary)
                Text(prefs.defaultApp.isDefault == true ? t("MD Lite abre tus .md") : t("App para archivos .md"))
                    .font(.system(size: 12))
                Spacer()
                if prefs.defaultApp.isDefault != true {
                    Button(t("Configurar…")) { target?.showDefaultAppGuide = true }.controlSize(.small)
                }
            }
            HStack {
                Button(t("Atajos de teclado")) { target?.showQuickSettings = false; target?.showShortcuts = true }.buttonStyle(.link)
                Spacer()
                Button(t("Buscar actualizaciones")) { UpdateChecker.check(prefs, userInitiated: true) }.buttonStyle(.link)
            }
            .font(.system(size: 11.5))
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(wide ? 24 : 18)
        .frame(width: wide ? 420 : 320)
        .tint(prefs.accentColor)
        .onAppear { prefs.refreshDefaultApp() }
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

struct SettingsView: View {
    @ObservedObject var prefs: AppPreferences
    var body: some View {
        QuickSettingsView(prefs: prefs, wide: true)
            .environment(\.locale, Locale(identifier: prefs.resolvedLanguage))
    }
}

struct AboutView: View {
    @ObservedObject var prefs: AppPreferences
    private let githubURL = URL(string: "https://github.com/glozahn/md-lite")!

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high).frame(width: 84, height: 84)
            VStack(spacing: 5) {
                Text("MD Lite").font(.system(size: 24, weight: .semibold))
                Text("A little space to read.").foregroundStyle(.secondary)
                Text("Version \(UpdateChecker.currentVersion) · MIT License").font(.caption).foregroundStyle(.tertiary)
            }
            Text(prefs.t("Un lector Markdown nativo y ligero para macOS."))
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
                .padding(.horizontal, 28)
            Link(destination: githubURL) {
                Label(prefs.t("Visitar GitHub y dejar una estrella"), systemImage: "star.fill")
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .background(prefs.accentColor, in: Capsule())
                    .foregroundStyle(.white)
            }
            Button(prefs.t("Buscar actualizaciones")) { UpdateChecker.check(prefs, userInitiated: true) }.buttonStyle(.link)
            Text("github.com/glozahn/md-lite")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tint(prefs.accentColor)
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
