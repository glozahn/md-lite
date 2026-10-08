import SwiftUI
import CryptoKit

/// Local version history: before a save replaces a file, the text on disk is kept as a snapshot,
/// at most every few minutes, the last 50 per file. Stored in Application Support, never synced.
enum History {
    struct Version: Identifiable, Hashable {
        let url: URL
        let date: Date
        var id: URL { url }
    }

    private static let keep = 50
    private static let spacing: TimeInterval = 180

    private static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MD Lite/History", isDirectory: true)
    }

    static func folder(for file: URL) -> URL {
        let digest = SHA256.hash(data: Data(file.standardizedFileURL.path.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(digest, isDirectory: true)
    }

    static func versions(of file: URL) -> [Version] {
        let folder = folder(for: file)
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return items.filter { $0.pathExtension == "snapshot" }.compactMap { url in
            guard let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return nil }
            return Version(url: url, date: date)
        }
        .sorted { $0.date > $1.date }
    }

    /// Keeps what is on disk now, before `newText` replaces it.
    static func snapshot(before newText: String, at file: URL) {
        guard let old = try? String(contentsOf: file, encoding: .utf8), old != newText, !old.isEmpty else { return }
        let existing = versions(of: file)
        if let latest = existing.first, Date().timeIntervalSince(latest.date) < spacing { return }
        if let latest = existing.first, let last = try? String(contentsOf: latest.url, encoding: .utf8), last == old { return }
        let folder = folder(for: file)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-") + ".snapshot"
        try? old.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
        try? (file.path as NSString).write(to: folder.appendingPathComponent("path.txt"), atomically: true, encoding: String.Encoding.utf8.rawValue)
        for version in existing.dropFirst(keep - 1) { try? FileManager.default.removeItem(at: version.url) }
    }

    /// Line differences from `old` to `new`, in order, for a compact view.
    struct Line: Identifiable {
        enum Kind { case same, added, removed }
        let id: Int
        let kind: Kind
        let text: String
    }

    static func diff(from old: String, to new: String) -> [Line] {
        let a = old.components(separatedBy: "\n"), b = new.components(separatedBy: "\n")
        let changes = b.difference(from: a)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in changes {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var lines: [Line] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, removed.contains(i) {
                lines.append(Line(id: lines.count, kind: .removed, text: a[i])); i += 1
            } else if j < b.count, inserted.contains(j) {
                lines.append(Line(id: lines.count, kind: .added, text: b[j])); j += 1
            } else {
                if j < b.count { lines.append(Line(id: lines.count, kind: .same, text: b[j])) }
                i += 1; j += 1
            }
        }
        return lines
    }
}

/// File ▸ Version History: earlier saves of this file, what changed since each one, and a way back.
struct HistoryView: View {
    @ObservedObject var store: ReaderStore
    @State private var versions: [History.Version] = []
    @State private var selected: History.Version?
    @State private var text = ""
    @State private var onlyChanges = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(store.t("Historial de versiones")).font(.system(size: 14, weight: .semibold))
                Text(store.title).font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Toggle(store.t("Solo cambios"), isOn: $onlyChanges).toggleStyle(.switch).controlSize(.small)
            }
            .padding(.horizontal, 16).frame(height: 44)
            Divider()
            if versions.isEmpty {
                Text(store.t("Todavía no hay versiones anteriores. MD Lite guarda una antes de cada guardado, cada pocos minutos."))
                    .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).padding(30)
            } else {
                HStack(spacing: 0) {
                    List(versions, selection: $selected) { version in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(version.date.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 12, weight: .medium))
                            Text(version.date.formatted(.relative(presentation: .named))).font(.system(size: 10.5)).foregroundStyle(.secondary)
                        }
                        .tag(version)
                    }
                    .listStyle(.sidebar)
                    .frame(width: 200)
                    Divider()
                    diffView
                }
            }
            Divider()
            HStack {
                Button(store.t("Cerrar")) { store.showHistory = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(store.t("Restaurar esta versión")) { restore() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected == nil)
            }
            .padding(12)
        }
        .frame(width: 780, height: 520)
        .onAppear {
            if let file = store.fileURL { versions = History.versions(of: file) }
            selected = versions.first
        }
        .onChange(of: selected) { _, version in text = version.flatMap { try? String(contentsOf: $0.url, encoding: .utf8) } ?? "" }
    }

    private var diffView: some View {
        let lines = History.diff(from: text, to: store.markdownSource)
        let shown = onlyChanges ? lines.filter { $0.kind != .same } : lines
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if shown.isEmpty {
                    Text(store.t("Igual al documento actual.")).font(.system(size: 12)).foregroundStyle(.secondary).padding(16)
                }
                ForEach(shown) { line in
                    HStack(alignment: .top, spacing: 8) {
                        Text(line.kind == .added ? "+" : line.kind == .removed ? "−" : " ")
                            .foregroundStyle(line.kind == .added ? Color.green : line.kind == .removed ? Color.red : Color.secondary)
                        Text(line.text.isEmpty ? " " : line.text).textSelection(.enabled)
                    }
                    .font(.system(size: 11.5, design: .monospaced))
                    .padding(.horizontal, 12).padding(.vertical, 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(line.kind == .added ? Color.green.opacity(0.1) : line.kind == .removed ? Color.red.opacity(0.1) : Color.clear)
                }
            }
            .padding(.vertical, 8)
        }
    }

    /// The current text is kept as a version first, so restoring can itself be undone.
    private func restore() {
        guard let file = store.fileURL, selected != nil else { return }
        try? FileManager.default.createDirectory(at: History.folder(for: file), withIntermediateDirectories: true)
        let backup = History.folder(for: file).appendingPathComponent(ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-") + ".snapshot")
        try? store.markdownSource.write(to: backup, atomically: true, encoding: .utf8)
        store.restoreVersion(text)
        store.showHistory = false
    }
}
