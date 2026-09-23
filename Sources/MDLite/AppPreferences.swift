import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DefaultAppStatus: Equatable {
    var isDefault: Bool?
    var currentName: String?
    var currentURL: URL?
}

/// Settings shared by every window and tab. Persisted in UserDefaults.
@MainActor
final class AppPreferences: ObservableObject {
    static let shared = AppPreferences()
    private let defaults = UserDefaults.standard

    @Published var appearance: String { didSet { defaults.set(appearance, forKey: "appearance"); applyWindowAppearance() } }
    @Published var language: String { didSet { defaults.set(language, forKey: "language") } }
    @Published var accent: String { didSet { defaults.set(accent, forKey: "accent") } }
    @Published var fontSize: Double { didSet { defaults.set(fontSize, forKey: "fontSize") } }
    @Published var textWidth: String { didSet { defaults.set(textWidth, forKey: "textWidth") } }
    @Published var sidebarVisible: Bool { didSet { defaults.set(sidebarVisible, forKey: "sidebarVisible") } }
    @Published var alwaysLoadRemoteImages: Bool { didSet { defaults.set(alwaysLoadRemoteImages, forKey: "alwaysLoadRemoteImages") } }
    /// Check, download and install updates on their own.
    @Published var automaticUpdates: Bool { didSet { defaults.set(automaticUpdates, forKey: "automaticUpdates") } }
    @Published private(set) var recent: [URL]
    @Published private(set) var favorites: [URL]
    /// Bumped when a Finder tag changes so rows showing tags refresh.
    @Published private(set) var tagVersion = 0
    @Published private(set) var defaultApp = DefaultAppStatus()
    @Published private var systemLanguage = ReaderLanguage.resolve("system")
    private var localeObserver: NSObjectProtocol?

    init() {
        appearance = defaults.string(forKey: "appearance") ?? "system"
        language = defaults.string(forKey: "language") ?? "system"
        accent = defaults.string(forKey: "accent") ?? "system"
        fontSize = defaults.object(forKey: "fontSize") as? Double ?? 17
        textWidth = defaults.string(forKey: "textWidth") ?? "normal"
        sidebarVisible = defaults.object(forKey: "sidebarVisible") as? Bool ?? true
        alwaysLoadRemoteImages = defaults.bool(forKey: "alwaysLoadRemoteImages")
        automaticUpdates = defaults.object(forKey: "automaticUpdates") as? Bool ?? defaults.object(forKey: "checkForUpdates") as? Bool ?? true
        recent = (defaults.stringArray(forKey: "recentFiles") ?? []).map { URL(fileURLWithPath: $0) }
        favorites = (defaults.stringArray(forKey: "favoriteFiles") ?? []).map { URL(fileURLWithPath: $0) }
        localeObserver = NotificationCenter.default.addObserver(forName: NSLocale.currentLocaleDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.systemLanguage = ReaderLanguage.resolve("system") }
        }
    }

    var resolvedLanguage: String { language == "system" ? systemLanguage : ReaderLanguage.resolve(language) }
    var accentNSColor: NSColor { (AccentChoice(rawValue: accent) ?? .system).color }
    var accentColor: Color { Color(nsColor: accentNSColor) }
    var colorScheme: ColorScheme? { appearance == "dark" ? .dark : appearance == "light" ? .light : nil }
    func t(_ key: String) -> String { ReaderLanguage.text(key, language: resolvedLanguage) }

    var columnWidth: CGFloat {
        switch textWidth {
        case "narrow": return 620
        case "wide": return 980
        case "full": return 100_000
        default: return 780
        }
    }

    func applyWindowAppearance() {
        let requested: NSAppearance?
        switch appearance {
        case "dark": requested = NSAppearance(named: .darkAqua)
        case "light": requested = NSAppearance(named: .aqua)
        default: requested = nil
        }
        DispatchQueue.main.async { NSApp?.windows.forEach { $0.appearance = requested } }
    }

    func addRecent(_ url: URL) {
        var list = recent.filter { $0 != url }
        list.insert(url, at: 0)
        recent = Array(list.prefix(12))
        defaults.set(recent.map(\.path), forKey: "recentFiles")
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    func removeRecent(_ url: URL) {
        recent.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
        defaults.set(recent.map(\.path), forKey: "recentFiles")
    }

    func clearRecent() {
        recent = []
        defaults.set([String](), forKey: "recentFiles")
        NSDocumentController.shared.clearRecentDocuments(nil)
    }

    // MARK: Favorites and Finder tags

    func isFavorite(_ url: URL) -> Bool { favorites.contains { $0.standardizedFileURL == url.standardizedFileURL } }

    func toggleFavorite(_ url: URL) {
        if isFavorite(url) { favorites.removeAll { $0.standardizedFileURL == url.standardizedFileURL } }
        else { favorites.append(url) }
        defaults.set(favorites.map(\.path), forKey: "favoriteFiles")
    }

    /// Finder's color tags, in Finder's order and language.
    var colorTags: [(name: String, color: NSColor)] {
        Array(zip(NSWorkspace.shared.fileLabels, NSWorkspace.shared.fileLabelColors).dropFirst()).map { ($0.0, $0.1) }
    }

    private var tagCache: [String: [String]] = [:]

    func tags(of url: URL) -> [String] {
        if let cached = tagCache[url.path] { return cached }
        var fresh = url
        fresh.removeAllCachedResourceValues()
        let tags = (try? fresh.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
        tagCache[url.path] = tags
        return tags
    }

    /// Tags may change in Finder while MD Lite is in the background.
    func forgetCachedTags() {
        tagCache.removeAll()
        tagVersion += 1
    }

    func color(forTag name: String) -> NSColor? { colorTags.first { $0.name == name }?.color }

    func toggleTag(_ name: String, on url: URL) {
        var tags = tags(of: url)
        if let index = tags.firstIndex(of: name) { tags.remove(at: index) } else { tags.append(name) }
        setTags(tags, on: url)
    }

    func setTags(_ tags: [String], on url: URL) {
        try? (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
        tagCache[url.path] = nil
        tagVersion += 1
    }

    /// Asks for a custom tag name and adds it to the file.
    func addCustomTag(to url: URL) {
        let alert = NSAlert()
        alert.messageText = t("Nueva etiqueta")
        alert.informativeText = url.lastPathComponent
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = t("Nombre de la etiqueta")
        alert.accessoryView = field
        alert.addButton(withTitle: t("Añadir"))
        alert.addButton(withTitle: t("Cancelar"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !tags(of: url).contains(name) else { return }
        setTags(tags(of: url) + [name], on: url)
    }

    // MARK: Default Markdown app

    func refreshDefaultApp() {
        guard let type = UTType(filenameExtension: "md") else { return }
        let url = NSWorkspace.shared.urlForApplication(toOpen: type)
        let isDefault = url.map { Bundle(url: $0)?.bundleIdentifier == Bundle.main.bundleIdentifier && Bundle.main.bundleIdentifier != nil }
        let name = url.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
        defaultApp = DefaultAppStatus(isDefault: isDefault ?? false, currentName: name, currentURL: url)
    }

    func makeDefaultMarkdownApp(onError: @escaping (String) -> Void) {
        let applicationURL = Bundle.main.bundleURL
        let types = [UTType(filenameExtension: "md"), UTType(filenameExtension: "markdown")].compactMap { $0 }
        for type in types {
            NSWorkspace.shared.setDefaultApplication(at: applicationURL, toOpen: type) { [weak self] error in
                Task { @MainActor in
                    if let error, let self { onError("\(self.t("No se pudo asociar Markdown")): \(error.localizedDescription)") }
                    self?.refreshDefaultApp()
                }
            }
        }
    }
}
