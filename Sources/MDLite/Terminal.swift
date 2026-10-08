import AppKit
import SwiftUI

/// Opens the folder of a document in a terminal app. Prefers the one chosen in Settings,
/// then the first of the usual ones that is installed.
@MainActor
enum TerminalLauncher {
    struct App: Identifiable, Hashable {
        let id: String      // bundle identifier
        let name: String
        let url: URL
    }

    private static let known: [(String, String)] = [
        ("com.mitchellh.ghostty", "Ghostty"), ("com.googlecode.iterm2", "iTerm"), ("dev.warp.Warp-Stable", "Warp"),
        ("net.kovidgoyal.kitty", "kitty"), ("org.alacritty", "Alacritty"), ("com.github.wez.wezterm", "WezTerm"),
        ("com.apple.Terminal", "Terminal")
    ]

    static var installed: [App] {
        known.compactMap { id, name in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { App(id: id, name: name, url: $0) }
        }
    }

    static var preferred: App? {
        let chosen = UserDefaults.standard.string(forKey: "terminalApp")
        return installed.first { $0.id == chosen } ?? installed.first { $0.id == "com.apple.Terminal" } ?? installed.first
    }

    static func open(_ folder: URL) {
        guard let app = preferred else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([folder], withApplicationAt: app.url, configuration: configuration)
    }

    /// Where a document's commands run: its folder, the working folder, or home.
    static func folder(for store: ReaderStore) -> URL {
        if let file = store.fileURL { return file.deletingLastPathComponent() }
        return store.workspace ?? FileManager.default.homeDirectoryForCurrentUser
    }
}

/// Runs a shell script or a code block and collects what it prints. Not interactive: input is closed,
/// so a command that waits for the keyboard ends instead of hanging.
@MainActor
final class ScriptRunner: ObservableObject {
    @Published private(set) var output = ""
    @Published private(set) var running = false
    @Published private(set) var status: Int32?
    @Published private(set) var title = ""
    @Published var visible = false

    private var process: Process?
    private let limit = 400_000

    /// Asks before running: a document (or something downloaded) can hold any command.
    static func confirm(_ script: String, title: String, folder: URL, prefs: AppPreferences) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(format: prefs.t("¿Ejecutar %@?"), title)
        let preview = script.split(separator: "\n", omittingEmptySubsequences: false).prefix(12).joined(separator: "\n")
        alert.informativeText = prefs.t("Se ejecuta con tu usuario en") + " " + folder.path + "\n\n" + preview
            + (script.split(separator: "\n").count > 12 ? "\n…" : "")
        alert.addButton(withTitle: prefs.t("Ejecutar"))
        alert.addButton(withTitle: prefs.t("Cancelar"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    func run(_ script: String, title: String, in folder: URL) {
        stop()
        output = ""
        status = nil
        self.title = title
        visible = true
        running = true
        let task = Process()
        // A login shell picks up the PATH people set in their profile (Homebrew, nvm…).
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-l", "-c", script]
        task.currentDirectoryURL = folder
        task.standardInput = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "dumb"
        environment["NO_COLOR"] = "1"
        task.environment = environment
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in self?.append(text) }
        }
        task.terminationHandler = { [weak self] finished in
            let code = finished.terminationStatus
            Task { @MainActor in
                pipe.fileHandleForReading.readabilityHandler = nil
                self?.running = false
                self?.status = code
                self?.process = nil
            }
        }
        do {
            try task.run()
            process = task
        } catch {
            running = false
            output = error.localizedDescription
        }
    }

    func stop() {
        guard let process, process.isRunning else { return }
        process.terminate()
    }

    func clear() {
        stop()
        output = ""
        status = nil
        visible = false
    }

    private func append(_ text: String) {
        output += text.replacingOccurrences(of: #"\u{1B}\[[0-9;?]*[A-Za-z]"#, with: "", options: .regularExpression)
        if output.utf16.count > limit { output = "…\n" + String(output.suffix(limit / 2)) }
    }
}

/// Shows the output panel while there is something to show; it observes the runner on its own.
struct RunPanelSlot: View {
    @ObservedObject var runner: ScriptRunner
    let store: ReaderStore
    var body: some View {
        if runner.visible { RunPanel(runner: runner, store: store).transition(.move(edge: .bottom).combined(with: .opacity)) }
    }
}

/// Output of the last run, under the document.
struct RunPanel: View {
    @ObservedObject var runner: ScriptRunner
    @ObservedObject var store: ReaderStore

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: runner.running ? "circle.dotted" : (runner.status == 0 ? "checkmark.circle.fill" : "exclamationmark.circle.fill"))
                    .foregroundStyle(runner.running ? Color.secondary : (runner.status == 0 ? Color.green : Color.orange))
                    .symbolEffect(.pulse, isActive: runner.running)
                Text(runner.title).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                if let status = runner.status, !runner.running {
                    Text(status == 0 ? store.t("terminó") : String(format: store.t("salió con %d"), status))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                if runner.running {
                    Button(store.t("Detener")) { runner.stop() }
                }
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(runner.output, forType: .string) } label: {
                    Image(systemName: "doc.on.doc")
                }.help(store.t("Copiar la salida"))
                Button { TerminalLauncher.open(TerminalLauncher.folder(for: store)) } label: {
                    Image(systemName: "terminal")
                }.help(store.t("Abrir en Terminal"))
                Button { runner.clear() } label: { Image(systemName: "xmark") }.help(store.t("Cerrar"))
            }
            .buttonStyle(.borderless).controlSize(.small)
            .padding(.horizontal, 14).frame(height: 30)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    Text(runner.output.isEmpty ? (runner.running ? "" : store.t("Sin salida.")) : runner.output)
                        .font(.system(size: 11.5, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                    Color.clear.frame(height: 1).id("end")
                }
                .onChange(of: runner.output) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            }
        }
        .frame(height: 210)
        .background(.background.opacity(0.6))
        .overlay(alignment: .top) { Rectangle().fill(.primary.opacity(0.08)).frame(height: 1) }
    }
}
