import AppKit
import CryptoKit

/// Keeps MD Lite up to date on its own: it downloads the disk image from GitHub Releases,
/// checks it, and swaps the app in place. Nothing is installed that is not signed by the
/// same developer as the copy already running, and notarized by Apple.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    struct Ready: Equatable {
        let version: String
        /// The new app, already verified, waiting next to the one in use.
        let app: URL
    }

    @Published private(set) var ready: Ready?
    @Published private(set) var working = false
    @Published private(set) var failure: String?

    private var stagingFolder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MD Lite/Updates", isDirectory: true)
    }

    /// Where the running app lives, when we are allowed to replace it.
    private var installedApp: URL? {
        let url = Bundle.main.bundleURL
        guard url.pathExtension == "app",
              !url.path.contains("/AppTranslocation/"),
              !url.path.contains("/Volumes/"),
              FileManager.default.isWritableFile(atPath: url.deletingLastPathComponent().path),
              FileManager.default.isWritableFile(atPath: url.path) else { return nil }
        return url
    }

    var canInstall: Bool { installedApp != nil }

    // MARK: Checking

    func checkInBackground(_ prefs: AppPreferences) {
        guard prefs.automaticUpdates, !working, ready == nil, canInstall else { return }
        let last = UserDefaults.standard.double(forKey: "lastUpdateCheck")
        guard Date().timeIntervalSince1970 - last > 21_600 else { return }
        Task { await check(prefs, userInitiated: false) }
    }

    /// Returns true when it took over, so the caller can skip the download-in-a-browser path.
    @discardableResult
    func checkNow(_ prefs: AppPreferences) -> Bool {
        guard canInstall else { return false }
        if let ready {
            install(relaunch: true, version: ready.version)
            return true
        }
        guard !working else { return true }
        Task { await check(prefs, userInitiated: true) }
        return true
    }

    private func check(_ prefs: AppPreferences, userInitiated: Bool) async {
        working = true
        failure = nil
        defer { working = false }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")
        do {
            guard let release = try await UpdateChecker.latest(),
                  UpdateChecker.isNewer(release.version, than: UpdateChecker.currentVersion) else {
                if userInitiated { upToDate(prefs) }
                return
            }
            guard let download = release.download else {
                if userInitiated { NSWorkspace.shared.open(release.page) }
                return
            }
            let version = release.version.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            let app = try await fetchAndVerify(download, checksum: release.checksum, version: version)
            ready = Ready(version: version, app: app)
        } catch {
            let message = (error as? UpdateError)?.message ?? error.localizedDescription
            failure = message
            if userInitiated {
                let alert = NSAlert()
                alert.messageText = prefs.t("No se pudo actualizar")
                alert.informativeText = message
                alert.addButton(withTitle: prefs.t("Entendido"))
                alert.addButton(withTitle: prefs.t("Ver novedades"))
                if alert.runModal() == .alertSecondButtonReturn,
                   let page = URL(string: "https://github.com/\(UpdateChecker.repository)/releases/latest") {
                    NSWorkspace.shared.open(page)
                }
            }
        }
    }

    private func upToDate(_ prefs: AppPreferences) {
        let alert = NSAlert()
        alert.messageText = prefs.t("MD Lite está al día")
        alert.informativeText = String(format: prefs.t("Tienes la versión más reciente (%@)."), UpdateChecker.currentVersion)
        alert.runModal()
    }

    // MARK: Download and checks

    private func fetchAndVerify(_ download: URL, checksum: URL?, version: String) async throws -> URL {
        let session = URLSession(configuration: .ephemeral)
        let (file, response) = try await session.download(from: download)
        defer { try? FileManager.default.removeItem(at: file) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.download }

        if let checksum, let expected = try? await session.data(from: checksum).0,
           let text = String(data: expected, encoding: .utf8)?.split(separator: " ").first {
            let digest = SHA256.hash(data: try Data(contentsOf: file, options: .mappedIfSafe))
            let actual = digest.map { String(format: "%02x", $0) }.joined()
            guard actual == text.lowercased() else { throw UpdateError.checksum }
        }

        let mount = stagingFolder.appendingPathComponent("mount-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        guard run("/usr/bin/hdiutil", ["attach", file.path, "-nobrowse", "-readonly", "-mountpoint", mount.path]) else {
            throw UpdateError.mount
        }
        defer {
            _ = run("/usr/bin/hdiutil", ["detach", mount.path, "-quiet"])
            try? FileManager.default.removeItem(at: mount)
        }

        guard let name = try FileManager.default.contentsOfDirectory(atPath: mount.path).first(where: { $0.hasSuffix(".app") }) else {
            throw UpdateError.contents
        }
        let newApp = mount.appendingPathComponent(name)
        try verify(newApp)

        let staged = stagingFolder.appendingPathComponent("\(version)/\(name)")
        try? FileManager.default.removeItem(at: staged.deletingLastPathComponent())
        try FileManager.default.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard run("/usr/bin/ditto", [newApp.path, staged.path]) else { throw UpdateError.copy }
        return staged
    }

    /// The update has to be signed by the same team as the running app, and notarized.
    private func verify(_ app: URL) throws {
        guard let team = Self.teamIdentifier(of: app), team == Self.teamIdentifier(of: Bundle.main.bundleURL) else {
            throw UpdateError.signature
        }
        var requirement: SecRequirement?
        let rule = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\"" as CFString
        guard SecRequirementCreateWithString(rule, [], &requirement) == errSecSuccess, let requirement else {
            throw UpdateError.signature
        }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { throw UpdateError.signature }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate)
        guard SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else { throw UpdateError.signature }
        // Gatekeeper's own verdict, which also covers notarization.
        guard run("/usr/sbin/spctl", ["--assess", "--type", "exec", app.path]) else { throw UpdateError.notarization }
    }

    private static func teamIdentifier(of app: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else { return nil }
        return dictionary["teamid"] as? String
    }

    // MARK: Installing

    /// Swaps the app once this process is gone. Called on quit, or right away when the user asks.
    func install(relaunch: Bool, version: String? = nil) {
        guard let ready, let current = installedApp else { return }
        let documents = relaunch ? DocumentRouter.shared.openFileURLs() : []
        let script = stagingFolder.appendingPathComponent("install-\(ready.version).sh")
        let reopen = relaunch
            ? "/usr/bin/open -a \(quote(current.path)) " + documents.map { quote($0.path) }.joined(separator: " ")
            : ""
        let body = """
        #!/bin/sh
        while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do /bin/sleep 0.2; done
        /bin/rm -rf \(quote(current.path + ".old"))
        /bin/mv \(quote(current.path)) \(quote(current.path + ".old")) || exit 1
        /usr/bin/ditto \(quote(ready.app.path)) \(quote(current.path)) || { /bin/mv \(quote(current.path + ".old")) \(quote(current.path)); exit 1; }
        /usr/bin/xattr -dr com.apple.quarantine \(quote(current.path))
        /bin/rm -rf \(quote(current.path + ".old")) \(quote(ready.app.deletingLastPathComponent().path))
        \(reopen)
        """
        UserDefaults.standard.set(UpdateChecker.currentVersion, forKey: "updatedFromVersion")
        do {
            try FileManager.default.createDirectory(at: stagingFolder, withIntermediateDirectories: true)
            try body.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/sh")
            task.arguments = [script.path]
            try task.run()
        } catch {
            failure = error.localizedDescription
            return
        }
        self.ready = nil
        if relaunch { NSApp.terminate(nil) }
    }

    /// After an update has been installed, the first launch shows what changed.
    func showChangelogAfterUpdate() {
        let key = "updatedFromVersion"
        guard let previous = UserDefaults.standard.string(forKey: key) else { return }
        UserDefaults.standard.removeObject(forKey: key)
        guard previous != UpdateChecker.currentVersion else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard let bench = DocumentRouter.shared.keyBench else { return }
            let target = bench.focusedStore.canReuseForNewDocument ? bench.focusedStore : bench.newTab()
            target.readChangelog()
        }
    }

    /// Called when the app is quitting anyway: the update lands without interrupting anyone.
    func installOnQuit() {
        guard ready != nil else { return }
        install(relaunch: false)
    }

    private func quote(_ path: String) -> String { "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    @discardableResult
    private func run(_ tool: String, _ arguments: [String]) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: tool)
        task.arguments = arguments
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return false }
        task.waitUntilExit()
        return task.terminationStatus == 0
    }

    enum UpdateError: Error {
        case download, checksum, mount, contents, copy, signature, notarization

        @MainActor var message: String {
            let prefs = AppPreferences.shared
            switch self {
            case .download: return prefs.t("No se pudo descargar la actualización.")
            case .checksum: return prefs.t("La descarga no coincide con su suma de verificación.")
            case .mount, .contents, .copy: return prefs.t("No se pudo abrir la imagen de disco descargada.")
            case .signature, .notarization: return prefs.t("La actualización no está firmada por el mismo desarrollador.")
            }
        }
    }
}
