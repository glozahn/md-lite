import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension UTType {
    /// A tab being dragged inside MD Lite (payload: the tab's UUID).
    static let mdliteTab = UTType(exportedAs: "org.mdlite.tab")
}

enum DropZone: Equatable { case left, center, right }

/// Drop highlight for a pane. SwiftUI does not always report the end of a drag session,
/// so the highlight also clears itself shortly after the last update.
@MainActor
final class DropTracker: ObservableObject {
    @Published private(set) var zone: DropZone?
    private var lastUpdate = Date.distantPast

    func show(_ zone: DropZone) {
        lastUpdate = Date()
        if self.zone != zone { self.zone = zone }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, Date().timeIntervalSince(self.lastUpdate) >= 0.55 else { return }
            self.zone = nil
        }
    }

    func clear() { zone = nil }
}

extension ReaderStore {
    /// Drag payload for a tab: the tab itself, plus its file for Finder and other apps.
    func dragProvider() -> NSItemProvider {
        let provider = fileURL.map { NSItemProvider(object: $0 as NSURL) } ?? NSItemProvider()
        let id = self.id.uuidString
        provider.registerDataRepresentation(forTypeIdentifier: UTType.mdliteTab.identifier, visibility: .ownProcess) { completion in
            completion(Data(id.utf8), nil)
            return nil
        }
        provider.suggestedName = title
        return provider
    }
}

extension Workbench {
    func store(with id: UUID) -> ReaderStore? {
        DocumentRouter.shared.all.first { $0.id == id }
    }

    /// A tab dropped on a pane: in the middle it joins that pane, on an edge it opens beside.
    func dropTab(_ id: UUID, zone: DropZone, on pane: Pane, before anchor: ReaderStore? = nil) {
        guard let dragged = store(with: id) else { return }
        if dragged.workbench !== self {
            guard let origin = dragged.workbench else { return }
            origin.release(dragged)
            dragged.workbench = self
            pane.tabs.append(dragged)
            focus(dragged)
            return
        }
        switch zone {
        case .left, .right:
            place(store: dragged, side: zone == .left ? .left : .right)
        case .center:
            let index = anchor.flatMap { a in pane.tabs.firstIndex { $0 === a } }
            move(dragged, to: pane, at: index)
        }
    }

    /// A file or folder dropped on a pane.
    func dropFile(_ url: URL, zone: DropZone, on pane: Pane) {
        var isFolder: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue {
            setWorkspace(url)
            return
        }
        if let existing = allStores.first(where: { $0.fileURL?.standardizedFileURL == url.standardizedFileURL }) {
            dropTab(existing.id, zone: zone, on: pane)
            return
        }
        switch zone {
        case .left: place(url: url, side: .left)
        case .right: place(url: url, side: .right)
        case .center: open(url, in: pane, newTab: !pane.selected.canReuseForNewDocument)
        }
    }

    func handleDrop(_ providers: [NSItemProvider], zone: DropZone, on pane: Pane, before anchor: ReaderStore? = nil) -> Bool {
        if let tab = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.mdliteTab.identifier) }) {
            tab.loadDataRepresentation(forTypeIdentifier: UTType.mdliteTab.identifier) { data, _ in
                guard let data, let id = UUID(uuidString: String(decoding: data, as: UTF8.self)) else { return }
                Task { @MainActor in self.dropTab(id, zone: zone, on: pane, before: anchor) }
            }
            return true
        }
        let files = providers.filter { $0.canLoadObject(ofClass: URL.self) }
        guard !files.isEmpty else { return false }
        for provider in files {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.isFileURL else { return }
                Task { @MainActor in self.dropFile(url, zone: zone, on: pane) }
            }
        }
        return true
    }
}

/// Shows where a dragged file or tab will land: left, here as a tab, or right.
struct PaneDropDelegate: DropDelegate {
    let pane: Pane
    let bench: Workbench
    let tracker: DropTracker
    let width: CGFloat
    let allowSides: Bool

    private func zone(at x: CGFloat) -> DropZone {
        guard allowSides, width > 0 else { return .center }
        let ratio = x / width
        return ratio < 0.3 ? .left : ratio > 0.7 ? .right : .center
    }

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.mdliteTab, .fileURL]) }
    func dropEntered(info: DropInfo) { MainActor.assumeIsolated { tracker.show(zone(at: info.location.x)) } }
    func dropExited(info: DropInfo) { MainActor.assumeIsolated { tracker.clear() } }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        MainActor.assumeIsolated { tracker.show(zone(at: info.location.x)) }
        return DropProposal(operation: info.hasItemsConforming(to: [.mdliteTab]) ? .move : .copy)
    }
    func performDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated {
            let target = tracker.zone ?? zone(at: info.location.x)
            tracker.clear()
            return bench.handleDrop(info.itemProviders(for: [.mdliteTab, .fileURL]), zone: target, on: pane)
        }
    }
}

/// Dropping on a tab inserts before it.
private struct TabDropDelegate: DropDelegate {
    let anchor: ReaderStore
    let pane: Pane
    let bench: Workbench
    @Binding var targeted: Bool

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.mdliteTab, .fileURL]) }
    func dropEntered(info: DropInfo) { targeted = true }
    func dropExited(info: DropInfo) { targeted = false }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool {
        targeted = false
        return MainActor.assumeIsolated {
            bench.handleDrop(info.itemProviders(for: [.mdliteTab, .fileURL]), zone: .center, on: pane, before: anchor)
        }
    }
}

/// Tabs of one pane, sharing the window's single top bar with the document controls.
struct TabStrip: View {
    @ObservedObject var pane: Pane
    @ObservedObject var bench: Workbench
    let isFocused: Bool
    @State private var stripTargeted = false
    private let spacing: CGFloat = 4

    var body: some View {

        GeometryReader { geometry in
            // Tabs share the room evenly, like Safari's compact tabs, and scroll once they hit their minimum width.
            let extras: CGFloat = 30 + (bench.panes.count == 2 ? 32 : 0)
            let available = max(0, geometry.size.width - extras)
            let count = CGFloat(max(1, pane.tabs.count))
            let width = min(180, max(112, (available - (count - 1) * spacing) / count))
            let content = count * width + (count - 1) * spacing
            HStack(spacing: 4) {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: spacing) {
                            ForEach(pane.tabs, id: \.id) { tab in
                                TabChip(store: tab, pane: pane, bench: bench, selected: tab.id == pane.selectedID,
                                        paneFocused: isFocused, width: width)
                                    .id(tab.id)
                            }
                        }
                    }
                    .frame(width: min(available, content))
                    .onChange(of: pane.selectedID) { _, id in withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id) } }
                }
                Button { bench.newTab(in: pane) } label: {
                    Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).frame(width: 26, height: 26).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help(bench.focusedStore.t("Nueva pestaña") + " · ⌘T")
                .accessibilityLabel(bench.focusedStore.t("Nueva pestaña"))
                Spacer(minLength: 0)
                if bench.panes.count == 2 {
                    Button { bench.closePane(pane) } label: {
                        Image(systemName: "xmark.rectangle").font(.system(size: 12)).frame(width: 28, height: 26).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help(bench.focusedStore.t("Cerrar panel: sus pestañas pasan al otro") + " · ⌥⌘W")
                    .accessibilityLabel(bench.focusedStore.t("Cerrar panel"))
                }
            }
            .frame(height: geometry.size.height)
        }
        .frame(height: 30)
        .frame(minWidth: 150)
        .background(stripTargeted ? bench.focusedStore.accentColor.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 9))
        .onDrop(of: [.mdliteTab, .fileURL], isTargeted: $stripTargeted) { providers in
            bench.handleDrop(providers, zone: .center, on: pane)
        }
    }
}

private struct TabChip: View {
    @ObservedObject var store: ReaderStore
    @ObservedObject var pane: Pane
    @ObservedObject var bench: Workbench
    let selected: Bool
    let paneFocused: Bool
    let width: CGFloat
    @State private var hovering = false
    @State private var targeted = false
    @State private var showPath = false
    @Environment(\.colorScheme) private var colorScheme

    private var fill: Color {
        if selected {
            if colorScheme == .dark { return .white.opacity(paneFocused ? 0.13 : 0.08) }
            return .white.opacity(paneFocused ? 1 : 0.7)
        }
        return .primary.opacity(hovering ? 0.075 : 0.04)
    }

    var body: some View {

        ZStack {
            HStack(spacing: 5) {
                Image(systemName: store.isNewNote ? "square.and.pencil" : (store.isWelcome ? "sparkle" : "doc.text"))
                    .font(.system(size: 10.5)).foregroundStyle(selected ? store.accentColor : Color.secondary)
                Text(store.title).font(.system(size: 12, weight: selected ? .medium : .regular))
                    .lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
            }
            .padding(.horizontal, 24)
            HStack(spacing: 0) {
                // Close on the left, shown on hover, as in Safari; the unsaved dot balances it on the right.
                if hovering {
                    Button { bench.close(store) } label: {
                        Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold)).frame(width: 16, height: 16)
                            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help(store.t("Cerrar") + " · ⌘W")
                    .accessibilityLabel(store.t("Cerrar"))
                }
                Spacer(minLength: 0)
                if store.isDirty { Circle().fill(store.accentColor).frame(width: 6, height: 6).padding(.trailing, 4) }
            }
            .padding(.horizontal, 6)
        }
        .frame(width: width, height: 28)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(fill)
                .shadow(color: selected && paneFocused ? .black.opacity(0.09) : .clear, radius: 1.2, y: 0.5)
        }
        .overlay {
            if selected { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.05)) }
        }
        .overlay(alignment: .leading) {
            if targeted { Capsule().fill(store.accentColor).frame(width: 2.5).padding(.vertical, 4).offset(x: -3.5) }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onTapGesture {
            // A click on the tab that is already in front shows where the file lives.
            if selected && paneFocused { showPath.toggle() } else { bench.focus(store) }
        }
        .popover(isPresented: $showPath, arrowEdge: .bottom) { PathPopover(store: store).onDisappear { showPath = false } }
        .onDrag { store.dragProvider() }
        .onDrop(of: [.mdliteTab, .fileURL], delegate: TabDropDelegate(anchor: store, pane: pane, bench: bench, targeted: $targeted))
        .help(store.fileURL?.path ?? store.title)
        .contextMenu {
            Button(store.t("Guardar")) { store.save() }
            Button(store.t("Guardar como…")) { store.saveAs() }
            Button(store.t("Duplicar")) { store.duplicateDocument() }
            Menu(store.t("Exportar")) {
                Button(store.t("HTML…")) { store.exportHTML() }
                Button(store.t("PDF…")) { store.exportPDF() }
            }
            Button(store.t("Imprimir…")) { store.printDocument() }
            Divider()
            Button(store.t("Mover al panel izquierdo")) { bench.place(store: store, side: .left) }
                .disabled(bench.panes.count == 1 && pane.tabs.count == 1 || bench.panes.first === pane && bench.panes.count == 2)
            Button(store.t("Mover al panel derecho")) { bench.place(store: store, side: .right) }
                .disabled(bench.panes.count == 1 && pane.tabs.count == 1 || bench.panes.last === pane && bench.panes.count == 2)
            if let url = store.fileURL {
                Divider()
                FileExtras(url: url, store: store)
            }
            Divider()
            Button(store.t("Cerrar")) { bench.close(store) }
            Button(store.t("Cerrar las demás")) {
                for other in pane.tabs where other !== store { bench.close(other) }
            }.disabled(pane.tabs.count < 2)
        }
    }
}


/// Full location of the file, as a breadcrumb, with quick actions.
struct PathPopover: View {
    @ObservedObject var store: ReaderStore

    var body: some View {

        VStack(alignment: .leading, spacing: 12) {
            if let url = store.fileURL {
                let parts = url.pathComponents.filter { $0 != "/" }
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                        HStack(spacing: 6) {
                            Image(systemName: index == parts.count - 1 ? "doc.text" : "folder")
                                .font(.system(size: 11)).foregroundStyle(index == parts.count - 1 ? store.accentColor : Color.secondary)
                                .frame(width: 14)
                            Text(part).font(.system(size: 12, weight: index == parts.count - 1 ? .semibold : .regular)).lineLimit(1)
                        }
                        .padding(.leading, CGFloat(min(index, 8)) * 10)
                    }
                }
                Text(url.path).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(store.t("Mostrar en Finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    Button(store.t("Copiar ruta")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.path, forType: .string)
                    }
                }
                .controlSize(.small)
            } else {
                Text(store.t("Este documento aún no está guardado.")).font(.system(size: 12))
                Button(store.t("Guardar…")) { store.saveAs() }.controlSize(.small)
            }
        }
        .padding(16)
        .frame(width: 340, alignment: .leading)
    }
}
