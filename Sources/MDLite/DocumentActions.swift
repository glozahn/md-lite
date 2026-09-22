import AppKit
import Markdown
import UniformTypeIdentifiers

/// Save-as, duplicate, export and print, for open tabs and for files in the sidebar.
@MainActor
enum DocumentActions {
    static func source(of url: URL) -> String? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 5_000_000 else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// "name copy.md", "name copy 2.md", … next to the original.
    static func duplicateURL(for url: URL, prefs: AppPreferences) -> URL {
        let folder = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.isEmpty ? "md" : url.pathExtension
        let word = prefs.t("copia")
        var candidate = folder.appendingPathComponent("\(base) \(word).\(ext)")
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(word) \(number).\(ext)")
            number += 1
        }
        return candidate
    }

    /// Writes a copy next to `url` (using `text` when given, e.g. unsaved edits) and returns it.
    @discardableResult
    static func duplicate(_ url: URL, text: String? = nil, prefs: AppPreferences) -> URL? {
        let target = duplicateURL(for: url, prefs: prefs)
        do {
            if let text { try text.write(to: target, atomically: true, encoding: .utf8) }
            else { try FileManager.default.copyItem(at: url, to: target) }
            return target
        } catch {
            NSAlert(error: error).runModal()
            return nil
        }
    }

    /// Saves a copy of a file somewhere else.
    static func saveCopy(of url: URL, prefs: AppPreferences) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = url.lastPathComponent
        panel.directoryURL = url.deletingLastPathComponent()
        guard panel.runModal() == .OK, let target = panel.url else { return nil }
        do {
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            try FileManager.default.copyItem(at: url, to: target)
            return target
        } catch {
            NSAlert(error: error).runModal()
            return nil
        }
    }

    // MARK: Export

    static func exportHTML(source: String, title: String, suggestedFolder: URL?, prefs: AppPreferences) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = title + ".html"
        panel.directoryURL = suggestedFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let front = GFM.frontMatter(in: source)
        let body = HTMLFormatter.format(front?.masked ?? source)
        let escapedTitle = title.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        let page = """
        <!doctype html>
        <html lang="\(prefs.resolvedLanguage)">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="generator" content="MD Lite">
        <title>\(escapedTitle)</title>
        <style>
        :root { color-scheme: light dark; }
        body { margin: 0; font: 17px/1.65 -apple-system, "Segoe UI", system-ui, sans-serif; color: #1f2328; background: #fbfaf7; }
        article { max-width: 780px; margin: 0 auto; padding: 40px 32px 80px; }
        h1, h2 { border-bottom: 1px solid rgba(0,0,0,.1); padding-bottom: .3em; }
        h1, h2, h3, h4 { line-height: 1.25; margin: 1.5em 0 .6em; }
        a { color: #0a84ff; }
        img { max-width: 100%; }
        code, pre { font-family: ui-monospace, "SF Mono", Menlo, Consolas, monospace; font-size: .86em; }
        :not(pre) > code { background: rgba(0,0,0,.055); border-radius: 5px; padding: .12em .36em; }
        pre { background: rgba(0,0,0,.035); border: 1px solid rgba(0,0,0,.06); border-radius: 10px; padding: 14px 16px; overflow-x: auto; }
        blockquote { margin: 0 0 1em; padding: .1em 1em; border-left: 3px solid rgba(0,0,0,.15); color: #5f6670; }
        table { border-collapse: collapse; width: 100%; }
        th, td { border: 1px solid rgba(0,0,0,.12); padding: .45em .8em; }
        th { background: rgba(0,0,0,.04); }
        hr { border: 0; border-top: 1px solid rgba(0,0,0,.12); margin: 1.6em 0; }
        @media (prefers-color-scheme: dark) {
          body { color: #e6e8eb; background: #16181c; }
          h1, h2 { border-color: rgba(255,255,255,.12); }
          :not(pre) > code { background: rgba(255,255,255,.1); }
          pre { background: rgba(255,255,255,.05); border-color: rgba(255,255,255,.07); }
          th, td { border-color: rgba(255,255,255,.12); }
          blockquote { color: #a2a8b1; border-color: rgba(255,255,255,.2); }
        }
        </style>
        </head>
        <body>
        <article>
        \(body)
        </article>
        </body>
        </html>
        """
        do { try page.write(to: url, atomically: true, encoding: .utf8) } catch { NSAlert(error: error).runModal() }
    }

    /// A paginated, print-ready text view of the document (always light).
    private static func printableView(source: String, baseURL: URL?, prefs: AppPreferences, info: NSPrintInfo) -> MDTextView {
        let renderer = MarkdownRenderer(size: 12.5, baseURL: baseURL, accent: prefs.accentNSColor, language: prefs.resolvedLanguage)
        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        renderer.maxImageWidth = width - 20
        renderer.mermaid = { code in MermaidRenderer.shared.result(for: code, dark: false) }
        let text = NSMutableAttributedString(attributedString: renderer.render(source).text)
        // Link styling is screen-only in NSTextView; bake it in so links read as links on paper.
        text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard value != nil else { return }
            text.addAttributes([.foregroundColor: prefs.accentNSColor, .underlineStyle: NSUnderlineStyle.single.rawValue], range: range)
        }
        let view = MDTextView.make()
        view.appearance = NSAppearance(named: .aqua)
        view.mdLayoutManager?.showsCopyButton = false
        view.minimumInset = 0
        view.verticalInset = 0
        view.columnWidth = width
        view.frame = NSRect(x: 0, y: 0, width: width, height: 100)
        view.textStorage?.setAttributedString(text)
        if let layout = view.layoutManager, let container = view.textContainer {
            layout.ensureLayout(for: container)
            view.frame.size.height = layout.usedRect(for: container).height + 20
        }
        return view
    }

    private static func printInfo() -> NSPrintInfo {
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.topMargin = 56
        info.bottomMargin = 56
        info.leftMargin = 60
        info.rightMargin = 60
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        return info
    }

    static func exportPDF(source: String, title: String, baseURL: URL?, suggestedFolder: URL?, prefs: AppPreferences) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = title + ".pdf"
        panel.directoryURL = suggestedFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        MDSymbols.rasterized = true
        defer { MDSymbols.rasterized = false }
        let info = printInfo()
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        let operation = NSPrintOperation(view: printableView(source: source, baseURL: baseURL, prefs: prefs, info: info), printInfo: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        operation.jobTitle = title
        operation.run()
    }

    static func print(source: String, title: String, baseURL: URL?, prefs: AppPreferences) {
        MDSymbols.rasterized = true
        defer { MDSymbols.rasterized = false }
        let info = printInfo()
        let operation = NSPrintOperation(view: printableView(source: source, baseURL: baseURL, prefs: prefs, info: info), printInfo: info)
        operation.jobTitle = title
        operation.run()
    }
}

extension ReaderStore {
    var markdownSource: String { source }
    private var exportFolder: URL? { fileURL?.deletingLastPathComponent() ?? workspace }

    func exportHTML() { DocumentActions.exportHTML(source: source, title: title, suggestedFolder: exportFolder, prefs: prefs) }
    func exportPDF() {
        DocumentActions.exportPDF(source: source, title: title, baseURL: fileURL?.deletingLastPathComponent(), suggestedFolder: exportFolder, prefs: prefs)
    }
    func printDocument() { DocumentActions.print(source: source, title: title, baseURL: fileURL?.deletingLastPathComponent(), prefs: prefs) }

    /// Copies this document (with unsaved edits) next to the original and opens the copy in a new tab.
    func duplicateDocument() {
        guard let fileURL else {
            workbench?.newTab().readPastedText(source)
            return
        }
        if let copy = DocumentActions.duplicate(fileURL, text: source, prefs: prefs) {
            DocumentRouter.shared.open(copy, from: self, newTab: true)
            workbench?.refreshWorkspace()
        }
    }
}
