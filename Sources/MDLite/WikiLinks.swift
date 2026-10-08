import SwiftUI

/// `[[Note]]` and `[[Note|shown text]]` link to another document by name, wherever it sits in the
/// working folder. A note that does not exist yet is offered to be created on click.
enum WikiLinks {
    struct Span {
        let range: Range<String.Index>
        let target: String
        let label: String
    }

    static let scheme = "x-mdlite-wiki"

    static func spans(in text: String) -> [Span] {
        guard text.contains("[[") else { return [] }
        var spans: [Span] = []
        var index = text.startIndex
        while let open = text.range(of: "[[", range: index..<text.endIndex) {
            guard let close = text.range(of: "]]", range: open.upperBound..<text.endIndex) else { break }
            let inner = text[open.upperBound..<close.lowerBound]
            if inner.isEmpty || inner.contains("[") || inner.contains("\n") {
                index = open.upperBound
                continue
            }
            let parts = inner.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if let target = parts.first, !target.isEmpty {
                spans.append(Span(range: open.lowerBound..<close.upperBound, target: target, label: parts.count > 1 && !parts[1].isEmpty ? parts[1] : target))
            }
            index = close.upperBound
        }
        return spans
    }

    static func url(for target: String) -> URL? {
        URL(string: scheme + ":" + (target.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? target))
    }

    static func target(of url: URL) -> String? {
        guard url.scheme == scheme else { return nil }
        return String(url.absoluteString.dropFirst(scheme.count + 1)).removingPercentEncoding
    }

    /// The document a link points to: next to the current one first, then anywhere in the folder.
    static func resolve(_ target: String, from document: URL?, in files: [URL]) -> URL? {
        let path = target.components(separatedBy: "#")[0]
        guard !path.isEmpty else { return nil }
        let names = (path as NSString).pathExtension.isEmpty ? [path + ".md", path + ".markdown", path] : [path]
        if let folder = document?.deletingLastPathComponent() {
            for name in names {
                let candidate = folder.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            }
        }
        let wanted = names.map { ($0 as NSString).lastPathComponent.lowercased() }
        let suffixes = names.map { "/" + $0.lowercased() }
        return files.first { file in
            let lower = file.path.lowercased()
            return wanted.contains(file.lastPathComponent.lowercased()) && suffixes.contains { lower.hasSuffix($0) }
        }
    }

    /// The name other documents use to link here.
    static func name(of file: URL) -> String { file.deletingPathExtension().lastPathComponent }

    struct Mention: Identifiable, Hashable {
        let id = UUID()
        let file: URL
        let offset: Int
        let text: String
    }

    /// Lines in other Markdown files that link to `file`, by `[[name]]` or by a link to its file name.
    nonisolated static func mentions(of file: URL, in files: [URL], limit: Int = 60) -> [Mention] {
        let name = self.name(of: file).lowercased()
        let fileName = file.lastPathComponent.lowercased()
        let encodedName = (file.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fileName).lowercased()
        var found: [Mention] = []
        for other in files where other.standardizedFileURL != file.standardizedFileURL && FileTypes.kind(of: other) == .markdown {
            guard let size = try? other.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_000_000,
                  let text = try? String(contentsOf: other, encoding: .utf8) else { continue }
            let lower = text.lowercased()
            guard lower.contains(name) else { continue }
            var offset = 0
            text.enumerateLines { line, stop in
                defer { offset += (line as NSString).length + 1 }
                let lowerLine = line.lowercased()
                guard lowerLine.contains(name) else { return }
                let wiki = spans(in: line).contains { span in
                    let target = (span.target.components(separatedBy: "#")[0] as NSString)
                    let last = (target.lastPathComponent as NSString)
                    return (last.pathExtension.isEmpty ? last as String : last.deletingPathExtension).lowercased() == name
                }
                let linked = lowerLine.contains("/" + fileName + ")") || lowerLine.contains("(" + fileName + ")")
                    || lowerLine.contains("(" + encodedName + ")") || lowerLine.contains("/" + encodedName + ")")
                    || lowerLine.contains("(" + fileName + "#") || lowerLine.contains("/" + fileName + "#")
                if wiki || linked {
                    found.append(Mention(file: other, offset: offset, text: line.trimmingCharacters(in: .whitespaces)))
                    if found.count >= limit { stop = true }
                }
            }
            if found.count >= limit { break }
        }
        return found
    }
}

/// Sidebar: the documents in the working folder that link to the one in front.
struct BacklinksSection: View {
    @ObservedObject var store: ReaderStore
    @ObservedObject var bench: Workbench
    let palette: SidebarPalette
    @State private var mentions: [WikiLinks.Mention] = []

    /// The working folder, plus the notes next to this one when it lives elsewhere.
    private var files: [URL] {
        var list = bench.workspace != nil ? FolderSearch.files(in: bench.workspaceTree) : []
        if let folder = store.fileURL?.deletingLastPathComponent(),
           bench.workspace.map({ !folder.path.hasPrefix($0.path + "/") && folder.path != $0.path }) ?? true {
            list += ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                .filter { FileTypes.kind(of: $0) == .markdown }
        }
        return list
    }

    var body: some View {
        let list = files
        // A stack, not a Group: a Group with nothing in it would never start the task below.
        VStack(alignment: .leading, spacing: 2) {
            if !mentions.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.uturn.backward").font(.system(size: 10.5))
                    Text(store.t("MENCIONADO EN")).font(.system(size: 10.5, weight: .semibold)).tracking(1.2)
                    Spacer()
                    Text("\(mentions.count)").font(.system(size: 10.5)).foregroundStyle(palette.faint)
                }
                .foregroundStyle(palette.label).padding(.horizontal, 8).padding(.top, 18).padding(.bottom, 4)
                ForEach(mentions) { mention in
                    Button { open(mention) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Image(systemName: "doc.text").font(.system(size: 11)).foregroundStyle(palette.label)
                                Text(mention.file.deletingPathExtension().lastPathComponent).font(.system(size: 12.5)).lineLimit(1)
                            }
                            Text(mention.text).font(.system(size: 11)).foregroundStyle(palette.label).lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8).padding(.vertical, 6).contentShape(Rectangle())
                    }
                    .buttonStyle(SidebarRowStyle(palette: palette))
                    .help(mention.file.path)
                }
            }
        }
        .task(id: "\(store.fileURL?.path ?? "")|\(list.count)|\(store.lastSaved?.timeIntervalSince1970 ?? 0)") {
            guard let file = store.fileURL, store.kind.isMarkdown, !list.isEmpty else { mentions = []; return }
            let found = await Task.detached(priority: .utility) { WikiLinks.mentions(of: file, in: list) }.value
            if !Task.isCancelled { mentions = found }
        }
    }

    private func open(_ mention: WikiLinks.Mention) {
        DocumentRouter.shared.open(mention.file, from: store)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard let target = DocumentRouter.shared.all.first(where: { $0.fileURL?.standardizedFileURL == mention.file.standardizedFileURL }) else { return }
            target.jump(toSource: mention.offset)
        }
    }
}
