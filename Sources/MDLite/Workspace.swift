import AppKit
import SwiftUI

/// What a window (tab) shows. Codable so macOS can restore tabs on relaunch.
struct DocumentTarget: Codable, Hashable {
    var id = UUID()
    var url: URL?
    var workspace: URL?
}

/// Secondary windows (Settings, About). SwiftUI opens them, but leaves them behind the
/// document window when they already exist, so bring them to the front ourselves.
@MainActor
enum AppWindows {
    /// SwiftUI's openSettings opens the window; raising it is on us.
    static func showSettings(_ open: OpenSettingsAction) {
        if raise("Settings") { return }
        open()
        DispatchQueue.main.async { _ = raise("Settings") }
    }

    @discardableResult
    static func raise(_ fragment: String) -> Bool {
        guard let window = NSApp.windows.first(where: {
            $0.identifier?.rawValue.localizedCaseInsensitiveContains(fragment) == true && $0.isVisible
        }) else { return false }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        return true
    }
}

struct FileNode: Identifiable, Hashable {
    let url: URL
    let isDirectory: Bool
    var children: [FileNode]?
    var id: URL { url }
    var name: String { url.lastPathComponent }
}

/// Finds Markdown files under a folder, skipping hidden and generated directories.
enum WorkspaceScanner {
    static let skipped: Set<String> = ["node_modules", ".git", ".build", "build", "dist", "DerivedData", "Pods", ".next",
                                       "target", "vendor", ".venv", "venv", "__pycache__", ".swiftpm", "Carthage"]
    static let extensions: Set<String> = ["md", "markdown", "mdown", "mkd"]

    static func scan(_ root: URL, limit: Int = 4000) -> [FileNode] {
        var budget = limit
        return scan(root, depth: 0, budget: &budget)
    }

    private static func scan(_ folder: URL, depth: Int, budget: inout Int) -> [FileNode] {
        guard depth < 10, budget > 0,
              let items = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var folders: [FileNode] = [], files: [FileNode] = []
        for item in items {
            guard budget > 0 else { break }
            let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory {
                guard !skipped.contains(item.lastPathComponent) else { continue }
                let children = scan(item, depth: depth + 1, budget: &budget)
                if !children.isEmpty { folders.append(FileNode(url: item, isDirectory: true, children: children)) }
            } else if extensions.contains(item.pathExtension.lowercased()) {
                budget -= 1
                files.append(FileNode(url: item, isDirectory: false, children: nil))
            }
        }
        let order: (FileNode, FileNode) -> Bool = { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return folders.sorted(by: order) + files.sorted(by: order)
    }
}

/// One column of tabs. A window shows one pane, or two side by side.
@MainActor
final class Pane: ObservableObject, Identifiable {
    let id = UUID()
    @Published var tabs: [ReaderStore]
    @Published var selectedID: UUID
    /// Last tab shown. A pane being animated away can still be drawn after its last tab left.
    private var lastSelected: ReaderStore

    init(_ store: ReaderStore) {
        tabs = [store]
        selectedID = store.id
        lastSelected = store
    }

    var selected: ReaderStore {
        if let store = tabs.first(where: { $0.id == selectedID }) ?? tabs.first {
            lastSelected = store
            return store
        }
        return lastSelected
    }
}

enum PaneSide { case left, right }

/// Everything one window shows: its panes and tabs, and its working folder.
@MainActor
final class Workbench: ObservableObject {
    @Published private(set) var panes: [Pane] = []
    @Published private(set) var focusedPaneID: UUID
    @Published private(set) var workspace: URL?
    @Published private(set) var workspaceTree: [FileNode] = []
    @Published private(set) var isScanningWorkspace = false
    /// Focus mode belongs to the window: it hides the sidebar, the other pane and every bar.
    @Published var focusMode = false
    @Published var splitRatio: CGFloat = UserDefaults.standard.object(forKey: "paneRatio") as? CGFloat ?? 0.5
    weak var window: NSWindow?
    private var observers: [NSObjectProtocol] = []

    init(target: DocumentTarget) {
        let first = ReaderStore()
        // Only the first window greets with the welcome page; later ones start empty.
        if !DocumentRouter.shared.workbenches.isEmpty, target.url == nil { first.makeBlank() }
        let pane = Pane(first)
        panes = [pane]
        focusedPaneID = pane.id
        first.workbench = self
        if let folder = target.workspace, FileManager.default.fileExists(atPath: folder.path) { setWorkspace(folder) }
        if let url = target.url { first.open(url, quiet: true) }
    }

    var focusedPane: Pane { panes.first { $0.id == focusedPaneID } ?? panes[0] }
    var focusedStore: ReaderStore { focusedPane.selected }
    var allStores: [ReaderStore] { panes.flatMap(\.tabs) }
    func pane(of store: ReaderStore) -> Pane? { panes.first { $0.tabs.contains { $0 === store } } }

    func attach(_ window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        window.tabbingMode = .disallowed
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.allStores.forEach { $0.preserveUnsavedWork() } }
        })
        DocumentRouter.shared.register(self)
    }

    // MARK: Focus and selection

    func focus(_ store: ReaderStore) {
        guard let pane = pane(of: store) else { return }
        if pane.selectedID != store.id { pane.selectedID = store.id }
        if focusedPaneID != pane.id { focusedPaneID = pane.id }
        objectWillChange.send()
    }

    func focus(pane: Pane) {
        guard focusedPaneID != pane.id else { return }
        focusedPaneID = pane.id
    }

    func cycleTab(_ delta: Int) {
        let pane = focusedPane
        guard pane.tabs.count > 1, let index = pane.tabs.firstIndex(where: { $0.id == pane.selectedID }) else { return }
        focus(pane.tabs[(index + delta + pane.tabs.count) % pane.tabs.count])
    }

    // MARK: Tabs

    private func makeStore(blank: Bool = true) -> ReaderStore {
        let store = ReaderStore()
        store.workbench = self
        if blank { store.makeBlank() }
        return store
    }

    /// A new, empty tab: a place to drop or open a document.
    @discardableResult
    func newTab(in pane: Pane? = nil, after anchor: ReaderStore? = nil) -> ReaderStore {
        let target = pane ?? focusedPane
        let store = makeStore()
        let index = anchor.flatMap { a in target.tabs.firstIndex { $0 === a } }.map { $0 + 1 } ?? target.tabs.count
        target.tabs.insert(store, at: index)
        focus(store)
        return store
    }

    /// Opens a file: in the focused tab when it is free, otherwise in a new tab of `pane`.
    func open(_ url: URL, in pane: Pane? = nil, newTab forceNew: Bool = false) {
        let target = pane ?? focusedPane
        if !forceNew, target.selected.canReuseForNewDocument {
            target.selected.open(url)
            focus(target.selected)
            return
        }
        let store = makeStore()
        store.open(url, quiet: false)
        guard store.fileURL != nil else {
            target.selected.error = store.error
            return
        }
        let index = target.tabs.firstIndex { $0.id == target.selectedID }.map { $0 + 1 } ?? target.tabs.count
        target.tabs.insert(store, at: index)
        focus(store)
    }

    /// Opens `url` (or moves `store`) into the pane on `side`, creating that pane when needed.
    func place(url: URL? = nil, store moving: ReaderStore? = nil, side: PaneSide) {
        let destination: Pane
        if panes.count == 1 {
            if let moving, pane(of: moving)?.tabs.count == 1 { return }
            let placeholder = makeStore()
            let pane = Pane(placeholder)
            if side == .left { panes.insert(pane, at: 0) } else { panes.append(pane) }
            destination = pane
        } else {
            destination = side == .left ? panes[0] : panes[panes.count - 1]
        }
        if let moving {
            move(moving, to: destination, at: nil)
        } else if let url {
            open(url, in: destination)
        }
        if destination.tabs.count > 1, destination.tabs[0].canReuseForNewDocument, destination.tabs[0].isBlank || destination.tabs[0].isWelcome {
            destination.tabs.removeFirst()
        }
        cleanUpEmptyPanes()
    }

    func move(_ store: ReaderStore, to destination: Pane, at index: Int?) {
        guard let source = pane(of: store) else { return }
        if source === destination {
            guard let index, let from = source.tabs.firstIndex(where: { $0 === store }) else { return }
            source.tabs.remove(at: from)
            source.tabs.insert(store, at: min(index > from ? index - 1 : index, source.tabs.count))
            focus(store)
            return
        }
        source.tabs.removeAll { $0 === store }
        if source.tabs.isEmpty { panes.removeAll { $0 === source } }
        else if source.selectedID == store.id { source.selectedID = source.tabs[0].id }
        destination.tabs.insert(store, at: min(index ?? destination.tabs.count, destination.tabs.count))
        focus(store)
    }

    /// Closes a tab after saving or asking. The last tab of the last pane closes the window.
    func close(_ store: ReaderStore) {
        guard let pane = pane(of: store), store.confirmDiscard() else { return }
        if panes.count == 1, pane.tabs.count == 1 {
            window?.performClose(nil)
            return
        }
        let index = pane.tabs.firstIndex { $0 === store } ?? 0
        pane.tabs.remove(at: index)
        if pane.tabs.isEmpty {
            panes.removeAll { $0 === pane }
            focusedPaneID = panes[0].id
        } else if pane.selectedID == store.id {
            pane.selectedID = pane.tabs[min(index, pane.tabs.count - 1)].id
        }
        focus(focusedStore)
    }

    /// Closes a pane without closing documents: its tabs join the other pane.
    func closePane(_ pane: Pane) {
        guard panes.count == 2, let other = panes.first(where: { $0 !== pane }) else { return }
        let selected = pane.selected
        let moving = pane.tabs.filter { !(($0.isWelcome || $0.isBlank) && $0.canReuseForNewDocument) }
        other.tabs.append(contentsOf: moving)
        if other.tabs.count > 1, other.tabs[0].isWelcome || other.tabs[0].isBlank, other.tabs[0].canReuseForNewDocument { other.tabs.removeFirst() }
        panes.removeAll { $0 === pane }
        focusedPaneID = other.id
        focus(moving.contains { $0 === selected } ? selected : other.selected)
    }

    /// Takes a tab out of this window (it is moving to another one).
    func release(_ store: ReaderStore) {
        guard let pane = pane(of: store) else { return }
        pane.tabs.removeAll { $0 === store }
        if pane.tabs.isEmpty {
            if panes.count > 1 { panes.removeAll { $0 === pane } } else { window?.performClose(nil) }
        } else if pane.selectedID == store.id {
            pane.selectedID = pane.tabs[0].id
        }
        if !panes.contains(where: { $0.id == focusedPaneID }) { focusedPaneID = panes[0].id }
    }

    private func cleanUpEmptyPanes() {
        panes.removeAll { $0.tabs.isEmpty }
        if !panes.contains(where: { $0.id == focusedPaneID }) { focusedPaneID = panes[0].id }
    }

    // MARK: Working folder

    func openWorkspacePanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = focusedStore.t("Abrir carpeta")
        if panel.runModal() == .OK, let url = panel.url { setWorkspace(url) }
    }

    func setWorkspace(_ url: URL?) {
        workspace = url
        workspaceTree = []
        if let url {
            UserDefaults.standard.set(url.path, forKey: "lastWorkspace")
            refreshWorkspace()
        }
    }

    func refreshWorkspace() {
        guard let root = workspace, !isScanningWorkspace else { return }
        isScanningWorkspace = true
        Task.detached(priority: .userInitiated) {
            let tree = WorkspaceScanner.scan(root)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isScanningWorkspace = false
                guard self.workspace == root, tree != self.workspaceTree else { return }
                self.workspaceTree = tree
            }
        }
    }
}

/// Routes documents to windows: focuses a tab that already shows the file, reuses an empty tab,
/// or adds a tab to the frontmost window.
@MainActor
final class DocumentRouter {
    static let shared = DocumentRouter()
    var openWindow: ((DocumentTarget) -> Void)?
    private let benches = NSHashTable<Workbench>.weakObjects()
    private var pending: [URL] = []

    var workbenches: [Workbench] { benches.allObjects }
    var all: [ReaderStore] { workbenches.flatMap(\.allStores) }
    var keyBench: Workbench? {
        workbenches.first { $0.window?.isKeyWindow == true } ?? workbenches.first { $0.window?.isMainWindow == true } ?? workbenches.first
    }
    var keyStore: ReaderStore? { keyBench?.focusedStore }

    func register(_ bench: Workbench) {
        benches.add(bench)
        flush()
    }

    func enqueue(_ urls: [URL]) {
        pending += urls
        flush()
    }

    private func flush() {
        guard !pending.isEmpty, keyBench != nil else { return }
        let urls = pending
        pending = []
        for url in urls { open(url) }
    }

    func open(_ url: URL, from source: ReaderStore? = nil, newTab: Bool = false) {
        var isFolder: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue {
            (source?.workbench ?? keyBench)?.setWorkspace(url)
            return
        }
        if let existing = all.first(where: { $0.fileURL?.standardizedFileURL == url.standardizedFileURL }), let bench = existing.workbench {
            bench.focus(existing)
            bench.window?.makeKeyAndOrderFront(nil)
            return
        }
        guard let bench = source?.workbench ?? keyBench else {
            openWindow?(DocumentTarget(url: url))
            return
        }
        bench.open(url, in: source.flatMap { bench.pane(of: $0) }, newTab: newTab)
    }

    func newTab(from store: ReaderStore?) {
        (store?.workbench ?? keyBench)?.newTab()
    }

    /// Command-W: closes the innermost thing in front — a popover or sheet, About or Settings,
    /// or the current tab — never more than one.
    func closeFrontmost(focused: ReaderStore?) {
        if let owner = all.first(where: { $0.showQuickSettings }) { owner.showQuickSettings = false; return }
        let key = NSApp.keyWindow
        if let key, let bench = workbenches.first(where: { $0.window === key || (key.sheetParent != nil && $0.window === key.sheetParent) }) {
            bench.focusedStore.closeFrontmost()
        } else if let key {
            key.performClose(nil)
        } else {
            focused?.closeFrontmost()
        }
    }

    /// Asks every tab with unsaved work before quitting.
    func confirmQuit() -> Bool {
        for store in all where store.isDirty {
            store.workbench?.focus(store)
            store.window?.makeKeyAndOrderFront(nil)
            guard store.confirmDiscard() else { return false }
        }
        return true
    }
}

/// Hands the hosting NSWindow to SwiftUI code.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { if let window = view.window { onWindow(window) } }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        if let window = view.window { onWindow(window) }
    }
}
