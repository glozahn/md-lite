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
    @ObservedObject var prefs = AppPreferences.shared
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
                        WorkspaceSection(store: store, palette: palette)
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
            }
            .foregroundStyle(palette.label).padding(.horizontal, 8).padding(.top, 18).padding(.bottom, 4)
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
                    }
                    .font(.system(size: 12.5))
                    .padding(.horizontal, 8).padding(.vertical, 6).contentShape(Rectangle())
                }
                .buttonStyle(SidebarRowStyle(palette: palette))
                .help(url.path)
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
            SettingsLink {
                HStack(spacing: 5) {
                    Image(systemName: "gearshape").font(.system(size: 12))
                    Text(store.t("Ajustes")).font(.system(size: 12))
                }
                .foregroundStyle(palette.text)
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

/// Working folder: every Markdown file under it, as a collapsible tree.
struct WorkspaceSection: View {
    @ObservedObject var store: ReaderStore
    let palette: SidebarPalette

    var body: some View {
        if let folder = store.workspace {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Image(systemName: "folder").font(.system(size: 10.5))
                    Text(folder.lastPathComponent.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(1.1).lineLimit(1)
                    Spacer()
                    if store.isScanningWorkspace { ProgressView().controlSize(.mini) }
                    Button { store.refreshWorkspace() } label: { Image(systemName: "arrow.clockwise").font(.system(size: 10)) }
                        .buttonStyle(.plain).help(store.t("Actualizar carpeta"))
                    Button { store.setWorkspace(nil) } label: { Image(systemName: "xmark").font(.system(size: 10)) }
                        .buttonStyle(.plain).help(store.t("Cerrar carpeta"))
                }
                .foregroundStyle(palette.label).padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 4)
                .help(folder.path)
                if store.workspaceTree.isEmpty && !store.isScanningWorkspace {
                    Text(store.t("Sin archivos Markdown")).font(.system(size: 11.5)).foregroundStyle(palette.faint).padding(8)
                }
                ForEach(store.workspaceTree) { node in WorkspaceNodeRow(store: store, node: node, depth: 0, palette: palette) }
            }
            .padding(.bottom, 6)
        } else {
            Button { store.openWorkspacePanel() } label: {
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
    let node: FileNode
    let depth: Int
    let palette: SidebarPalette
    @State private var expanded: Bool

    init(store: ReaderStore, node: FileNode, depth: Int, palette: SidebarPalette) {
        self.store = store
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
                }
                .font(.system(size: 12.5))
                .padding(.leading, CGFloat(depth) * 14 + 6).padding(.trailing, 6).padding(.vertical, 5).contentShape(Rectangle())
            }
            .buttonStyle(SidebarRowStyle(palette: palette))
            if expanded, let children = node.children {
                ForEach(children) { child in WorkspaceNodeRow(store: store, node: child, depth: depth + 1, palette: palette) }
            }
        } else {
            let selected = store.fileURL?.standardizedFileURL == node.url.standardizedFileURL
            Button {
                let newTab = NSEvent.modifierFlags.contains(.command)
                if newTab { DocumentRouter.shared.open(node.url, from: store, newTab: true) }
                else { store.open(node.url) }
            } label: {
                HStack(spacing: 6) {
                    Spacer().frame(width: 10)
                    Image(systemName: "doc.text").font(.system(size: 11)).foregroundStyle(selected ? store.accentColor : palette.label)
                    Text(node.url.deletingPathExtension().lastPathComponent).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 12.5, weight: selected ? .medium : .regular))
                .padding(.leading, CGFloat(depth) * 14 + 6).padding(.trailing, 6).padding(.vertical, 5).contentShape(Rectangle())
            }
            .buttonStyle(SidebarRowStyle(palette: palette, selected: selected, accent: store.accentColor))
            .help(node.url.path + "\n" + store.t("⌘-clic para abrir en una pestaña nueva"))
        }
    }
}

/// "On this page" navigator: collapsible heading tree with a reading rail and scroll tracking.
struct OutlineNavigator: View {
    @ObservedObject var store: ReaderStore
    let palette: SidebarPalette
    let proxy: ScrollViewProxy
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
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(store.t("EN ESTA PÁGINA")).font(.system(size: 10.5, weight: .semibold)).tracking(1.2).foregroundStyle(palette.label)
                Spacer()
                if items.contains(where: hasChildren) {
                    Button {
                        withAnimation(.snappy(duration: 0.2)) {
                            collapsed = collapsed.isEmpty ? Set(items.filter(hasChildren).filter { $0.level > minLevel || items.filter { $0.level == minLevel }.count > 1 }.map(\.id)) : []
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
                    ForEach(visible) { item in row(item, active: activeVisible == item.id) }
                }
                .overlay(alignment: .leading) {
                    Rectangle().fill(palette.rail).frame(width: 1).padding(.leading, 20).padding(.vertical, 8)
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
        return HStack(spacing: 4) {
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
                .font(.system(size: depth == 0 ? 13 : 12.5, weight: active ? .semibold : (depth == 0 ? .medium : .regular)))
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
        .help(item.title)
        .id(item.id)
        .animation(.easeOut(duration: 0.15), value: active)
    }
}
