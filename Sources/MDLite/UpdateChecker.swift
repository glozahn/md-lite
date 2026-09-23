import AppKit

/// Checks GitHub Releases for a newer MD Lite. One small HTTPS request, only when asked
/// (or once a day when the user enables automatic checks).
@MainActor
enum UpdateChecker {
    static let repository = "glozahn/md-lite"
    private static var checking = false

    struct Release {
        let version: String
        let page: URL
        let download: URL?
        let checksum: URL?
        let notes: String
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ value: String) -> [Int] {
            value.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")).split(separator: "-").first?
                .split(separator: ".").map { Int($0) ?? 0 } ?? []
        }
        let a = parts(candidate), b = parts(current)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0, y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    static func checkAutomaticallyIfNeeded(_ store: AppPreferences) {
        guard store.automaticUpdates else { return }
        // When MD Lite can replace itself it does the whole thing quietly.
        if Updater.shared.canInstall { Updater.shared.checkInBackground(store); return }
        let last = UserDefaults.standard.double(forKey: "lastUpdateCheck")
        guard Date().timeIntervalSince1970 - last > 86_400 else { return }
        check(store, userInitiated: false)
    }

    static func check(_ store: AppPreferences, userInitiated: Bool) {
        if userInitiated, Updater.shared.checkNow(store) { return }
        guard !checking else { return }
        checking = true
        Task {
            let release = try? await latest()
            checking = false
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")
            present(release, store: store, userInitiated: userInitiated)
        }
    }

    /// The newest published release, or nil when GitHub says nothing useful.
    static func latest() async throws -> Release? {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        return try await fetch(request, session: URLSession(configuration: .ephemeral))
    }

    private static func fetch(_ request: URLRequest, session: URLSession) async throws -> Release? {
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)) else { return nil }
        let assets = json["assets"] as? [[String: Any]] ?? []
        let architecture = ProcessInfo.processInfo.machineArchitecture
        let dmgs = assets.compactMap { $0["browser_download_url"] as? String }.filter { $0.hasSuffix(".dmg") }
        let download = (dmgs.first { $0.contains(architecture) } ?? dmgs.first).flatMap(URL.init(string:))
        let checksums = assets.compactMap { $0["browser_download_url"] as? String }.filter { $0.hasSuffix(".sha256") }
        let checksum = (download?.lastPathComponent).flatMap { name in checksums.first { $0.hasSuffix(name + ".sha256") } }
            .flatMap(URL.init(string:))
        return Release(version: tag, page: page, download: download, checksum: checksum, notes: json["body"] as? String ?? "")
    }

    private static func present(_ release: Release?, store: AppPreferences, userInitiated: Bool) {
        let alert = NSAlert()
        guard let release else {
            guard userInitiated else { return }
            alert.messageText = store.t("No se pudo buscar actualizaciones")
            alert.informativeText = store.t("Revisa tu conexión e inténtalo de nuevo.")
            alert.runModal()
            return
        }
        guard isNewer(release.version, than: currentVersion) else {
            guard userInitiated else { return }
            alert.messageText = store.t("MD Lite está al día")
            alert.informativeText = String(format: store.t("Tienes la versión más reciente (%@)."), currentVersion)
            alert.runModal()
            return
        }
        let version = release.version.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        alert.messageText = String(format: store.t("MD Lite %@ está disponible"), version)
        let notes = release.notes.split(separator: "\n").prefix(8).joined(separator: "\n")
        alert.informativeText = String(format: store.t("Tienes la versión %@."), currentVersion) + (notes.isEmpty ? "" : "\n\n" + notes)
        alert.addButton(withTitle: store.t("Descargar"))
        alert.addButton(withTitle: store.t("Ver novedades"))
        alert.addButton(withTitle: store.t("Más tarde"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: NSWorkspace.shared.open(release.download ?? release.page)
        case .alertSecondButtonReturn: NSWorkspace.shared.open(release.page)
        default: break
        }
    }
}

private extension ProcessInfo {
    var machineArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }
}
