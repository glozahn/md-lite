import SwiftUI

/// Matches typed letters against file names in order, preferring starts of words and runs of letters.
enum FuzzyMatch {
    /// A score, or nil when not every letter of `query` appears in `name` in order.
    static func score(_ query: String, in name: String) -> Int? {
        let needle = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !needle.isEmpty else { return 0 }
        let hay = Array(name.lowercased())
        var score = 0
        var index = 0
        var previous = -2
        for (position, character) in hay.enumerated() where index < needle.count && character == needle[index] {
            let wordStart = position == 0 || " -_./".contains(hay[position - 1])
            score += 1 + (position == previous + 1 ? 5 : 0) + (wordStart ? 3 : 0)
            previous = position
            index += 1
        }
        guard index == needle.count else { return nil }
        return score - hay.count / 8
    }
}

/// ⌥⌘P: jump to any file in the working folder, the recent list or favorites by typing part of its name.
struct QuickOpenView: View {
    @ObservedObject var store: ReaderStore
    @ObservedObject var bench: Workbench
    @ObservedObject private var prefs = AppPreferences.shared
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    private var candidates: [URL] {
        var seen = Set<String>()
        var list: [URL] = []
        func add(_ url: URL) { if seen.insert(url.standardizedFileURL.path).inserted { list.append(url) } }
        prefs.recent.forEach(add)
        prefs.favorites.forEach(add)
        func walk(_ nodes: [FileNode]) {
            for node in nodes {
                if node.isDirectory { walk(node.children ?? []) } else { add(node.url) }
            }
        }
        walk(bench.workspaceTree)
        return list
    }

    private var results: [URL] {
        let all = candidates
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return Array(all.prefix(12)) }
        return all.compactMap { url -> (URL, Int)? in
            let nameScore = FuzzyMatch.score(query, in: url.lastPathComponent).map { $0 + 20 }
            let pathScore = FuzzyMatch.score(query, in: relative(url))
            guard let best = [nameScore, pathScore].compactMap({ $0 }).max() else { return nil }
            return (url, best)
        }
        .sorted { $0.1 > $1.1 }
        .prefix(40).map(\.0)
    }

    private func relative(_ url: URL) -> String {
        guard let root = bench.workspace?.path, url.path.hasPrefix(root + "/") else {
            return url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        }
        return String(url.deletingLastPathComponent().path.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    var body: some View {
        let shown = results
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(store.t("Abrir rápido: escribe parte del nombre"), text: $query)
                    .textFieldStyle(.plain).font(.system(size: 15))
                    .focused($focused)
                    .onSubmit { open(shown) }
                    .onChange(of: query) { _, _ in selection = 0 }
            }
            .padding(.horizontal, 14).frame(height: 44)
            Divider()
            if shown.isEmpty {
                Text(bench.workspace == nil ? store.t("Abre una carpeta de trabajo para buscar en todos sus archivos.") : store.t("Nada coincide."))
                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(18)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 1) {
                            ForEach(Array(shown.enumerated()), id: \.element) { index, url in
                                row(url, selected: index == selection)
                                    .id(index)
                                    .onTapGesture { selection = index; open(shown) }
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 360)
                    .onChange(of: selection) { _, value in proxy.scrollTo(value) }
                }
            }
        }
        .frame(width: 560)
        .onAppear { focused = true }
        .onKeyPress(.downArrow) { selection = min(selection + 1, max(0, shown.count - 1)); return .handled }
        .onKeyPress(.upArrow) { selection = max(selection - 1, 0); return .handled }
        .onKeyPress(.escape) { store.showQuickOpen = false; return .handled }
    }

    private func row(_ url: URL, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: (FileTypes.kind(of: url) ?? .text).symbol)
                .foregroundStyle(selected ? Color.white : store.accentColor).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(relative(url)).font(.system(size: 11)).lineLimit(1).truncationMode(.head)
                    .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
            }
            Spacer()
        }
        .foregroundStyle(selected ? Color.white : Color.primary)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(selected ? store.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
    }

    private func open(_ shown: [URL]) {
        guard shown.indices.contains(selection) else { return }
        let url = shown[selection]
        store.showQuickOpen = false
        DocumentRouter.shared.open(url, from: store)
    }
}
