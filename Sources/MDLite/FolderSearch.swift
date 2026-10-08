import SwiftUI

/// Text search across the working folder: every line that contains the query, with its file and context.
/// Runs off the main thread and reads only the text files MD Lite can show, up to 1 MB each.
enum FolderSearch {
    struct Match: Identifiable, Hashable {
        let id = UUID()
        let file: URL
        let line: Int
        /// Offset of the line in the file's text, to jump there.
        let offset: Int
        let text: String
    }

    static func files(in nodes: [FileNode]) -> [URL] {
        nodes.flatMap { $0.isDirectory ? files(in: $0.children ?? []) : [$0.url] }
    }

    nonisolated static func search(_ query: String, in files: [URL], limit: Int = 400) -> [Match] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard needle.count >= 2 else { return [] }
        var matches: [Match] = []
        for file in files {
            guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_000_000,
                  let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            var offset = 0
            var number = 0
            text.enumerateLines { line, stop in
                number += 1
                if line.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                    matches.append(Match(file: file, line: number, offset: offset, text: line.trimmingCharacters(in: .whitespaces)))
                    if matches.count >= limit { stop = true }
                }
                offset += (line as NSString).length + 1
            }
            if matches.count >= limit { break }
        }
        return matches
    }
}

/// ⌥⌘F: find text in every file of the working folder.
struct FolderSearchView: View {
    @ObservedObject var store: ReaderStore
    @ObservedObject var bench: Workbench
    @State private var query = ""
    @State private var matches: [FolderSearch.Match] = []
    @State private var searching = false
    @State private var selection = 0
    @State private var work: Task<Void, Never>?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "text.magnifyingglass").foregroundStyle(.secondary)
                TextField(store.t("Buscar en la carpeta"), text: $query)
                    .textFieldStyle(.plain).font(.system(size: 15))
                    .focused($focused)
                    .onSubmit { open() }
                    .onChange(of: query) { _, value in run(value) }
                if searching { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 14).frame(height: 44)
            Divider()
            content
        }
        .frame(width: 640)
        .onAppear { focused = true }
        .onKeyPress(.downArrow) { selection = min(selection + 1, max(0, matches.count - 1)); return .handled }
        .onKeyPress(.upArrow) { selection = max(selection - 1, 0); return .handled }
        .onKeyPress(.escape) { store.showFolderSearch = false; return .handled }
    }

    @ViewBuilder private var content: some View {
        if bench.workspace == nil {
            Text(store.t("Abre una carpeta de trabajo para buscar en todos sus archivos."))
                .font(.system(size: 12)).foregroundStyle(.secondary).padding(18)
        } else if matches.isEmpty {
            Text(query.count < 2 ? store.t("Escribe al menos dos letras.") : (searching ? "" : store.t("Nada coincide.")))
                .font(.system(size: 12)).foregroundStyle(.secondary).padding(18)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(matches.enumerated()), id: \.element.id) { index, match in
                            row(match, selected: index == selection)
                                .id(index)
                                .onTapGesture { selection = index; open() }
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 420)
                .onChange(of: selection) { _, value in proxy.scrollTo(value) }
            }
            Text(String(format: store.t("%d resultados"), matches.count))
                .font(.system(size: 10.5)).foregroundStyle(.tertiary).padding(.vertical, 6)
        }
    }

    private func row(_ match: FolderSearch.Match, selected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: (FileTypes.kind(of: match.file) ?? .text).symbol).font(.system(size: 10))
                Text(match.file.lastPathComponent).font(.system(size: 11.5, weight: .semibold))
                Text(":\(match.line)").font(.system(size: 11, design: .monospaced)).opacity(0.7)
            }
            Text(highlighted(match.text)).font(.system(size: 12)).lineLimit(2)
        }
        .foregroundStyle(selected ? Color.white : Color.primary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(selected ? store.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
    }

    private func highlighted(_ line: String) -> AttributedString {
        var text = AttributedString(line.count > 220 ? String(line.prefix(220)) + "…" : line)
        if let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) {
            text[range].font = .system(size: 12, weight: .bold)
        }
        return text
    }

    private func run(_ value: String) {
        work?.cancel()
        selection = 0
        guard value.trimmingCharacters(in: .whitespaces).count >= 2 else { matches = []; searching = false; return }
        let files = FolderSearch.files(in: bench.workspaceTree)
        searching = true
        work = Task {
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            let found = await Task.detached(priority: .userInitiated) { FolderSearch.search(value, in: files) }.value
            guard !Task.isCancelled else { return }
            matches = found
            searching = false
        }
    }

    private func open() {
        guard matches.indices.contains(selection) else { return }
        let match = matches[selection]
        store.showFolderSearch = false
        DocumentRouter.shared.open(match.file, from: store)
        // Once the file is open, bring the matching line to the top.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard let target = DocumentRouter.shared.all.first(where: { $0.fileURL?.standardizedFileURL == match.file.standardizedFileURL }) else { return }
            target.jump(toSource: match.offset)
        }
    }
}
