import SwiftUI
import UniformTypeIdentifiers

/// Settings ▸ Open with MD Lite: which app Finder uses for each kind of file MD Lite reads,
/// and a button to make it MD Lite. macOS asks for confirmation before it changes anything.
struct FileAssociationsSection: View {
    @ObservedObject var prefs: AppPreferences
    @State private var owners: [String: String] = [:]
    @State private var mine: Set<String> = []
    @State private var error: String?

    struct Group: Identifiable {
        let id: String
        let title: String
        let extensions: [String]
        /// Kinds MD Lite is a natural home for; code stays with the developer's editor unless asked.
        let suggested: Bool
    }

    private var groups: [Group] {
        [
            Group(id: "markdown", title: prefs.t("Markdown"), extensions: ["md", "markdown"], suggested: true),
            Group(id: "text", title: prefs.t("Texto"), extensions: ["txt"], suggested: true),
            Group(id: "logs", title: prefs.t("Registros"), extensions: ["log"], suggested: true),
            Group(id: "data", title: prefs.t("Datos"), extensions: ["csv", "tsv", "json", "yaml", "yml", "toml"], suggested: false),
            Group(id: "scripts", title: prefs.t("Scripts y SQL"), extensions: ["sh", "zsh", "sql"], suggested: false)
        ]
    }

    var body: some View {
        Section {
            ForEach(groups) { group in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            Text(group.title)
                            if group.suggested && !mine.contains(group.id) {
                                Text(prefs.t("Sugerido")).font(.system(size: 9.5, weight: .semibold))
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .foregroundStyle(prefs.accentColor)
                                    .background(prefs.accentColor.opacity(0.12), in: Capsule())
                            }
                        }
                        Text(group.extensions.map { "." + $0 }.joined(separator: " ") + (owners[group.id].map { " · " + $0 } ?? ""))
                            .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if mine.contains(group.id) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            .help(prefs.t("Ya se abren con MD Lite"))
                    } else {
                        Button(prefs.t("Usar MD Lite")) { associate(group) }.controlSize(.small)
                    }
                }
            }
            if groups.contains(where: { !mine.contains($0.id) }) {
                Button(prefs.t("Usar MD Lite para los sugeridos")) {
                    for group in groups where group.suggested && !mine.contains(group.id) { associate(group) }
                }
                .buttonStyle(.link).font(.system(size: 11.5))
                .disabled(!groups.contains { $0.suggested && !mine.contains($0.id) })
            }
            if let error {
                Text(error).font(.system(size: 10.5)).foregroundStyle(.red)
            }
        } header: {
            Text(prefs.t("Abrir con MD Lite"))
        } footer: {
            Text(prefs.t("Doble clic en Finder abre estos archivos aquí. macOS te pide confirmarlo."))
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private func types(_ group: Group) -> [UTType] {
        var seen = Set<String>()
        return group.extensions.compactMap { UTType(filenameExtension: $0) }.filter { seen.insert($0.identifier).inserted }
    }

    private func refresh() {
        var owners: [String: String] = [:]
        var mine = Set<String>()
        for group in groups {
            let apps = types(group).map { NSWorkspace.shared.urlForApplication(toOpen: $0) }
            if !apps.isEmpty, apps.allSatisfy({ $0.flatMap { Bundle(url: $0)?.bundleIdentifier } == Bundle.main.bundleIdentifier }) {
                mine.insert(group.id)
            }
            let others = Set(apps.compactMap { $0 }.filter { Bundle(url: $0)?.bundleIdentifier != Bundle.main.bundleIdentifier }
                .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") })
            if !others.isEmpty { owners[group.id] = others.sorted().joined(separator: ", ") }
        }
        self.owners = owners
        self.mine = mine
        prefs.refreshDefaultApp()
    }

    private func associate(_ group: Group) {
        error = nil
        for type in types(group) {
            NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: type) { failure in
                Task { @MainActor in
                    if let failure { error = "\(prefs.t("No se pudo asociar")) \(group.title): \(failure.localizedDescription)" }
                    refresh()
                }
            }
        }
    }
}
