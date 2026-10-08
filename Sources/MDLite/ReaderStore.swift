import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

enum ScrollTarget: Equatable {
    case none, top, bottom
    /// A place in the source, as remembered for a file.
    case source(Int)
    case heading(OutlineItem)
}

struct ScrollRequest: Equatable {
    var id = 0
    var target: ScrollTarget = .none
}

/// Where the reader is in the document. Changes on every scroll step, so few views observe it.
@MainActor
/// The heading being read. Kept apart from the store so scrolling only redraws the outline.
final class ReadingTracker: ObservableObject {
    @Published var currentHeading: Int?
}

/// Reading progress for the footer. Separate from the heading so each scroll tick does not redraw the outline.
final class ProgressTracker: ObservableObject {
    @Published var percent = 0
    var progress: Double { Double(percent) / 100 }
}

extension Notification.Name {
    static let mermaidDidRender = Notification.Name("MDLiteMermaidDidRender")
}

/// State of one document tab. Shared settings live in `AppPreferences`.
@MainActor
final class ReaderStore: ObservableObject {
    let prefs: AppPreferences

    /// Markdown source of the open document. Not published: the editor owns typing.
    private(set) var source = welcomeMarkdown
    @Published var fileURL: URL?
    /// A document read from the web. Read-only; "Save a Copy" keeps it.
    @Published private(set) var remoteURL: URL?
    @Published private(set) var isFeed = false
    @Published private(set) var isLoadingRemote = false
    @Published var isPastedDocument = false
    @Published var isNewNote = false
    @Published var showPasteEditor = false
    @Published var pasteDraft = ""
    var isWelcome: Bool { fileURL == nil && remoteURL == nil && !isPastedDocument && !isNewNote && !isBlank && !isChangelog }
    /// Showing the bundled changelog.
    @Published private(set) var isChangelog = false
    /// An empty tab waiting for a document.
    @Published private(set) var isBlank = false
    @Published private(set) var rendered = RenderedDocument(text: NSAttributedString(), outline: [])
    @Published private(set) var renderVersion = 0
    @Published private(set) var contentVersion = 0
    var didReplaceDocument = true
    @Published var error: String?
    @Published var mode: DocumentMode = .read {
        didSet {
            if mode == .edit || mode == .source { lastEditMode = mode }
            if mode != .edit && mode != .source, renderPending { renderNow() }
        }
    }
    private var lastEditMode: DocumentMode = .edit
    var focusMode: Bool {
        get { workbench?.focusMode ?? false }
        set {
            guard focusMode != newValue else { return }
            objectWillChange.send()
            workbench?.focusMode = newValue
        }
    }
    /// Scroll position state, published separately so scrolling only redraws the outline and the footer.
    let tracker = ReadingTracker()
    var currentHeading: Int? {
        get { tracker.currentHeading }
        set { if tracker.currentHeading != newValue { tracker.currentHeading = newValue } }
    }
    let progressTracker = ProgressTracker()
    var progress: Double { progressTracker.progress }
    @Published var scrollRequest = ScrollRequest()
    @Published var findRequest = 0
    @Published private(set) var isDirty = false
    @Published private(set) var lastSaved: Date?
    @Published private(set) var wordCount = 0
    @Published var showShortcuts = false
    @Published var showDefaultAppGuide = false
    @Published var showQuickSettings = false
    @Published var showQuickOpen = false
    @Published private(set) var remoteImagesAllowed: Bool
    @Published private(set) var isDark = false
    let id = UUID()
    weak var workbench: Workbench?
    /// Reader and editor views for this tab. Kept alive while the tab exists so undo history,
    /// selection and scroll position survive switching tabs.
    lazy var controller = DocumentController(store: self)

    weak var document: DocumentEditing?
    var window: NSWindow? { workbench?.window }
    var workspace: URL? { workbench?.workspace }
    private var watcher: DispatchSourceFileSystemObject?
    private var reloadWork: DispatchWorkItem?
    private var renderWork: DispatchWorkItem?
    private var saveWork: DispatchWorkItem?
    private var renderPending = false
    private var lastWritten: String?
    private var remoteCache: [URL: NSImage] = [:]
    private var remoteLoading = Set<URL>()
    private var subscriptions = Set<AnyCancellable>()
    private var renderKey = ""
    private var welcomeLanguage = ""

    // MARK: Shared preferences, forwarded for views and tests

    var fontSize: Double { get { prefs.fontSize } set { prefs.fontSize = newValue } }
    var appearance: String { get { prefs.appearance } set { prefs.appearance = newValue } }
    var language: String { get { prefs.language } set { prefs.language = newValue; applyPreferences() } }
    var accent: String { get { prefs.accent } set { prefs.accent = newValue; applyPreferences() } }
    var textWidth: String { get { prefs.textWidth } set { prefs.textWidth = newValue } }
    var sidebarVisible: Bool { get { prefs.sidebarVisible } set { prefs.sidebarVisible = newValue } }
    var alwaysLoadRemoteImages: Bool { get { prefs.alwaysLoadRemoteImages } set { prefs.alwaysLoadRemoteImages = newValue } }
    var automaticUpdates: Bool { get { prefs.automaticUpdates } set { prefs.automaticUpdates = newValue } }
    var recent: [URL] { prefs.recent }
    var defaultApp: DefaultAppStatus { prefs.defaultApp }
    var resolvedLanguage: String { prefs.resolvedLanguage }
    var accentNSColor: NSColor { prefs.accentNSColor }
    var accentColor: Color { prefs.accentColor }
    var columnWidth: CGFloat { prefs.columnWidth }
    func t(_ key: String) -> String { prefs.t(key) }
    func refreshDefaultApp() { prefs.refreshDefaultApp() }
    func makeDefaultMarkdownApp() { prefs.makeDefaultMarkdownApp { [weak self] message in self?.error = message } }

    var title: String {
        if let fileURL { return fileURL.deletingPathExtension().lastPathComponent }
        if isFeed, let name = rendered.outline.first?.title { return name }
        if let remoteURL {
            let name = remoteURL.deletingPathExtension().lastPathComponent
            return isFeed || name.isEmpty || name == "/" || name == "raw" ? (remoteURL.host ?? "Web") : name
        }
        if isNewNote { return t("Nueva nota") }
        if isBlank { return t("Nueva pestaña") }
        if isChangelog { return t("Novedades") }
        return t(isPastedDocument ? "Texto pegado" : "Bienvenido")
    }
    var readingMinutes: Int { max(1, Int(ceil(Double(wordCount) / 220))) }
    var outline: [OutlineItem] { rendered.outline }
    /// What kind of file this tab shows. Notes, pasted text and the welcome page are Markdown.
    var kind: DocumentKind {
        if let fileURL { return FileTypes.kind(of: fileURL) ?? .text }
        if let remoteURL, !isFeed { return FileTypes.kind(of: remoteURL) ?? .markdown }
        return .markdown
    }
    /// Logs and web pages are only read.
    var isReadOnly: Bool { kind.isReadOnly || remoteURL != nil }
    /// Lines in the source, for the footer of files that are not prose.
    @Published private(set) var lineCount = 0
    /// A log keeps showing its newest lines while the reader stays at the end, like `tail -f`.
    var followsEnd = true
    /// How much of the top of the document the floating bars cover; the text starts below it.
    @Published var topInset: CGFloat = 60
    /// A tab that only shows the welcome page (or an untouched note) can take the next document.
    var canReuseForNewDocument: Bool { !isDirty && (isBlank || isWelcome || (isNewNote && source.count < 40)) }

    func makeBlank() {
        isBlank = true
        mode = .read
        source = ""
        contentVersion += 1
        renderNow()
    }

    init(preferences: AppPreferences? = nil) {
        let preferences = preferences ?? .shared
        prefs = preferences
        remoteImagesAllowed = preferences.alwaysLoadRemoteImages
        MermaidRenderer.shared.onUpdate = { NotificationCenter.default.post(name: .mermaidDidRender, object: nil) }
        preferences.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
                DispatchQueue.main.async { self?.applyPreferences() }
            }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .mermaidDidRender)
            .sink { [weak self] _ in
                guard let self, self.source.contains("mermaid") else { return }
                self.renderNow()
            }
            .store(in: &subscriptions)
        applyPreferences()
    }

    private var currentRenderKey: String {
        "\(prefs.fontSize)|\(prefs.accent)|\(prefs.resolvedLanguage)|\(prefs.textWidth)|\(isDark)"
    }

    /// Re-renders when a preference that affects the page changed.
    private func applyPreferences() {
        if prefs.alwaysLoadRemoteImages, !remoteImagesAllowed { remoteImagesAllowed = true; loadRemoteImages() }
        if isWelcome, !isBlank, !isDirty, welcomeLanguage != prefs.resolvedLanguage {
            welcomeLanguage = prefs.resolvedLanguage
            replaceSource(prefs.resolvedLanguage == "es" ? welcomeMarkdown : welcomeMarkdownEnglish)
            return
        }
        if currentRenderKey != renderKey { renderNow() }
    }

    func setDarkAppearance(_ dark: Bool) {
        guard dark != isDark else { return }
        isDark = dark
        renderNow()
    }

    /// Closing a tab or window never loses work: files save, untitled text goes to a recovery file.
    func preserveUnsavedWork() {
        guard isDirty else { return }
        if fileURL != nil { _ = save(); return }
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MD Lite/Recovered", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = folder.appendingPathComponent("\(suggestedName) \(stamp).md")
        if (try? source.write(to: url, atomically: true, encoding: .utf8)) != nil { prefs.addRecent(url) }
    }

    // MARK: Documents

    private func replaceSource(_ text: String) {
        isBlank = false
        isChangelog = false
        source = text
        contentVersion += 1
        didReplaceDocument = true
        currentHeading = nil
        isDirty = false
        renderNow()
    }

    /// Asks before discarding unsaved edits. Returns false when the user cancels.
    func confirmDiscard() -> Bool {
        guard isDirty else { return true }
        if fileURL != nil { return save() }
        let alert = NSAlert()
        alert.messageText = String(format: t("¿Guardar los cambios de “%@”?"), title)
        alert.informativeText = t("Si no los guardas, se perderán.")
        alert.addButton(withTitle: t("Guardar…"))
        alert.addButton(withTitle: t("No guardar"))
        alert.addButton(withTitle: t("Cancelar"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: return saveAs()
        case .alertSecondButtonReturn: isDirty = false; return true
        default: return false
        }
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = FileTypes.contentTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { DocumentRouter.shared.open(url, from: self) }
    }

    /// Opens `url` in this tab. `quiet` skips the error alert (restored tabs whose file moved).
    func open(_ url: URL, quiet: Bool = false) {
        guard url != fileURL || !isDirty else { return }
        guard confirmDiscard() else { return }
        do {
            let text = try readFile(url)
            reloadWork?.cancel()
            isPastedDocument = false
            isNewNote = false
            fileURL = url
            remoteURL = nil
            isFeed = false
            lastWritten = text
            if !prefs.alwaysLoadRemoteImages { remoteImagesAllowed = false }
            // The live Markdown editor means nothing for code; logs are only read.
            if kind.isReadOnly || (!kind.isMarkdown && mode == .edit) { mode = .read }
            followsEnd = true
            replaceSource(text)
            let remembered = ReadingPositions.offset(for: url).map { ScrollTarget.source($0) }
            scrollRequest = ScrollRequest(id: scrollRequest.id + 1, target: kind == .log ? .bottom : (remembered ?? .top))
            prefs.addRecent(url)
            watch(url)
        } catch {
            if !quiet { self.error = "\(t("No se pudo abrir")) \(url.lastPathComponent). \(errorMessage(error))" }
        }
    }

    private func readFile(_ url: URL) throws -> String {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        let size = values.fileSize ?? Int.max
        guard values.isRegularFile == true else { throw ReaderError.tooLarge }
        // A log can grow without limit; what matters is its end.
        if FileTypes.kind(of: url) == .log, size > Self.logTail {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(size - Self.logTail))
            let data = try handle.readToEnd() ?? Data()
            var text = String(decoding: data, as: UTF8.self)
            if let firstBreak = text.firstIndex(of: "\n") { text = String(text[text.index(after: firstBreak)...]) }
            return text
        }
        guard size <= 5_000_000 else { throw ReaderError.tooLarge }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static let logTail = 2_000_000

    private func detach() {
        watcher?.cancel()
        watcher = nil
        reloadWork?.cancel()
        fileURL = nil
        remoteURL = nil
        isFeed = false
        lastWritten = nil
    }

    func welcome() {
        guard confirmDiscard() else { return }
        detach()
        isPastedDocument = false
        isNewNote = false
        mode = .read
        welcomeLanguage = prefs.resolvedLanguage
        replaceSource(prefs.resolvedLanguage == "es" ? welcomeMarkdown : welcomeMarkdownEnglish)
        scrollRequest = ScrollRequest(id: scrollRequest.id + 1, target: .top)
    }

    func presentPasteEditor() {
        pasteDraft = isPastedDocument ? source : ""
        showPasteEditor = true
    }

    func newNote() {
        guard confirmDiscard() else { return }
        detach()
        isPastedDocument = false
        isNewNote = true
        replaceSource("# " + t("Nueva nota") + "\n\n")
        mode = .edit
    }

    // MARK: Running

    let runner = ScriptRunner()

    /// A shell script saved on this Mac.
    var isShellScript: Bool { fileURL != nil && kind == .code(language: "shell") }

    /// Runs this .sh file with the interpreter its first line asks for.
    func runScript() {
        guard isShellScript, let file = fileURL else { return }
        if isDirty { save() }
        let folder = file.deletingLastPathComponent()
        let firstLine = source.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        let interpreter = firstLine.hasPrefix("#!") ? String(firstLine.dropFirst(2)).trimmingCharacters(in: .whitespaces) : "/bin/sh"
        let quoted = "'" + file.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        guard ScriptRunner.confirm(source, title: file.lastPathComponent, folder: folder, prefs: prefs) else { return }
        runner.run(interpreter + " " + quoted, title: file.lastPathComponent, in: folder)
    }

    /// Runs a shell code block from this document, in its folder.
    func runCode(_ code: String, language: String?) {
        guard remoteURL == nil else { return }
        if isShellScript { runScript(); return }
        let folder = TerminalLauncher.folder(for: self)
        let title = (language ?? "shell") + " · " + self.title
        guard ScriptRunner.confirm(code, title: title, folder: folder, prefs: prefs) else { return }
        runner.run(code, title: title, in: folder)
    }

    func openInTerminal() { TerminalLauncher.open(TerminalLauncher.folder(for: self)) }

    /// Asks for a link to read, suggesting the one on the clipboard.
    func promptForLink() {
        let alert = NSAlert()
        alert.messageText = t("Abrir enlace")
        alert.informativeText = t("Un archivo Markdown o de texto en la web, un README de GitHub, un gist o un feed RSS.")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = "https://github.com/owner/repo"
        if let link = NSPasteboard.general.string(forType: .string).flatMap(WebSources.link(in:)) { field.stringValue = link.absoluteString }
        alert.accessoryView = field
        alert.addButton(withTitle: t("Abrir"))
        alert.addButton(withTitle: t("Cancelar"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty, !text.contains("://") { text = "https://" + text }
        guard let url = WebSources.link(in: text) else {
            error = t("Escribe un enlace que empiece con https://")
            return
        }
        DocumentRouter.shared.openRemote(url, from: self)
    }

    /// Reads a document from the web: Markdown or any text file behind the link, or a feed.
    func openRemote(_ url: URL) {
        guard WebSources.isWeb(url) else { return }
        guard remoteURL == url || confirmDiscard() else { return }
        isLoadingRemote = true
        Task { @MainActor in
            defer { isLoadingRemote = false }
            do {
                let page = try await WebSources.fetch(url)
                detach()
                isPastedDocument = false
                isNewNote = false
                remoteURL = page.source
                isFeed = page.isFeed
                if !prefs.alwaysLoadRemoteImages { remoteImagesAllowed = false }
                if mode == .edit { mode = .read }
                replaceSource(page.text)
                scrollRequest = ScrollRequest(id: scrollRequest.id + 1, target: .top)
            } catch {
                self.error = "\(t("No se pudo abrir")) \(url.absoluteString). \(webMessage(error))"
            }
        }
    }

    private func webMessage(_ error: Error) -> String {
        switch error {
        case WebSources.Failure.status(let code): return String(format: t("El servidor respondió %d."), code)
        case WebSources.Failure.tooLarge: return t("Elige un archivo de texto UTF-8 de hasta 5 MB.")
        case WebSources.Failure.notText: return t("El enlace no lleva a un archivo de texto.")
        default: return error.localizedDescription
        }
    }

    /// The bundled changelog, shown as a document like any other.
    @discardableResult
    func readChangelog() -> Bool {
        guard let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        guard confirmDiscard() else { return false }
        detach()
        isPastedDocument = false
        isNewNote = false
        replaceSource(text)
        isChangelog = true
        scrollRequest = ScrollRequest(id: scrollRequest.id + 1, target: .top)
        return true
    }

    @discardableResult

    func readPastedText(_ text: String) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if let link = WebSources.link(in: text) {
            showPasteEditor = false
            openRemote(link)
            return true
        }
        guard text.utf8.count <= 5_000_000 else {
            error = t("Elige un archivo de texto UTF-8 de hasta 5 MB.")
            return false
        }
        guard confirmDiscard() else { return false }
        detach()
        isNewNote = false
        isPastedDocument = true
        replaceSource(text)
        scrollRequest = ScrollRequest(id: scrollRequest.id + 1, target: .top)
        showPasteEditor = false
        return true
    }

    func readClipboard() {
        if let text = NSPasteboard.general.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            readPastedText(text)
        } else { presentPasteEditor() }
    }

    /// Dismisses the innermost sheet, popover, or tab (Command-W).
    func closeFrontmost() {
        if showPasteEditor { showPasteEditor = false; return }
        if showShortcuts { showShortcuts = false; return }
        if showDefaultAppGuide { showDefaultAppGuide = false; return }
        if showQuickSettings { showQuickSettings = false; return }
        workbench?.close(self)
    }

    /// Something (a sheet or popover) is shown on top of the document.
    var hasOverlay: Bool { showPasteEditor || showShortcuts || showDefaultAppGuide || showQuickSettings }

    // MARK: Workspace

    func openWorkspacePanel() { workbench?.openWorkspacePanel() }
    func setWorkspace(_ url: URL?) { workbench?.setWorkspace(url) }

    // MARK: Rendering

    func renderNow() {
        renderWork?.cancel()
        renderPending = false
        renderKey = currentRenderKey
        let renderer = MarkdownRenderer(size: fontSize, baseURL: (fileURL ?? remoteURL)?.deletingLastPathComponent(), accent: accentNSColor, language: resolvedLanguage)
        renderer.dark = isDark
        renderer.maxImageWidth = min(columnWidth, 1200)
        renderer.allowsRunning = remoteURL == nil
        renderer.remoteImage = { [weak self] url in self?.cachedRemoteImage(url) }
        let dark = isDark
        renderer.mermaid = { code in MermaidRenderer.shared.result(for: code, dark: dark) }
        rendered = kind.isMarkdown ? renderer.render(source) : renderer.render(file: source, kind: kind)
        renderVersion += 1
        wordCount = source.split(whereSeparator: { $0.isWhitespace }).count
        lineCount = source.isEmpty ? 0 : source.reduce(into: 1) { if $1 == "\n" { $0 += 1 } }
        if remoteImagesAllowed { loadRemoteImages() }
    }

    /// Kept for callers that still rebuild explicitly.
    func rebuild() { renderNow() }

    func editorDidChange(_ text: String) {
        source = text
        if !isDirty { isDirty = true }
        renderPending = true
        renderWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.renderNow() }
        renderWork = work
        let delay: Double = mode == .read ? 0.05 : (mode == .split ? 0.18 : 0.35)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        scheduleAutosave()
    }

    func toggleTask(at offset: Int) {
        if let document {
            document.toggleTask(at: offset)
            return
        }
        let text = source as NSString
        guard offset + 2 < text.length, text.character(at: offset) == 91 else { return }
        let checked = text.character(at: offset + 1) != 32
        editorDidChange(text.replacingCharacters(in: NSRange(location: offset + 1, length: 1), with: checked ? " " : "x"))
        renderNow()
    }

    // MARK: Saving

    private func scheduleAutosave() {
        saveWork?.cancel()
        guard fileURL != nil, !isReadOnly else { return }
        let work = DispatchWorkItem { [weak self] in _ = self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
    }

    @discardableResult
    func save() -> Bool {
        saveWork?.cancel()
        guard !kind.isReadOnly else { return true }
        // A web page is kept by saving a copy of it.
        if remoteURL != nil { return saveAs() }
        guard let fileURL else { return saveAs() }
        return write(to: fileURL)
    }

    @discardableResult
    func saveAs() -> Bool {
        let panel = NSSavePanel()
        let original = fileURL ?? (isFeed ? nil : remoteURL)
        let ext = kind.isMarkdown ? "md" : (original?.pathExtension.isEmpty == false ? original!.pathExtension : "txt")
        panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .plainText]
        panel.nameFieldStringValue = (fileURL.map { $0.deletingPathExtension().lastPathComponent } ?? (remoteURL != nil ? title : suggestedName)) + "." + ext
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        guard write(to: url) else { return false }
        isPastedDocument = false
        isNewNote = false
        fileURL = url
        remoteURL = nil
        isFeed = false
        prefs.addRecent(url)
        watch(url)
        renderNow()
        return true
    }

    private var suggestedName: String {
        let heading = outline.first?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cleaned = heading.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>")).joined()
        return cleaned.isEmpty ? t("Sin título") : String(cleaned.prefix(60))
    }

    private func write(to url: URL) -> Bool {
        do {
            try source.write(to: url, atomically: true, encoding: .utf8)
            lastWritten = source
            isDirty = false
            lastSaved = Date()
            return true
        } catch {
            self.error = "\(t("No se pudo guardar")): \(error.localizedDescription)"
            return false
        }
    }

    func reload() {
        if let remoteURL { openRemote(remoteURL); return }
        guard let url = fileURL else { return }
        if isDirty {
            let alert = NSAlert()
            alert.messageText = t("¿Descartar tus cambios y volver a cargar el archivo?")
            alert.addButton(withTitle: t("Volver a cargar"))
            alert.addButton(withTitle: t("Cancelar"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            saveWork?.cancel()
            isDirty = false
        }
        loadFromDisk(url, force: true)
    }

    private func loadFromDisk(_ url: URL, force: Bool = false) {
        do {
            let updated = try readFile(url)
            watch(url)
            if !force && (updated == lastWritten || updated == source || isDirty) { return }
            lastWritten = updated
            let top = currentHeading
            let following = kind == .log && followsEnd
            source = updated
            contentVersion += 1
            didReplaceDocument = false
            renderNow()
            currentHeading = top
            if following { scrollRequest = ScrollRequest(id: scrollRequest.id + 1, target: .bottom) }
        } catch { self.error = "\(t("No se pudo actualizar el documento.")) \(errorMessage(error))" }
    }

    private func errorMessage(_ error: Error) -> String {
        if error is ReaderError { return t("Elige un archivo de texto UTF-8 de hasta 5 MB.") }
        return error.localizedDescription
    }

    private func watch(_ url: URL) {
        watcher?.cancel()
        let fd = Darwin.open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            self?.reloadWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, let current = self.fileURL else { return }
                self.loadFromDisk(current)
            }
            self?.reloadWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
        source.setCancelHandler { Darwin.close(fd) }
        watcher = source
        source.resume()
    }

    // MARK: Modes and navigation

    func setMode(_ new: DocumentMode) {
        var new = new
        // Code and data have no live Markdown editor; logs are only read.
        if kind.isReadOnly { new = .read } else if !kind.isMarkdown || remoteURL != nil, new == .edit { new = .source }
        guard mode != new else { return }
        mode = new
    }

    /// Focus mode hides everything but the text; the same command brings it all back.
    func toggleFocus() {
        withAnimation(.snappy(duration: 0.28)) {
            if !focusMode, mode == .split { mode = .read }
            focusMode.toggle()
        }
    }

    func toggleEditing() {
        if !kind.isMarkdown { setMode(mode == .read ? .source : .read); return }
        setMode(mode == .edit || mode == .source ? .read : lastEditMode)
    }

    func format(_ action: FormatAction) {
        guard kind.isMarkdown else { return }
        if mode == .read { mode = .edit }
        DispatchQueue.main.async { [weak self] in self?.document?.perform(action) }
    }

    func find(_ action: NSTextFinder.Action) {
        if action == .showFindInterface { findRequest += 1 } else { document?.find(action) }
    }

    func zoom(_ delta: Double) {
        fontSize = min(28, max(12, fontSize + delta))
    }

    func resetZoom() {
        fontSize = 17
    }

    func navigate(_ item: OutlineItem) {
        currentHeading = item.id
        scrollRequest = ScrollRequest(id: scrollRequest.id + 1, target: .heading(item))
    }

    func navigateRelative(_ delta: Int) {
        guard !outline.isEmpty else { return }
        let index = currentHeading.flatMap { id in outline.firstIndex { $0.id == id } } ?? (delta > 0 ? -1 : outline.count)
        let target = min(outline.count - 1, max(0, index + delta))
        navigate(outline[target])
    }

    func setCurrentHeading(_ id: Int?, progress: Double) {
        currentHeading = id
        let percent = Int((progress * 100).rounded())
        if progressTracker.percent != percent { progressTracker.percent = percent }
    }

    /// Handles links clicked in the document. Returns true when MD Lite handled it.
    @discardableResult
    func follow(_ url: URL) -> Bool {
        if url.scheme == "x-mdlite-anchor" {
            let anchor = (url.absoluteString.dropFirst("x-mdlite-anchor:".count).removingPercentEncoding ?? "").lowercased()
            if let item = outline.first(where: { $0.anchor == anchor || GFM.slug($0.title) == anchor }) { navigate(item) }
            return true
        }
        if url.isFileURL, FileTypes.isSupported(url) {
            DocumentRouter.shared.open(url, from: self)
            return true
        }
        // A link from a web document to another Markdown file stays in MD Lite.
        if WebSources.isWeb(url), FileTypes.kind(of: url) == .markdown {
            DocumentRouter.shared.openRemote(url, from: self)
            return true
        }
        NSWorkspace.shared.open(url)
        return true
    }

    // MARK: Remote images

    func cachedRemoteImage(_ url: URL) -> NSImage? { remoteImagesAllowed ? remoteCache[url] : nil }

    func allowRemoteImages() {
        remoteImagesAllowed = true
        loadRemoteImages()
        renderNow()
    }

    private func loadRemoteImages() {
        let pending = rendered.remoteImages.filter { remoteCache[$0] == nil && !remoteLoading.contains($0) }
        guard !pending.isEmpty else { return }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: configuration)
        for url in pending.prefix(60) {
            remoteLoading.insert(url)
            Task { [weak self] in
                let data = try? await session.data(from: url).0
                await MainActor.run {
                    guard let self else { return }
                    self.remoteLoading.remove(url)
                    if let data, data.count < 15_000_000, let image = NSImage(data: data) { self.remoteCache[url] = image }
                    if self.remoteLoading.isEmpty { self.renderNow() }
                }
            }
        }
    }

    var blockedRemoteImages: Int { remoteImagesAllowed ? 0 : rendered.remoteImages.count }
}

private enum ReaderError: LocalizedError {
    case tooLarge
    var errorDescription: String? { "Elige un archivo de texto UTF-8 de hasta 5 MB." }
}

let welcomeMarkdown = """
# Un espacio para tus ideas.

Menos interfaz. Más claridad. **MD Lite** lee y edita Markdown en una experiencia tranquila, precisa y completamente nativa.

> [!TIP]
> Pulsa **⌘E** para editar este mismo texto y **⌘/** para ver todos los atajos.

## Tres formas de ver

| Modo | Atajo | Para qué |
| --- | :---: | --- |
| Lectura | ⌘1 | Leer el documento terminado |
| Editor | ⌘2 | Escribir con el formato a la vista |
| Código | ⌘3 | Ver y editar el Markdown puro |
| Dividida | ⌘4 | Código y lectura lado a lado |

En el editor, las marcas como `**` o `#` aparecen solo en la línea donde escribes. **⌘Z** deshace y **⇧⌘Z** rehace.

## Lo esencial, bien hecho

- [x] Abre un archivo con **⌘O** o arrástralo a la ventana.
- [x] Guarda con **⌘S**; los archivos abiertos se guardan solos.
- [x] Abre una carpeta con **⇧⌘O** y cada documento en su pestaña (**⌘T**).
- [ ] Marca esta tarea con un clic.

### Código que se lee bien

```swift
struct Idea: View {
    var body: some View {
        Text("Menos, pero mejor.")
    }
}
```

### Diagramas

```mermaid
flowchart LR
    Idea --> Escribir --> Leer
```

## Hecho para tu Mac

SwiftUI en la superficie. TextKit en cada línea. Sin cuentas, sin servicios y sin distracciones. Consulta la [guía de Markdown](https://www.markdownguide.org/basic-syntax/) o la especificación [GFM](https://github.github.com/gfm/).

---

**Abierto por naturaleza.** Código abierto bajo licencia MIT.
"""

let welcomeMarkdownEnglish = """
# A little space for your ideas.

Less interface. More clarity. **MD Lite** reads and edits Markdown in a calm, precise, and entirely native experience.

> [!TIP]
> Press **⌘E** to edit this very text and **⌘/** to see every shortcut.

## Three ways to look

| Mode | Shortcut | What for |
| --- | :---: | --- |
| Reading | ⌘1 | Read the finished document |
| Editor | ⌘2 | Write with formatting in view |
| Source | ⌘3 | See and edit plain Markdown |
| Split | ⌘4 | Source and reading side by side |

In the editor, markers such as `**` or `#` appear only on the line you are typing. **⌘Z** undoes and **⇧⌘Z** redoes.

## The essentials, done well

- [x] Open a file with **⌘O** or drop it into the window.
- [x] Save with **⌘S**; open files save themselves.
- [x] Open a folder with **⇧⌘O** and each document in its own tab (**⌘T**).
- [ ] Check this task with a click.

### Code that reads well

```swift
struct Idea: View {
    var body: some View {
        Text("Less, but better.")
    }
}
```

### Diagrams

```mermaid
flowchart LR
    Idea --> Write --> Read
```

## Made for your Mac

SwiftUI on the surface. TextKit in every line. No accounts, no services, no distractions. Explore the [Markdown guide](https://www.markdownguide.org/basic-syntax/) or the [GFM spec](https://github.github.com/gfm/).

---

**Open by nature.** Open source under the MIT license.
"""
