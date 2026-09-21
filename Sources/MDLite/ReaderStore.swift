import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ReaderStore: ObservableObject {
    static let shared = ReaderStore()
    @Published var source = welcomeMarkdown
    @Published var fileURL: URL?
    @Published var rendered = RenderedDocument(text: NSAttributedString(), outline: [])
    @Published var recent: [URL] = []
    @Published var error: String?
    @Published var showSource = false { didSet { rebuild() } }
    @Published var focusMode = false
    @Published var selectedHeading: Int?
    @Published var scrollTarget: NSRange?
    @Published var findRequest = 0
    @AppStorage("fontSize") var fontSize: Double = 17
    @AppStorage("appearance") var appearance = "system"
    private var watcher: DispatchSourceFileSystemObject?
    private var reloadWork: DispatchWorkItem?

    var title: String { fileURL?.deletingPathExtension().lastPathComponent ?? "Bienvenido" }
    var wordCount: Int { source.split(whereSeparator: { $0.isWhitespace }).count }
    var readingMinutes: Int { max(1, Int(ceil(Double(wordCount) / 220))) }

    init() {
        recent = (UserDefaults.standard.stringArray(forKey: "recentFiles") ?? []).map { URL(fileURLWithPath: $0) }
        rebuild()
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
        } catch { self.error = "No se pudo abrir \(url.lastPathComponent). \(error.localizedDescription)" }
    }

    func welcome() {
        watcher?.cancel()
        watcher = nil
        reloadWork?.cancel()
        fileURL = nil
        source = welcomeMarkdown
        selectedHeading = nil
        showSource = false
        rebuild()
        scrollTarget = NSRange(location: 0, length: 0)
    }

    func rebuild() {
        if showSource {
            rendered = RenderedDocument(text: NSAttributedString(string: source, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: fontSize * 0.85, weight: .regular),
                .foregroundColor: NSColor.labelColor
            ]), outline: rendered.outline)
        } else {
            rendered = MarkdownRenderer(size: fontSize, baseURL: fileURL?.deletingLastPathComponent()).render(source)
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
        } catch { self.error = "No se pudo actualizar el documento. \(error.localizedDescription)" }
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
