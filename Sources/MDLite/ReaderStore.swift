import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ReaderStore: ObservableObject {
    static let shared = ReaderStore()
    @Published var source = welcomeMarkdown
    @Published var fileURL: URL?
    @Published var isPastedDocument = false
    @Published var showPasteEditor = false
    @Published var pasteDraft = ""
    @Published var showNoteEditor = false
    @Published var noteDraft = ""
    var isWelcome: Bool { fileURL == nil && !isPastedDocument }
    @Published var rendered = RenderedDocument(text: NSAttributedString(), outline: [])
    @Published var recent: [URL] = []
    @Published var error: String?
    @Published var showSource = false { didSet { rebuild() } }
    @Published var focusMode = false
    @Published var selectedHeading: Int?
    @Published var scrollTarget: NSRange?
    @Published var findRequest = 0
    @AppStorage("fontSize") var fontSize: Double = 17
    @Published var appearance = UserDefaults.standard.string(forKey: "appearance") ?? "system" {
        didSet { UserDefaults.standard.set(appearance, forKey: "appearance") }
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
            rebuild()
        }
    }
    @Published private var systemLanguage = ReaderLanguage.resolve("system")
    var resolvedLanguage: String { language == "system" ? systemLanguage : ReaderLanguage.resolve(language) }
    var accentNSColor: NSColor { (AccentChoice(rawValue: accent) ?? .system).color }
    var accentColor: Color { Color(nsColor: accentNSColor) }
    func t(_ key: String) -> String { ReaderLanguage.text(key, language: resolvedLanguage) }
    private var localeObserver: NSObjectProtocol?

    private func updateLanguage() {
        if isWelcome {
            source = resolvedLanguage == "es" ? welcomeMarkdown : welcomeMarkdownEnglish
            selectedHeading = nil
        }
        rebuild()
    }
    private var watcher: DispatchSourceFileSystemObject?
    private var reloadWork: DispatchWorkItem?

    var title: String { fileURL?.deletingPathExtension().lastPathComponent ?? t(isPastedDocument ? "Texto pegado" : "Bienvenido") }
    var wordCount: Int { source.split(whereSeparator: { $0.isWhitespace }).count }
    var readingMinutes: Int { max(1, Int(ceil(Double(wordCount) / 220))) }

    init() {
        recent = (UserDefaults.standard.stringArray(forKey: "recentFiles") ?? []).map { URL(fileURLWithPath: $0) }
        updateLanguage()
        localeObserver = NotificationCenter.default.addObserver(forName: NSLocale.currentLocaleDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.systemLanguage = ReaderLanguage.resolve("system")
                self?.updateLanguage()
            }
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
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= 5_000_000 else {
                throw ReaderError.tooLarge
            }
            let text = try String(contentsOf: url, encoding: .utf8)
            reloadWork?.cancel()
            isPastedDocument = false
            source = text
            fileURL = url
            selectedHeading = nil
            showSource = false
            rebuild()
            scrollTarget = NSRange(location: 0, length: 0)
            recent.removeAll { $0 == url }
            recent.insert(url, at: 0)
            recent = Array(recent.prefix(12))
            UserDefaults.standard.set(recent.map(\.path), forKey: "recentFiles")
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            watch(url)
        } catch { self.error = "\(t("No se pudo abrir")) \(url.lastPathComponent). \(errorMessage(error))" }
    }

    func welcome() {
        watcher?.cancel()
        watcher = nil
        reloadWork?.cancel()
        fileURL = nil
        isPastedDocument = false
        source = resolvedLanguage == "es" ? welcomeMarkdown : welcomeMarkdownEnglish
        selectedHeading = nil
        showSource = false
        rebuild()
        scrollTarget = NSRange(location: 0, length: 0)
    }

    func presentPasteEditor() {
        pasteDraft = isPastedDocument ? source : ""
        showPasteEditor = true
    }

    func newNote() {
        noteDraft = "# " + t("Nueva nota") + "\n\n"
        showNoteEditor = true
    }

    func saveNote(_ text: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "note.md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            showNoteEditor = false
            open(url)
        } catch {
            self.error = "\(t("No se pudo guardar")): \(error.localizedDescription)"
        }
    }

    @discardableResult
    func readPastedText(_ text: String) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard text.utf8.count <= 5_000_000 else {
            error = t("Elige un archivo de texto UTF-8 de hasta 5 MB.")
            return false
        }
        reloadWork?.cancel()
        watcher?.cancel()
        watcher = nil
        fileURL = nil
        isPastedDocument = true
        source = text
        selectedHeading = nil
        showSource = false
        rebuild()
        scrollTarget = NSRange(location: 0, length: 0)
        showPasteEditor = false
        return true
    }

    func readClipboard() {
        if let text = NSPasteboard.general.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            readPastedText(text)
        } else { presentPasteEditor() }
    }

    func rebuild() {
        if showSource {
            rendered = RenderedDocument(text: NSAttributedString(string: source, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: fontSize * 0.85, weight: .regular),
                .foregroundColor: NSColor.labelColor
            ]), outline: rendered.outline)
        } else {
            rendered = MarkdownRenderer(size: fontSize, baseURL: fileURL?.deletingLastPathComponent(), accent: accentNSColor, language: resolvedLanguage).render(source)
        }
    }

    func zoom(_ delta: Double) {
        fontSize = min(28, max(12, fontSize + delta))
        rebuild()
    }

    func navigate(_ item: OutlineItem) {
        if showSource { showSource = false }
        selectedHeading = item.id
        scrollTarget = item.range
    }

    func reload() {
        guard let url = fileURL else { return }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
            guard size <= 5_000_000 else { throw ReaderError.tooLarge }
            let updated = try String(contentsOf: url, encoding: .utf8)
            if updated != source {
                source = updated
                selectedHeading = nil
                rebuild()
            }
            watch(url)
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
            let work = DispatchWorkItem { [weak self] in self?.reload() }
            self?.reloadWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
        source.setCancelHandler { Darwin.close(fd) }
        watcher = source
        source.resume()
    }
}

private enum ReaderError: LocalizedError {
    case tooLarge
    var errorDescription: String? { "Elige un archivo de texto UTF-8 de hasta 5 MB." }
}

let welcomeMarkdown = """
# Un espacio para tus ideas.

Menos interfaz. Más claridad. **MD Lite** convierte tus archivos Markdown en una experiencia de lectura tranquila, precisa y completamente nativa.

## Lo esencial, bien hecho

Abre un archivo con **⌘O**, arrástralo a la ventana o elígelo desde Finder. Tus documentos permanecen en tu Mac, justo donde los guardaste.

- Tipografía que deja respirar a cada palabra.
- Un índice para encontrar el hilo de tus ideas.
- Modo enfoque para quedarte con lo importante.
- Actualización automática cuando guardas cambios en tu editor.

> La simplicidad consiste en dejar espacio para lo que importa.

## De texto a pensamiento

Markdown es texto sencillo con intención. Usa **negrita**, *cursiva*, enlaces y `código` sin perder la naturalidad de escribir.

### Una pequeña muestra

```swift
import SwiftUI

struct Idea: View {
    var body: some View {
        Text("Menos, pero mejor.")
    }
}
```

1. Abre ese documento que quieres leer.
2. Encuentra tu tamaño de letra ideal con ⌘+ y ⌘−.
3. Activa el modo enfoque con ⇧⌘F.

## Hecho para tu Mac

SwiftUI en la superficie. TextKit en cada línea. Un lector local, sin cuentas, sin servicios y sin distracciones.

Consulta la [guía de Markdown](https://www.markdownguide.org/basic-syntax/) para explorar su sintaxis.

---

**Abierto por naturaleza.** Código abierto bajo licencia MIT.
"""


let welcomeMarkdownEnglish = """
# A little space for your ideas.

Less interface. More clarity. **MD Lite** turns your Markdown files into a calm, precise, and entirely native reading experience.

## The essentials, done well

Open a file with **⌘O**, drag it into the window, or choose it in Finder. Your documents stay on your Mac, right where you saved them.

- Typography that gives every word room to breathe.
- An outline to follow the thread of your ideas.
- Focus mode to stay with what matters.
- Automatic refresh when you save changes in your editor.

> Simplicity means making room for what matters.

## From text to thought

Markdown is plain text with intention. Use **bold**, *italic*, links, and `code` without losing the natural flow of writing.

### A small example

```swift
import SwiftUI

struct Idea: View {
    var body: some View {
        Text("Less, but better.")
    }
}
```

1. Open the document you want to read.
2. Find your ideal text size with ⌘+ and ⌘−.
3. Enter focus mode with ⇧⌘F.

## Made for your Mac

SwiftUI on the surface. TextKit in every line. A local reader, without accounts, services, or distractions.

Explore the [Markdown guide](https://www.markdownguide.org/basic-syntax/) to learn the syntax.

---

**Open by nature.** Open source under the MIT license.
"""
