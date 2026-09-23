import SwiftUI
import AppKit

/// Sidebar palette: cool gray panel, white cards, accent pill for the current item.
struct SidebarPalette {
    let scheme: ColorScheme
    private func pick(_ light: Color, _ dark: Color) -> Color { scheme == .dark ? dark : light }
    private static func rgb(_ value: UInt32, _ alpha: Double = 1) -> Color {
        Color(.sRGB, red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255, opacity: alpha)
    }
    var top: Color { pick(Self.rgb(0xF4F5F9), Self.rgb(0x1D1F25)) }
    var bottom: Color { pick(Self.rgb(0xECEEF4), Self.rgb(0x191B20)) }
    var card: Color { pick(Color.white.opacity(0.74), Color.white.opacity(0.05)) }
    var cardBorder: Color { pick(Self.rgb(0x141E3C, 0.07), Color.white.opacity(0.07)) }
    var text: Color { pick(Self.rgb(0x3A3F47), Self.rgb(0xD4D7DD)) }
    var strong: Color { pick(Self.rgb(0x1F2328), Self.rgb(0xECEEF1)) }
    var label: Color { pick(Self.rgb(0x8A8F99), Self.rgb(0x7D838D)) }
    var faint: Color { pick(Self.rgb(0xA3A8B0), Self.rgb(0x5F656E)) }
    var hover: Color { pick(Self.rgb(0x141E3C, 0.05), Color.white.opacity(0.05)) }
    var rail: Color { pick(Self.rgb(0x141E3C, 0.1), Color.white.opacity(0.1)) }
    var live: Color { Self.rgb(0x34C759) }
    var shadow: Color { pick(Self.rgb(0x141E3C, 0.06), .clear) }
    func active(_ accent: Color) -> Color { accent.opacity(scheme == .dark ? 0.22 : 0.13) }
}

private struct SidebarCard: ViewModifier {
    let palette: SidebarPalette
    var radius: CGFloat = 10
    func body(content: Content) -> some View {
        content
            .background(palette.card, in: RoundedRectangle(cornerRadius: radius))
            .overlay { RoundedRectangle(cornerRadius: radius).stroke(palette.cardBorder, lineWidth: 1) }
            .shadow(color: palette.shadow, radius: 1, y: 1)
    }
}

extension View {
    fileprivate func sidebarCard(_ palette: SidebarPalette, radius: CGFloat = 10) -> some View {
        modifier(SidebarCard(palette: palette, radius: radius))
    }
}

struct Sidebar: View {
    @ObservedObject var store: ReaderStore
    @ObservedObject var bench: Workbench
    @ObservedObject var prefs = AppPreferences.shared
    @Environment(\.openSettings) private var openSettings
    @State private var hoveringRecent = false
    @Environment(\.colorScheme) private var colorScheme

    private var palette: SidebarPalette { SidebarPalette(scheme: colorScheme) }

    var body: some View {

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().interpolation(.high).frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text("MD Lite").font(.system(size: 16, weight: .semibold)).foregroundStyle(palette.strong)
                    Text(store.t("Un pequeño espacio para leer")).font(.system(size: 11.5)).foregroundStyle(palette.label)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .sidebarCard(palette, radius: 14)
            .padding(.top, 40).padding(.horizontal, 12).padding(.bottom, 10)

            Button(action: store.openPanel) {
                HStack(spacing: 9) {
                    Image(systemName: "plus").font(.system(size: 12, weight: .medium))
                    Text(store.t("Abrir documento")).font(.system(size: 12.5, weight: .medium))
                    Spacer()
                    Text("⌘O").font(.system(size: 10.5)).foregroundStyle(palette.faint)
                }
                .foregroundStyle(palette.strong)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .sidebarCard(palette).contentShape(Rectangle())
            }.buttonStyle(.plain).padding(.horizontal, 12)

            HStack(spacing: 8) {
                smallAction(store.t("Nueva nota"), symbol: "square.and.pencil", keys: "⌘N", action: store.newNote)
                smallAction(store.t("Pegar"), symbol: "doc.on.clipboard", keys: "⇧⌘V", action: store.presentPasteEditor)
            }.padding(.horizontal, 12).padding(.top, 8)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        WorkspaceSection(store: store, bench: bench, palette: palette)
                        FavoritesSection(store: store, bench: bench, palette: palette)
                        OutlineNavigator(store: store, palette: palette, proxy: proxy).padding(.top, 8)
                        recentSection
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                }
            }
            if prefs.defaultApp.isDefault == false { defaultAppCard }
            footer
        }
        .foregroundStyle(palette.text)
    }

    @ViewBuilder private var recentSection: some View {
        let recent = Array(prefs.recent.prefix(5))
        if !recent.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "clock").font(.system(size: 10.5))
                Text(store.t("RECIENTES")).font(.system(size: 10.5, weight: .semibold)).tracking(1.2)
                Spacer()
                // Quiet until you point at the list, like the other section controls.
                Button { withAnimation(.snappy(duration: 0.2)) { prefs.clearRecent() } } label: {
                    Image(systemName: "trash").font(.system(size: 10.5)).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(hoveringRecent ? 1 : 0.45)
                .help(store.t("Vaciar la lista de recientes"))
                .accessibilityLabel(store.t("Vaciar la lista de recientes"))
            }
            .foregroundStyle(palette.label).padding(.horizontal, 8).padding(.top, 18).padding(.bottom, 4)
            .onHover { inside in withAnimation(.easeOut(duration: 0.15)) { hoveringRecent = inside } }
            ForEach(recent, id: \.self) { url in
                let duplicate = recent.filter { $0.lastPathComponent == url.lastPathComponent }.count > 1
                Button { DocumentRouter.shared.open(url, from: store) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.text").font(.system(size: 12)).foregroundStyle(palette.label)
                        Text(url.lastPathComponent).lineLimit(1)
                        if duplicate {
                            Text(url.deletingLastPathComponent().lastPathComponent).foregroundStyle(palette.faint).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        TagDots(url: url)
                    }
                    .font(.system(size: 12.5))
                    .padding(.horizontal, 8).padding(.vertical, 6).contentShape(Rectangle())
                }
                .buttonStyle(SidebarRowStyle(palette: palette))
                .help(url.path)
                .onDrag { NSItemProvider(object: url as NSURL) }
                .contextMenu {
                    FileMenu(url: url, store: store, bench: bench)
                    Divider()
                    Button(store.t("Quitar de recientes")) { withAnimation(.snappy(duration: 0.2)) { prefs.removeRecent(url) } }
                    Button(store.t("Vaciar la lista de recientes")) { withAnimation(.snappy(duration: 0.2)) { prefs.clearRecent() } }
                }
            }
        }
    }

    private var defaultAppCard: some View {
        Button { store.showDefaultAppGuide = true } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Image(systemName: "doc.badge.arrow.up").foregroundStyle(store.accentColor)
                    Text(store.t("Abre tus .md con MD Lite")).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(palette.strong)
                }
                Text(store.t("Doble clic en Finder y se abren aquí.")).font(.system(size: 10.5)).foregroundStyle(palette.label)
                Text(store.t("Ver cómo →")).font(.system(size: 10.5, weight: .medium)).foregroundStyle(store.accentColor)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12).sidebarCard(palette, radius: 12).contentShape(Rectangle())
        }
        .buttonStyle(.plain).padding(.horizontal, 12).padding(.bottom, 10)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Circle().fill(palette.live).frame(width: 7, height: 7)
                .overlay { Circle().stroke(palette.live.opacity(0.2), lineWidth: 3) }
            Text(store.t("Lectura local")).font(.system(size: 12))
            Spacer()
            Button { AppWindows.showSettings(openSettings) } label: {
                HStack(spacing: 5) {
                    Image(systemName: "gearshape").font(.system(size: 12))
                    Text(store.t("Ajustes")).font(.system(size: 12))
                }
                .foregroundStyle(palette.text)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(store.t("Ajustes") + " · ⌘,")
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .overlay(alignment: .top) { Rectangle().fill(palette.rail).frame(height: 1) }
    }

    private func smallAction(_ title: String, symbol: String, keys: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 12))
                Text(title).font(.system(size: 12.5)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(palette.strong)
            .padding(.horizontal, 11).padding(.vertical, 9)
            .sidebarCard(palette).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help("\(title) · \(keys)")
    }
}

struct SidebarRowStyle: ButtonStyle {
    let palette: SidebarPalette
    var selected = false
    var accent: Color = .accentColor
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(selected ? accent : palette.text)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? palette.active(accent) : (hovering || configuration.isPressed ? palette.hover : .clear)))
            .onHover { hovering = $0 }
    }
}

/// Colored dots for a file's Finder tags.
struct TagDots: View {
    let url: URL
    @ObservedObject private var prefs = AppPreferences.shared
    var body: some View {
        let colors = prefs.tags(of: url).compactMap { prefs.color(forTag: $0) }
        if !colors.isEmpty {
            HStack(spacing: -3) {
                ForEach(Array(colors.prefix(3).enumerated()), id: \.offset) { _, color in
                    Circle().fill(Color(nsColor: color)).frame(width: 8, height: 8)
                        .overlay { Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1) }
                }
            }
        }
    }
}

/// Right-click menu shared by the working folder, favorites, and recent files.
struct FileMenu: View {
    let url: URL
    let store: ReaderStore
    let bench: Workbench
    @ObservedObject private var prefs = AppPreferences.shared

    private var openStore: ReaderStore? {
        DocumentRouter.shared.all.first { $0.fileURL?.standardizedFileURL == url.standardizedFileURL }
    }

    var body: some View {

        Button(store.t("Abrir")) { DocumentRouter.shared.open(url, from: store) }
        Button(store.t("Abrir en una pestaña nueva")) { DocumentRouter.shared.open(url, from: store, newTab: true) }
        Button(store.t("Abrir a la derecha")) { bench.place(url: url, side: .right) }
        Divider()
        Button(store.t("Guardar una copia como…")) {
            if let copy = DocumentActions.saveCopy(of: url, prefs: prefs) { DocumentRouter.shared.open(copy, from: store, newTab: true) }
        }
        Button(store.t("Duplicar")) {
            if let open = openStore { open.duplicateDocument(); return }
            if let copy = DocumentActions.duplicate(url, prefs: prefs) {
                bench.refreshWorkspace()
                DocumentRouter.shared.open(copy, from: store, newTab: true)
            }
        }
        Menu(store.t("Exportar")) {
            Button(store.t("HTML…")) { export(html: true) }
            Button(store.t("PDF…")) { export(html: false) }
        }
        Divider()
        FileExtras(url: url, store: store)
    }

    private func export(html: Bool) {
        if let open = openStore { html ? open.exportHTML() : open.exportPDF(); return }
        guard let text = DocumentActions.source(of: url) else { return }
        let title = url.deletingPathExtension().lastPathComponent
        let folder = url.deletingLastPathComponent()
        if html { DocumentActions.exportHTML(source: text, title: title, suggestedFolder: folder, prefs: prefs) }
        else { DocumentActions.exportPDF(source: text, title: title, baseURL: folder, suggestedFolder: folder, prefs: prefs) }
    }
}

/// Favorite, Finder tags, reveal and copy path for a file.
struct FileExtras: View {
    let url: URL
    let store: ReaderStore
    @ObservedObject private var prefs = AppPreferences.shared

    var body: some View {

        Button(prefs.isFavorite(url) ? store.t("Quitar de favoritos") : store.t("Añadir a favoritos")) { prefs.toggleFavorite(url) }
        Menu(store.t("Etiquetas")) {
            let current = prefs.tags(of: url)
            ForEach(prefs.colorTags, id: \.name) { tag in
                Button { prefs.toggleTag(tag.name, on: url) } label: {
                    Label {
                        Text(tag.name)
                    } icon: {
                        Image(nsImage: FileMenu.swatch(tag.color, checked: current.contains(tag.name)))
                    }
                }
            }
            let custom = current.filter { name in !prefs.colorTags.contains { $0.name == name } }
            if !custom.isEmpty {
                Divider()
                ForEach(custom, id: \.self) { name in
                    Button("✓ " + name) { prefs.toggleTag(name, on: url) }
                }
            }
            Divider()
            Button(store.t("Nueva etiqueta…")) { prefs.addCustomTag(to: url) }
            if !current.isEmpty { Button(store.t("Quitar todas las etiquetas")) { prefs.setTags([], on: url) } }
        }
        Divider()
        Button(store.t("Mostrar en Finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        Button(store.t("Copiar ruta")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.path, forType: .string)
        }
    }
}

extension FileMenu {
    /// Menu items only show images, so tag colors are drawn as small swatches.
    static func swatch(_ color: NSColor, checked: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5)).fill()
            if checked {
                NSColor.white.setStroke()
                let path = NSBezierPath()
                path.lineWidth = 1.6
                path.move(to: NSPoint(x: 4.3, y: 7.2))
                path.line(to: NSPoint(x: 6.3, y: 5))
                path.line(to: NSPoint(x: 9.8, y: 9.2))
                path.stroke()
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}

struct FavoritesSection: View {
    @ObservedObject var store: ReaderStore
    @ObservedObject var bench: Workbench
    let palette: SidebarPalette
    @ObservedObject private var prefs = AppPreferences.shared

    var body: some View {

        if !prefs.favorites.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "star").font(.system(size: 10.5))
                Text(store.t("FAVORITOS")).font(.system(size: 10.5, weight: .semibold)).tracking(1.2)
            }
            .foregroundStyle(palette.label).padding(.horizontal, 8).padding(.top, 10).padding(.bottom, 4)
            ForEach(prefs.favorites, id: \.self) { url in
                let selected = store.fileURL?.standardizedFileURL == url.standardizedFileURL
                Button { DocumentRouter.shared.open(url, from: store) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "star.fill").font(.system(size: 10.5)).foregroundStyle(Color.yellow.opacity(0.9))
                        Text(url.deletingPathExtension().lastPathComponent).lineLimit(1)
                        Spacer(minLength: 0)
                        TagDots(url: url)
                    }
                    .font(.system(size: 12.5, weight: selected ? .medium : .regular))
                    .padding(.horizontal, 8).padding(.vertical, 6).contentShape(Rectangle())
                }
                .buttonStyle(SidebarRowStyle(palette: palette, selected: selected, accent: store.accentColor))
                .help(url.path)
                .onDrag { NSItemProvider(object: url as NSURL) }
                .contextMenu { FileMenu(url: url, store: store, bench: bench) }
            }
        }
    }
}

/// Working folder: every Markdown file under it, as a collapsible tree.
struct WorkspaceSection: View {
    @ObservedObject var store: ReaderStore
    @ObservedObject var bench: Workbench
    let palette: SidebarPalette

    var body: some View {

        if let folder = bench.workspace {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Image(systemName: "folder").font(.system(size: 10.5))
                    Text(folder.lastPathComponent.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(1.1).lineLimit(1)
                    Spacer()
                    Button { bench.refreshWorkspace() } label: { Image(systemName: "arrow.clockwise").font(.system(size: 10)) }
                        .buttonStyle(.plain).help(store.t("Actualizar carpeta"))
                    Button { bench.setWorkspace(nil) } label: { Image(systemName: "xmark").font(.system(size: 10)) }
                        .buttonStyle(.plain).help(store.t("Cerrar carpeta"))
                }
                .foregroundStyle(palette.label).padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 4)
                .help(folder.path)
                .contextMenu {
                    Button(store.t("Mostrar en Finder")) { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                    Button(store.t("Actualizar carpeta")) { bench.refreshWorkspace() }
                    Button(store.t("Cerrar carpeta")) { bench.setWorkspace(nil) }
                }
                if bench.workspaceTree.isEmpty {
                    if bench.isScanningWorkspace {
                        ProgressView().controlSize(.small).padding(8)
                    } else {
                        Text(store.t("Sin archivos Markdown")).font(.system(size: 11.5)).foregroundStyle(palette.faint).padding(8)
                    }
                }
                ForEach(bench.workspaceTree) { node in WorkspaceNodeRow(store: store, bench: bench, node: node, depth: 0, palette: palette) }
            }
            .padding(.bottom, 6)
        } else {
            Button { bench.openWorkspacePanel() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "folder.badge.plus").font(.system(size: 12))
                    Text(store.t("Abrir carpeta de trabajo")).font(.system(size: 12))
                    Spacer()
                    Text("⇧⌘O").font(.system(size: 10)).foregroundStyle(palette.faint)
                }
                .padding(.horizontal, 8).padding(.vertical, 6).contentShape(Rectangle())
            }
            .buttonStyle(SidebarRowStyle(palette: palette))
        }
    }
}

private struct WorkspaceNodeRow: View {
    @ObservedObject var store: ReaderStore
    @ObservedObject var bench: Workbench
    let node: FileNode
    let depth: Int
    let palette: SidebarPalette
    @State private var expanded: Bool

    init(store: ReaderStore, bench: Workbench, node: FileNode, depth: Int, palette: SidebarPalette) {
        self.store = store
        self.bench = bench
        self.node = node
        self.depth = depth
        self.palette = palette
        let current = store.fileURL?.standardizedFileURL.path ?? ""
        _expanded = State(initialValue: depth == 0 || current.hasPrefix(node.url.standardizedFileURL.path + "/"))
    }

    var body: some View {

        if node.isDirectory {
            Button { withAnimation(.snappy(duration: 0.18)) { expanded.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(expanded ? 90 : 0)).foregroundStyle(palette.faint).frame(width: 10)
                    Image(systemName: expanded ? "folder" : "folder.fill").font(.system(size: 11)).foregroundStyle(palette.label)
                    Text(node.name).lineLimit(1)
                    Spacer(minLength: 0)
                    TagDots(url: node.url)
                }
                .font(.system(size: 12.5))
                .padding(.leading, CGFloat(depth) * 14 + 6).padding(.trailing, 6).padding(.vertical, 5).contentShape(Rectangle())
            }
            .buttonStyle(SidebarRowStyle(palette: palette))
            .contextMenu {
                Button(store.t("Mostrar en Finder")) { NSWorkspace.shared.activateFileViewerSelecting([node.url]) }
                Button(store.t("Usar como carpeta de trabajo")) { bench.setWorkspace(node.url) }
                Button(store.t("Copiar ruta")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(node.url.path, forType: .string)
                }
            }
            if expanded, let children = node.children {
                ForEach(children) { child in WorkspaceNodeRow(store: store, bench: bench, node: child, depth: depth + 1, palette: palette) }
            }
        } else {
            let selected = store.fileURL?.standardizedFileURL == node.url.standardizedFileURL
            Button {
                if NSEvent.modifierFlags.contains(.command) { DocumentRouter.shared.open(node.url, from: store, newTab: true) }
                else { DocumentRouter.shared.open(node.url, from: store) }
            } label: {
                HStack(spacing: 6) {
                    Spacer().frame(width: 10)
                    Image(systemName: "doc.text").font(.system(size: 11)).foregroundStyle(selected ? store.accentColor : palette.label)
                    Text(node.url.deletingPathExtension().lastPathComponent).lineLimit(1)
                    Spacer(minLength: 0)
                    if AppPreferences.shared.isFavorite(node.url) {
                        Image(systemName: "star.fill").font(.system(size: 8.5)).foregroundStyle(Color.yellow.opacity(0.9))
                    }
                    TagDots(url: node.url)
                }
                .font(.system(size: 12.5, weight: selected ? .medium : .regular))
                .padding(.leading, CGFloat(depth) * 14 + 6).padding(.trailing, 6).padding(.vertical, 5).contentShape(Rectangle())
            }
            .buttonStyle(SidebarRowStyle(palette: palette, selected: selected, accent: store.accentColor))
            .help(node.url.path + "\n" + store.t("⌘-clic para abrir en una pestaña nueva"))
            .onDrag { NSItemProvider(object: node.url as NSURL) }
            .contextMenu { FileMenu(url: node.url, store: store, bench: bench) }
        }
    }
}

/// "On this page" navigator: collapsible heading tree with a reading rail and scroll tracking.
struct OutlineNavigator: View {
    @ObservedObject var store: ReaderStore
    let palette: SidebarPalette
    let proxy: ScrollViewProxy
    var body: some View {
        OutlineList(store: store, tracker: store.tracker, palette: palette, proxy: proxy)
    }
}

private struct OutlineList: View {
    @ObservedObject var store: ReaderStore
    @ObservedObject var tracker: ReadingTracker
    let palette: SidebarPalette
    let proxy: ScrollViewProxy
    @State private var followWork: DispatchWorkItem?
    @State private var collapsed = Set<Int>()
    @State private var filter = ""
    @State private var hovered: Int?
    @State private var showFilter = false

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

    /// Headings that have sub-headings, found in one pass.
    private var parents: Set<Int> {
        var result = Set<Int>()
        for index in items.indices.dropLast() where items[index + 1].level > items[index].level { result.insert(items[index].id) }
        return result
    }

    /// The heading that owns the current position, even when it is folded away.
    private var activeVisible: Int? { active(in: visible) }

    private func active(in visible: [OutlineItem]) -> Int? {
        guard let current = tracker.currentHeading else { return nil }
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

        // Computed once per render; per-row lookups made every scroll tick cost O(n²).
        let visible = self.visible
        let parents = self.parents
        let active = active(in: visible)
        let minLevel = self.minLevel
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(store.t("EN ESTA PÁGINA")).font(.system(size: 10.5, weight: .semibold)).tracking(1.2).foregroundStyle(palette.label)
                Spacer()
                if !parents.isEmpty {
                    Button {
                        withAnimation(.snappy(duration: 0.2)) {
                            let topLevel = items.filter { $0.level == minLevel }.count
                            collapsed = collapsed.isEmpty ? Set(items.filter { parents.contains($0.id) && ($0.level > minLevel || topLevel > 1) }.map(\.id)) : []
                        }
                    } label: {
                        Image(systemName: collapsed.isEmpty ? "rectangle.compress.vertical" : "rectangle.expand.vertical").font(.system(size: 10.5))
                    }
                    .buttonStyle(.plain).foregroundStyle(palette.label)
                    .help(collapsed.isEmpty ? store.t("Contraer todo") : store.t("Expandir todo"))
                    .accessibilityLabel(collapsed.isEmpty ? store.t("Contraer todo") : store.t("Expandir todo"))
                }
                if items.count > 1 {
                    Button { withAnimation(.snappy(duration: 0.18)) { showFilter.toggle(); if !showFilter { filter = "" } } } label: {
                        Image(systemName: "line.3.horizontal.decrease").font(.system(size: 11))
                    }
                    .buttonStyle(.plain).foregroundStyle(showFilter ? store.accentColor : palette.label)
                    .help(store.t("Filtrar títulos")).accessibilityLabel(store.t("Filtrar títulos"))
                }
            }
            .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 6)

            if showFilter || items.count > 14 {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(palette.faint)
                    TextField(store.t("Filtrar títulos"), text: $filter).textFieldStyle(.plain).font(.system(size: 12))
                    if !filter.isEmpty {
                        Button { filter = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 10)) }
                            .buttonStyle(.plain).foregroundStyle(palette.faint)
                    }
                }
                .padding(.horizontal, 9).padding(.vertical, 6).sidebarCard(palette, radius: 8).padding(.bottom, 6)
            }

            if items.isEmpty {
                Text(store.t("Los títulos aparecerán aquí.")).font(.system(size: 12)).foregroundStyle(palette.faint).padding(8)
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(visible) { item in
                        row(item, active: active == item.id, parent: parents.contains(item.id), depth: min(4, item.level - minLevel))
                    }
                }
                .overlay(alignment: .leading) {
                    Rectangle().fill(palette.rail).frame(width: 1).padding(.leading, 20).padding(.vertical, 8)
                }
            }
        }
        .onChange(of: store.contentVersion) { _, _ in collapsed = []; filter = "" }
        .onChange(of: tracker.currentHeading) { _, _ in
            // Follow the reader only once scrolling pauses; scrolling the sidebar mid-gesture stutters.
            followWork?.cancel()
            let work = DispatchWorkItem {
                guard hovered == nil, let id = activeVisible else { return }
                proxy.scrollTo(id)
            }
            followWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        }
    }

    private func row(_ item: OutlineItem, active: Bool, parent: Bool, depth: Int) -> some View {
        HStack(spacing: 4) {
            ZStack {
                if active { Circle().fill(store.accentColor).frame(width: 6, height: 6) }
            }
            .frame(width: 12)
            Spacer().frame(width: CGFloat(depth) * 13)
            if parent && filter.isEmpty {
                Button {
                    withAnimation(.snappy(duration: 0.2)) {
                        if collapsed.contains(item.id) { collapsed.remove(item.id) } else { collapsed.insert(item.id) }
                    }
                } label: {
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(collapsed.contains(item.id) ? 0 : 90))
                        .foregroundStyle(palette.faint).frame(width: 12, height: 16).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Spacer().frame(width: 12)
            }
            Text(item.title)
                // Same weight when active: a bolder title can wrap differently and re-lay out the whole sidebar.
                .font(.system(size: depth == 0 ? 13 : 12.5, weight: depth == 0 ? .medium : .regular))
                .foregroundStyle(active ? store.accentColor : (depth == 0 ? palette.strong : palette.text))
                .lineLimit(2).multilineTextAlignment(.leading)
            Spacer(minLength: 4)
        }
        .padding(.vertical, 6).padding(.trailing, 6)
        .background {
            RoundedRectangle(cornerRadius: 9)
                .fill(active ? palette.active(store.accentColor) : (hovered == item.id ? palette.hover : .clear))
        }
        .contentShape(Rectangle())
        .onTapGesture { store.navigate(item) }
        .onHover { inside in hovered = inside ? item.id : (hovered == item.id ? nil : hovered) }
        // Only long titles need a tooltip; each one is a tracking area AppKit refreshes on every change.
        .help(item.title.count > 32 ? item.title : "")
        .id(item.id)
        // No animation: the highlight moves while you scroll, and each animated frame redraws the whole sidebar.
    }
}
