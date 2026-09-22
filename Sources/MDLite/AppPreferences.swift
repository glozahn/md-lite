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
    @Published var checkForUpdatesAutomatically: Bool { didSet { defaults.set(checkForUpdatesAutomatically, forKey: "checkForUpdates") } }
    @Published private(set) var recent: [URL]
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
        checkForUpdatesAutomatically = defaults.bool(forKey: "checkForUpdates")
        recent = (defaults.stringArray(forKey: "recentFiles") ?? []).map { URL(fileURLWithPath: $0) }
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
