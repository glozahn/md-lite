import SwiftUI

/// ⇧⌘\ or the list button at the end of the tab strip: every open tab with its folder and path,
/// in this window and the others. Type to filter, arrows and Return to go, hover to close.
struct AllTabsView: View {
    @ObservedObject var store: ReaderStore
    @ObservedObject var bench: Workbench
    @State private var query = ""
    @State private var selection = 0
    @State private var hovered: UUID?
    @FocusState private var focused: Bool

    private struct Entry: Identifiable {
        let tab: ReaderStore
        let bench: Workbench
        let group: String
        var id: UUID { tab.id }
    }

    private var entries: [Entry] {
        var list: [Entry] = []
        let sides = bench.panes.count == 2 ? [store.t("Panel izquierdo"), store.t("Panel derecho")] : [store.t("Esta ventana")]
        for (index, pane) in bench.panes.enumerated() {
            list += pane.tabs.map { Entry(tab: $0, bench: bench, group: sides[min(index, sides.count - 1)]) }
        }
        for other in DocumentRouter.shared.workbenches where other !== bench {
            list += other.panes.flatMap(\.tabs).map { Entry(tab: $0, bench: other, group: store.t("Otras ventanas")) }
        }
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return list }
        return list.compactMap { entry -> (Entry, Int)? in
            let name = FuzzyMatch.score(needle, in: entry.tab.title).map { $0 + 20 }
            let path = FuzzyMatch.score(needle, in: location(of: entry.tab))
            guard let best = [name, path].compactMap({ $0 }).max() else { return nil }
            return (entry, best)
        }
        .sorted { $0.1 > $1.1 }.map(\.0)
    }

    var body: some View {
        let shown = entries
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.stack").foregroundStyle(.secondary)
                TextField(store.t("Buscar en las pestañas abiertas"), text: $query)
                    .textFieldStyle(.plain).font(.system(size: 15))
                    .focused($focused)
                    .onSubmit { go(shown) }
                    .onChange(of: query) { _, _ in selection = 0 }
                Text(String(format: store.t("%d pestañas"), shown.count))
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14).frame(height: 44)
            Divider()
            if shown.isEmpty {
                Text(store.t("Nada coincide.")).font(.system(size: 12)).foregroundStyle(.secondary).padding(18)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(shown.enumerated()), id: \.element.id) { index, entry in
                                if query.isEmpty, index == 0 || shown[index - 1].group != entry.group, groups(shown) > 1 {
                                    Text(entry.group.uppercased())
                                        .font(.system(size: 10, weight: .semibold)).tracking(1.1).foregroundStyle(.secondary)
                                        .padding(.horizontal, 10).padding(.top, index == 0 ? 4 : 12).padding(.bottom, 3)
                                }
                                row(entry, selected: index == selection)
                                    .id(index)
                                    .onTapGesture { selection = index; go(shown) }
                                    .onHover { hovered = $0 ? entry.id : (hovered == entry.id ? nil : hovered) }
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 440)
                    .onChange(of: selection) { _, value in proxy.scrollTo(value) }
                    .onAppear {
                        selection = shown.firstIndex { $0.tab === bench.focusedStore } ?? 0
                        proxy.scrollTo(selection, anchor: .center)
                    }
                }
            }
        }
        .frame(width: 600)
        .onAppear { focused = true }
        .onKeyPress(.downArrow) { selection = min(selection + 1, max(0, shown.count - 1)); return .handled }
        .onKeyPress(.upArrow) { selection = max(selection - 1, 0); return .handled }
        .onKeyPress(.escape) { store.showAllTabs = false; return .handled }
    }

    private func groups(_ list: [Entry]) -> Int { Set(list.map(\.group)).count }

    private func row(_ entry: Entry, selected: Bool) -> some View {
        let tab = entry.tab
        let current = tab === bench.focusedStore
        return HStack(spacing: 10) {
            Image(systemName: tab.isNewNote ? "square.and.pencil" : (tab.isWelcome ? "sparkle" : tab.kind.symbol))
                .foregroundStyle(selected ? Color.white : store.accentColor).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(tab.title).font(.system(size: 13, weight: current ? .semibold : .medium)).lineLimit(1)
                    if let folder = folder(of: tab) {
                        Text(folder).font(.system(size: 11.5)).lineLimit(1)
                            .foregroundStyle(selected ? Color.white.opacity(0.85) : Color.secondary)
                    }
                }
                Text(location(of: tab)).font(.system(size: 11)).lineLimit(1).truncationMode(.head)
                    .foregroundStyle(selected ? Color.white.opacity(0.75) : Color.secondary.opacity(0.8))
            }
            Spacer(minLength: 6)
            if tab.isDirty {
                Circle().fill(selected ? Color.white : store.accentColor).frame(width: 7, height: 7)
                    .help(store.t("Cambios sin guardar"))
            }
            if hovered == entry.id {
                Button { entry.bench.close(tab) } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                        .frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(store.t("Cerrar pestaña"))
            }
        }
        .foregroundStyle(selected ? Color.white : Color.primary)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(selected ? store.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .help(tab.fileURL?.path ?? tab.remoteURL?.absoluteString ?? tab.title)
    }

    private func folder(of tab: ReaderStore) -> String? {
        tab.fileURL?.deletingLastPathComponent().lastPathComponent ?? tab.remoteURL?.host
    }

    private func location(of tab: ReaderStore) -> String {
        if let file = tab.fileURL {
            return file.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        }
        if let remote = tab.remoteURL { return remote.absoluteString }
        return tab.isNewNote ? store.t("Nota sin guardar") : store.t("Pestaña vacía")
    }

    private func go(_ shown: [Entry]) {
        guard shown.indices.contains(selection) else { return }
        let entry = shown[selection]
        store.showAllTabs = false
        entry.bench.focus(entry.tab)
        entry.bench.window?.makeKeyAndOrderFront(nil)
    }
}
