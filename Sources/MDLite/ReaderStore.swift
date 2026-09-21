import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum ScrollTarget: Equatable {
    case none, top
    case heading(OutlineItem)
}

struct ScrollRequest: Equatable {
    var id = 0
    var target: ScrollTarget = .none
}

struct DefaultAppStatus: Equatable {
    var isDefault: Bool?
    var currentName: String?
    var currentURL: URL?
}

@MainActor
final class ReaderStore: ObservableObject {
    static let shared = ReaderStore()

    /// Markdown source of the open document. Not published: the editor owns typing.
    private(set) var source = welcomeMarkdown
    @Published var fileURL: URL?
    @Published var isPastedDocument = false
    @Published var isNewNote = false
    @Published var showPasteEditor = false
    @Published var pasteDraft = ""
    var isWelcome: Bool { fileURL == nil && !isPastedDocument && !isNewNote }
    @Published private(set) var rendered = RenderedDocument(text: NSAttributedString(), outline: [])
    @Published private(set) var renderVersion = 0
    @Published private(set) var contentVersion = 0
    var didReplaceDocument = true
    @Published var recent: [URL] = []
    @Published var error: String?
    @Published var mode: DocumentMode = .read {
        didSet {
            if mode != .read { lastEditMode = mode }
            if mode == .read, renderPending { renderNow() }
        }
    }
    private var lastEditMode: DocumentMode = .edit
    @Published var sidebarVisible = UserDefaults.standard.object(forKey: "sidebarVisible") as? Bool ?? true {
        didSet { UserDefaults.standard.set(sidebarVisible, forKey: "sidebarVisible") }
    }
    @Published var focusMode = false
    @Published private(set) var currentHeading: Int?
    @Published private(set) var progress: Double = 0
    @Published var scrollRequest = ScrollRequest()
    @Published var findRequest = 0
    @Published private(set) var isDirty = false
    @Published private(set) var lastSaved: Date?
    @Published private(set) var wordCount = 0
    @Published var showShortcuts = false
    @Published var showDefaultAppGuide = false
    @Published private(set) var defaultApp = DefaultAppStatus()
    @Published private(set) var remoteImagesAllowed = UserDefaults.standard.bool(forKey: "alwaysLoadRemoteImages")
    @Published var alwaysLoadRemoteImages = UserDefaults.standard.bool(forKey: "alwaysLoadRemoteImages") {
        didSet {
            UserDefaults.standard.set(alwaysLoadRemoteImages, forKey: "alwaysLoadRemoteImages")
            if alwaysLoadRemoteImages { allowRemoteImages() }
        }
    }
    @Published var checkForUpdatesAutomatically = UserDefaults.standard.bool(forKey: "checkForUpdates") {
        didSet { UserDefaults.standard.set(checkForUpdatesAutomatically, forKey: "checkForUpdates") }
    }
    @Published var textWidth = UserDefaults.standard.string(forKey: "textWidth") ?? "normal" {
        didSet { UserDefaults.standard.set(textWidth, forKey: "textWidth") }
    }
    @Published private(set) var isDark = false
    @Published var fontSize: Double = UserDefaults.standard.object(forKey: "fontSize") as? Double ?? 17 {
        didSet { UserDefaults.standard.set(fontSize, forKey: "fontSize") }
    }
    @Published var appearance = UserDefaults.standard.string(forKey: "appearance") ?? "system" {
        didSet {
            UserDefaults.standard.set(appearance, forKey: "appearance")
            applyWindowAppearance()
        }
    }
    @Published var language = UserDefaults.standard.string(forKey: "language") ?? "system" {
        didSet {
            UserDefaults.standard.set(language, forKey: "language")
            updateLanguage()
        }
    }
    @Published var accent = UserDefaults.standard.string(forKey: "accent") ?? "system" {
        didSet {
            UserDefaults.standard.set(accent, forKey: "accent")
            renderNow()
        }
    }
    @Published private var systemLanguage = ReaderLanguage.resolve("system")
    var resolvedLanguage: String { language == "system" ? systemLanguage : ReaderLanguage.resolve(language) }
    var accentNSColor: NSColor { (AccentChoice(rawValue: accent) ?? .system).color }
    var accentColor: Color { Color(nsColor: accentNSColor) }
    func t(_ key: String) -> String { ReaderLanguage.text(key, language: resolvedLanguage) }

    weak var document: DocumentEditing?
    private var localeObserver: NSObjectProtocol?
    private var watcher: DispatchSourceFileSystemObject?
    private var reloadWork: DispatchWorkItem?
    private var renderWork: DispatchWorkItem?
    private var saveWork: DispatchWorkItem?
    private var renderPending = false
    private var lastWritten: String?
    private var remoteCache: [URL: NSImage] = [:]
    private var remoteLoading = Set<URL>()

    var title: String {
        if let fileURL { return fileURL.deletingPathExtension().lastPathComponent }
        if isNewNote { return t("Nueva nota") }
        return t(isPastedDocument ? "Texto pegado" : "Bienvenido")
    }
    var readingMinutes: Int { max(1, Int(ceil(Double(wordCount) / 220))) }
    var columnWidth: CGFloat {
        switch textWidth {
        case "narrow": return 620
        case "wide": return 980
        case "full": return 100_000
        default: return 780
        }
    }
    var outline: [OutlineItem] { rendered.outline }

    init() {
        recent = (UserDefaults.standard.stringArray(forKey: "recentFiles") ?? []).map { URL(fileURLWithPath: $0) }
        MermaidRenderer.shared.onUpdate = { [weak self] in self?.renderNow() }
        updateLanguage()
        localeObserver = NotificationCenter.default.addObserver(forName: NSLocale.currentLocaleDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.systemLanguage = ReaderLanguage.resolve("system")
                self?.updateLanguage()
            }
        }
    }

    private func applyWindowAppearance() {
        let requested: NSAppearance?
        switch appearance {
        case "dark": requested = NSAppearance(named: .darkAqua)
        case "light": requested = NSAppearance(named: .aqua)
        default: requested = nil
        }
        DispatchQueue.main.async { NSApp?.windows.forEach { $0.appearance = requested } }
    }

    func setDarkAppearance(_ dark: Bool) {
        guard dark != isDark else { return }
        isDark = dark
        renderNow()
    }

    private func updateLanguage() {
        if isWelcome, !isDirty {
            replaceSource(resolvedLanguage == "es" ? welcomeMarkdown : welcomeMarkdownEnglish)
        } else {
            renderNow()
        }
    }

    // MARK: Documents

    private func replaceSource(_ text: String) {
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
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText,
                                     UTType(filenameExtension: "markdown") ?? .plainText, .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    func open(_ url: URL) {
        guard url != fileURL || !isDirty else { return }
        guard confirmDiscard() else { return }
        do {
            let text = try readFile(url)
            reloadWork?.cancel()
            isPastedDocument = false
            isNewNote = false
            fileURL = url
            lastWritten = text
            if !alwaysLoadRemoteImages { remoteImagesAllowed = false }
            replaceSource(text)
            scrollRequest = ScrollRequest(id: scrollRequest.id + 1, target: .top)
            recent.removeAll { $0 == url }
            recent.insert(url, at: 0)
            recent = Array(recent.prefix(12))
            UserDefaults.standard.set(recent.map(\.path), forKey: "recentFiles")
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            watch(url)
        } catch { self.error = "\(t("No se pudo abrir")) \(url.lastPathComponent). \(errorMessage(error))" }
    }

    private func readFile(_ url: URL) throws -> String {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= 5_000_000 else { throw ReaderError.tooLarge }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func detach() {
        watcher?.cancel()
        watcher = nil
        reloadWork?.cancel()
        fileURL = nil
        lastWritten = nil
    }

    func welcome() {
        guard confirmDiscard() else { return }
        detach()
        isPastedDocument = false
        isNewNote = false
        mode = .read
        replaceSource(resolvedLanguage == "es" ? welcomeMarkdown : welcomeMarkdownEnglish)
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

    @discardableResult
    func readPastedText(_ text: String) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
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

    // MARK: Rendering

    func renderNow() {
        renderWork?.cancel()
        renderPending = false
        let renderer = MarkdownRenderer(size: fontSize, baseURL: fileURL?.deletingLastPathComponent(), accent: accentNSColor, language: resolvedLanguage)
        renderer.dark = isDark
        renderer.maxImageWidth = min(columnWidth, 1200)
        renderer.remoteImage = { [weak self] url in self?.cachedRemoteImage(url) }
        renderer.mermaid = { [weak self] code in MermaidRenderer.shared.result(for: code, dark: self?.isDark ?? false) }
        rendered = renderer.render(source)
        renderVersion += 1
        wordCount = source.split(whereSeparator: { $0.isWhitespace }).count
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
        DispatchQueue.main.asyncAfter(deadline: .now() + (mode == .read ? 0.05 : 0.35), execute: work)
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
        guard fileURL != nil else { return }
        let work = DispatchWorkItem { [weak self] in _ = self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
    }

    @discardableResult
    func save() -> Bool {
        saveWork?.cancel()
        guard let fileURL else { return saveAs() }
        return write(to: fileURL)
    }

    @discardableResult
    func saveAs() -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = (fileURL?.deletingPathExtension().lastPathComponent ?? suggestedName) + ".md"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        guard write(to: url) else { return false }
        isPastedDocument = false
        isNewNote = false
        fileURL = url
        recent.removeAll { $0 == url }
        recent.insert(url, at: 0)
        UserDefaults.standard.set(recent.map(\.path), forKey: "recentFiles")
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
            source = updated
            contentVersion += 1
            didReplaceDocument = false
            renderNow()
            currentHeading = top
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
        guard mode != new else { return }
        mode = new
    }

    func toggleEditing() { setMode(mode == .read ? lastEditMode : .read) }

    func format(_ action: FormatAction) {
        if mode == .read { mode = .edit }
        DispatchQueue.main.async { [weak self] in self?.document?.perform(action) }
    }

    func find(_ action: NSTextFinder.Action) {
        if action == .showFindInterface { findRequest += 1 } else { document?.find(action) }
    }

    func zoom(_ delta: Double) {
        fontSize = min(28, max(12, fontSize + delta))
        renderNow()
    }

    func resetZoom() {
        fontSize = 17
        renderNow()
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
        if currentHeading != id { currentHeading = id }
        if abs(self.progress - progress) > 0.004 { self.progress = progress }
    }

    /// Handles links clicked in the document. Returns true when MD Lite handled it.
    @discardableResult
    func follow(_ url: URL) -> Bool {
        if url.scheme == "x-mdlite-anchor" {
            let anchor = (url.absoluteString.dropFirst("x-mdlite-anchor:".count).removingPercentEncoding ?? "").lowercased()
            if let item = outline.first(where: { $0.anchor == anchor || GFM.slug($0.title) == anchor }) { navigate(item) }
            return true
        }
        if url.isFileURL, ["md", "markdown", "mdown", "mkd"].contains(url.pathExtension.lowercased()) {
            open(url)
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

    // MARK: Default Markdown app

    func refreshDefaultApp() {
        guard let type = UTType(filenameExtension: "md") else { return }
        let url = NSWorkspace.shared.urlForApplication(toOpen: type)
        let isDefault = url.map { Bundle(url: $0)?.bundleIdentifier == Bundle.main.bundleIdentifier && Bundle.main.bundleIdentifier != nil }
        let name = url.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
        defaultApp = DefaultAppStatus(isDefault: isDefault ?? false, currentName: name, currentURL: url)
    }

    func makeDefaultMarkdownApp() {
        let applicationURL = Bundle.main.bundleURL
        let types = [UTType(filenameExtension: "md"), UTType(filenameExtension: "markdown")].compactMap { $0 }
        for type in types {
            NSWorkspace.shared.setDefaultApplication(at: applicationURL, toOpen: type) { [weak self] error in
                Task { @MainActor in
                    if let error { self?.error = "\(self?.t("No se pudo asociar Markdown") ?? "Unable to associate Markdown"): \(error.localizedDescription)" }
                    self?.refreshDefaultApp()
                }
            }
        }
    }
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

En el editor, las marcas como `**` o `#` aparecen solo en la línea donde escribes. **⌘Z** deshace y **⇧⌘Z** rehace.

## Lo esencial, bien hecho

- [x] Abre un archivo con **⌘O** o arrástralo a la ventana.
- [x] Guarda con **⌘S**; los archivos abiertos se guardan solos.
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

In the editor, markers such as `**` or `#` appear only on the line you are typing. **⌘Z** undoes and **⇧⌘Z** redoes.

## The essentials, done well

- [x] Open a file with **⌘O** or drop it into the window.
- [x] Save with **⌘S**; open files save themselves.
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
