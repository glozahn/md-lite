import SwiftUI
import AppKit
import Combine

/// One window: the sidebar and one or two panes of tabs.
struct WorkbenchView: View {
    @ObservedObject var bench: Workbench
    @ObservedObject private var prefs = AppPreferences.shared
    @Environment(\.colorScheme) private var colorScheme

    private var focused: ReaderStore { bench.focusedStore }
    private var showSidebar: Bool { prefs.sidebarVisible && !bench.focusMode }

    var body: some View {

        HStack(spacing: 0) {
            if showSidebar {
                Sidebar(store: focused, bench: bench)
                    .frame(width: 262)
                    .background { sidebarBackground }
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    // One ForEach for both layouts keeps each pane's identity, so its text view is never rebuilt.
                    let panes = bench.focusMode ? [bench.focusedPane] : bench.panes
                    ForEach(Array(panes.enumerated()), id: \.element.id) { index, pane in
                        if index > 0 { PaneDivider(bench: bench, width: geometry.size.width) }
                        PaneColumn(pane: pane, bench: bench, showsSidebarToggle: index == 0 && !bench.focusMode, showSidebar: showSidebar)
                            .frame(width: panes.count == 2 ? paneWidth(index, total: geometry.size.width) : nil)
                    }
                }
                .coordinateSpace(name: "panes")
            }
        }
        .animation(.snappy(duration: 0.24), value: showSidebar)
        .animation(.snappy(duration: 0.22), value: bench.panes.count)
        .animation(.snappy(duration: 0.28), value: bench.focusMode)
        .tint(prefs.accentColor)
        .background(.background)
        .background { hiddenShortcuts }
        .onAppear {
            prefs.refreshDefaultApp()
            bench.allStores.forEach { $0.setDarkAppearance(colorScheme == .dark) }
        }
        .onChange(of: colorScheme) { _, scheme in bench.allStores.forEach { $0.setDarkAppearance(scheme == .dark) } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            prefs.refreshDefaultApp()
            prefs.forgetCachedTags()
            bench.refreshWorkspace()
        }
    }

    private func paneWidth(_ index: Int, total: CGFloat) -> CGFloat {
        let left = (total * bench.splitRatio).rounded()
        return index == 0 ? left : max(0, total - left - 1)
    }

    /// Extra shortcut aliases that do not need a menu item.
    private var hiddenShortcuts: some View {
        ZStack {
            Button("") { withAnimation(.snappy(duration: 0.24)) { prefs.sidebarVisible.toggle() } }.keyboardShortcut("\\")
            Button("") { prefs.fontSize = min(28, prefs.fontSize + 1) }.keyboardShortcut("=")
            Button("") { bench.cycleTab(1) }.keyboardShortcut(.tab, modifiers: .control)
            Button("") { bench.cycleTab(-1) }.keyboardShortcut(.tab, modifiers: [.control, .shift])
        }
        .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
    }

    private var sidebarBackground: some View {
        let palette = SidebarPalette(scheme: colorScheme)
        return LinearGradient(colors: [palette.top, palette.bottom], startPoint: .top, endPoint: .bottom)
            .overlay(alignment: .trailing) { Rectangle().fill(palette.rail).frame(width: 1) }
            .ignoresSafeArea()
    }
}

/// Draggable line between two panes.
struct PaneDivider: View {
    @ObservedObject var bench: Workbench
    let width: CGFloat
    var body: some View {
        Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 1)
            .overlay { Color.clear.frame(width: 9).contentShape(Rectangle()) }
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("panes")).onChanged { value in
                guard width > 0 else { return }
                bench.splitRatio = min(0.78, max(0.22, value.location.x / width))
            }.onEnded { _ in UserDefaults.standard.set(bench.splitRatio, forKey: "paneRatio") })
    }
}

struct PaneColumn: View {
    @ObservedObject var pane: Pane
    @ObservedObject var bench: Workbench
    let showsSidebarToggle: Bool
    let showSidebar: Bool
    var body: some View {
        DocumentColumn(store: pane.selected, pane: pane, bench: bench, showsSidebarToggle: showsSidebarToggle, showSidebar: showSidebar)
    }
}

/// A pane: tab strip and controls, the document, and its status line.
struct DocumentColumn: View {
    @ObservedObject var store: ReaderStore
    @ObservedObject var pane: Pane
    @ObservedObject var bench: Workbench
    let showsSidebarToggle: Bool
    let showSidebar: Bool
    @StateObject private var drop = DropTracker()
    @State private var showPath = false
    @State private var barWidth: CGFloat = 1200
    @Namespace private var modeNamespace
    @Environment(\.colorScheme) private var colorScheme

    private var paper: Color { colorScheme == .dark ? Color(red: 0.085, green: 0.095, blue: 0.11) : Color(red: 0.985, green: 0.981, blue: 0.967) }
    private var isFocused: Bool { bench.focusedPaneID == pane.id }
    /// Tabs get their own row once there is more than one document in the window.
    private var showTabRow: Bool { pane.tabs.count > 1 || bench.panes.count > 1 }
    private var isLastPane: Bool { bench.panes.last === pane || store.focusMode }

    var body: some View {

        VStack(spacing: 0) {
            if store.focusMode {
                Color.clear.frame(height: 28)
            } else {
                toolbar
                if store.mode != .read {
                    FormatBar(store: store)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                Rectangle().fill(.primary.opacity(0.07)).frame(height: 1)
                if store.mode == .read, store.blockedRemoteImages > 0 { remoteBanner }
            }
            GeometryReader { geometry in
                Group {
                    if store.isBlank {
                        EmptyTabView(store: store, bench: bench)
                    } else {
                        DocumentView(store: store).id(store.id)
                    }
                }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .overlay { dropOverlay(in: geometry.size) }
                    .onDrop(of: [.mdliteTab, .fileURL], delegate: PaneDropDelegate(pane: pane, bench: bench, tracker: drop,
                                                                                  width: geometry.size.width, allowSides: bench.panes.count == 1))
            }
            if !store.focusMode { footer }
        }
        .background(paper)
        .simultaneousGesture(TapGesture().onEnded { bench.focus(pane: pane) })
        .overlay(alignment: .topTrailing) { if store.focusMode { FocusExitButton(store: store) } }
        .background {
            if store.focusMode {
                Button("") { withAnimation(.snappy(duration: 0.28)) { store.focusMode = false } }
                    .keyboardShortcut(.cancelAction).opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
            }
        }
        .animation(.snappy(duration: 0.2), value: store.mode)
        .sheet(isPresented: $store.showPasteEditor) { PasteEditor(store: store) }
        .sheet(isPresented: $store.showShortcuts) { ShortcutsView(store: store) }
        .sheet(isPresented: $store.showDefaultAppGuide) { DefaultAppGuide(store: store) }
        .alert(store.t("No se pudo leer el archivo"), isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button(store.t("Entendido"), role: .cancel) { store.error = nil }
        } message: { Text(store.error ?? "") }
        .task(id: store.id) { store.setDarkAppearance(colorScheme == .dark) }
    }

    @ViewBuilder private func dropOverlay(in size: CGSize) -> some View {
        if let zone = drop.zone {
            let half = CGSize(width: size.width / 2, height: size.height)
            let frame: CGRect = switch zone {
            case .left: CGRect(origin: .zero, size: half)
            case .right: CGRect(origin: CGPoint(x: size.width / 2, y: 0), size: half)
            case .center: CGRect(origin: .zero, size: size)
            }
            let label: (String, String) = switch zone {
            case .left: ("rectangle.lefthalf.inset.filled", store.t("Abrir a la izquierda"))
            case .right: ("rectangle.righthalf.inset.filled", store.t("Abrir a la derecha"))
            case .center: ("plus.rectangle.on.rectangle", store.t("Abrir aquí en una pestaña"))
            }
            RoundedRectangle(cornerRadius: 14)
                .fill(store.accentColor.opacity(0.1))
                .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(store.accentColor.opacity(0.7), lineWidth: 2) }
                .overlay {
                    VStack(spacing: 8) {
                        Image(systemName: label.0).font(.system(size: 26, weight: .light))
                        Text(label.1).font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(store.accentColor)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                .padding(10)
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)
                .allowsHitTesting(false)
                .animation(.snappy(duration: 0.18), value: zone)
        }
    }

    /// One bar per pane: the document's title, or its tabs once there are several, then the controls.
    private var toolbar: some View {
        HStack(spacing: 10) {
            if showsSidebarToggle {
                if !showSidebar { Spacer().frame(width: 62) }
                toolButton("sidebar.left", label: (showSidebar ? store.t("Ocultar barra lateral") : store.t("Mostrar barra lateral")) + " · ⌃⌘S") {
                    if store.focusMode { store.focusMode = false } else { store.sidebarVisible.toggle() }
                }
            }
            if showTabRow {
                TabStrip(pane: pane, bench: bench, isFocused: isFocused)
            } else {
                titleButton
                Spacer(minLength: 8)
            }
            if !store.isBlank {
                modeSwitcher
                toolButton("arrow.up.left.and.arrow.down.right", label: store.t("Modo enfoque") + " · ⇧⌘F") { store.toggleFocus() }
                toolButton("magnifyingglass", label: store.t("Buscar · ⌘F")) { store.find(.showFindInterface) }
            }
            if isLastPane { globalControls }
        }
        .padding(.leading, showsSidebarToggle ? 20 : 12).padding(.trailing, 16).frame(height: 56)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { barWidth = $0 }
    }

    /// File name; hover shows the full path, a click shows where it lives.
    private var titleButton: some View {
        Button { showPath.toggle() } label: {
            HStack(spacing: 7) {
                Image(systemName: store.isNewNote ? "square.and.pencil" : "doc.text").foregroundStyle(.tertiary)
                Text(store.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                if store.isDirty {
                    Circle().fill(store.accentColor).frame(width: 6, height: 6)
                } else {
                    Text(".md").font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(store.fileURL?.path ?? store.t("Este documento aún no está guardado."))
        .popover(isPresented: $showPath, arrowEdge: .bottom) { PathPopover(store: store).onDisappear { showPath = false } }
        .onDrag { store.dragProvider() }
    }

    /// Settings shared by every pane; shown once, in the last pane.
    @ViewBuilder private var globalControls: some View {
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
            .popover(isPresented: $store.showQuickSettings, arrowEdge: .top) {
                QuickSettingsView(prefs: store.prefs, store: store)
                    // AppKit can close a popover on its own (when the window stops being active, say)
                    // without telling SwiftUI, and the button would then need two clicks to show it again.
                    .onDisappear { store.showQuickSettings = false }
            }
            .help(store.t("Tipografía y apariencia"))
            .accessibilityLabel(store.t("Preferencias"))
    }

    /// Next to tabs the modes shrink to icons (the current one keeps its name while there is room).
    @ViewBuilder private var modeSwitcher: some View {
        if showTabRow {
            modeButtons(labels: false, currentLabel: barWidth >= 980)
        } else {
            ViewThatFits(in: .horizontal) {
                modeButtons(labels: true)
                modeButtons(labels: false)
            }
        }
    }

    private func modeButtons(labels: Bool, currentLabel: Bool = true) -> some View {
        HStack(spacing: 2) {
            modeButton(.read, symbol: "book", label: store.t("Lectura"), keys: "⌘1", showLabel: labels, currentLabel: currentLabel)
            modeButton(.edit, symbol: "pencil.line", label: store.t("Editor"), keys: "⌘2", showLabel: labels, currentLabel: currentLabel)
            modeButton(.source, symbol: "chevron.left.forwardslash.chevron.right", label: store.t("Código"), keys: "⌘3", showLabel: labels, currentLabel: currentLabel)
            modeButton(.split, symbol: "rectangle.split.2x1", label: store.t("Dividida"), keys: "⌘4", showLabel: labels, currentLabel: currentLabel)
        }
        .padding(3)
        .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 11))
    }

    private func modeButton(_ mode: DocumentMode, symbol: String, label: String, keys: String, showLabel: Bool, currentLabel: Bool) -> some View {
        let selected = store.mode == mode
        return Button { store.setMode(mode) } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 11.5, weight: .medium))
                if showLabel || (selected && currentLabel) { Text(label).font(.system(size: 12, weight: .medium)).lineLimit(1).fixedSize() }
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
            ProgressLabel(tracker: store.progressTracker)
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


/// The only control left in focus mode: faint until the pointer comes near.
private struct FocusExitButton: View {
    @ObservedObject var store: ReaderStore
    @State private var hovering = false
    var body: some View {
        Button { withAnimation(.snappy(duration: 0.28)) { store.focusMode = false } } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.right.and.arrow.up.left").font(.system(size: 11, weight: .semibold))
                if hovering { Text(store.t("Salir del enfoque")).font(.system(size: 11.5, weight: .medium)) }
            }
            .padding(.horizontal, 10).frame(height: 28)
            .background(.regularMaterial, in: Capsule())
            .overlay { Capsule().stroke(Color.primary.opacity(0.08)) }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .opacity(hovering ? 1 : 0.35)
        .onHover { inside in withAnimation(.easeOut(duration: 0.15)) { hovering = inside } }
        .help(store.t("Salir del enfoque") + " · ⇧⌘F · esc")
        .accessibilityLabel(store.t("Salir del enfoque"))
        .padding(.top, 10).padding(.trailing, 14)
    }
}


/// An AppKit label: the percentage changes while scrolling, and a SwiftUI text would redraw the whole window.
private struct ProgressLabel: NSViewRepresentable {
    let tracker: ProgressTracker

    final class Coordinator { var subscription: AnyCancellable? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.font = .monospacedDigitSystemFont(ofSize: 9.5, weight: .regular)
        field.textColor = .tertiaryLabelColor
        field.setContentHuggingPriority(.required, for: .horizontal)
        bind(field, context: context)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) { bind(field, context: context) }

    private func bind(_ field: NSTextField, context: Context) {
        context.coordinator.subscription = tracker.$percent.sink { [weak field] percent in field?.stringValue = "\(percent)%" }
    }
}


/// A fresh tab: drop a file here, or open, create or paste one.
private struct EmptyTabView: View {
    @ObservedObject var store: ReaderStore
    @ObservedObject var bench: Workbench
    @ObservedObject private var prefs = AppPreferences.shared

    var body: some View {

        ScrollView {
            VStack(spacing: 22) {
                VStack(spacing: 10) {
                    Image(systemName: "arrow.down.doc").font(.system(size: 34, weight: .light)).foregroundStyle(store.accentColor)
                    Text(store.t("Suelta un Markdown aquí")).font(.system(size: 18, weight: .semibold))
                    Text(store.t("o elige qué abrir en esta pestaña.")).font(.system(size: 13)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 34)
                .background {
                    RoundedRectangle(cornerRadius: 18).strokeBorder(store.accentColor.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [7, 6]))
                }
                HStack(spacing: 10) {
                    action(store.t("Abrir documento"), "plus", "⌘O") { store.openPanel() }
                    action(store.t("Nueva nota"), "square.and.pencil", "⌘N") { store.newNote() }
                    action(store.t("Pegar"), "doc.on.clipboard", "⇧⌘V") { store.readClipboard() }
                }
                if bench.workspace == nil {
                    Button { bench.openWorkspacePanel() } label: {
                        Label(store.t("Abrir carpeta de trabajo"), systemImage: "folder.badge.plus").font(.system(size: 12.5))
                    }
                    .buttonStyle(.link)
                }
                let recent = Array(prefs.recent.prefix(6))
                if !recent.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(store.t("RECIENTES")).font(.system(size: 10.5, weight: .semibold)).tracking(1.2).foregroundStyle(.tertiary)
                            .padding(.horizontal, 10).padding(.bottom, 4)
                        ForEach(recent, id: \.self) { url in
                            Button { DocumentRouter.shared.open(url, from: store) } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "doc.text").foregroundStyle(.secondary)
                                    Text(url.deletingPathExtension().lastPathComponent).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                    Text(url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                        .font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 10).padding(.vertical, 8).contentShape(Rectangle())
                            }
                            .buttonStyle(RecentRowStyle())
                            .help(url.path)
                        }
                    }
                }
            }
            .frame(maxWidth: 560)
            .padding(40)
            .frame(maxWidth: .infinity)
        }
    }

    private func action(_ title: String, _ symbol: String, _ keys: String, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            VStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 17))
                Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(keys).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 14)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct RecentRowStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(configuration.isPressed ? 0.08 : (hovering ? 0.045 : 0))))
            .onHover { hovering = $0 }
    }
}
