import AppKit
import SwiftUI

/// What a window (tab) shows. Codable so macOS can restore tabs on relaunch.
struct DocumentTarget: Codable, Hashable {
    var id = UUID()
    var url: URL?
    var workspace: URL?
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

/// Routes documents to windows: reuses an empty tab, focuses a tab that already shows the file,
/// or opens a new tab.
@MainActor
final class DocumentRouter {
    static let shared = DocumentRouter()
    var openWindow: ((DocumentTarget) -> Void)?
    private let stores = NSHashTable<ReaderStore>.weakObjects()
    /// Window that the next opened document joins as a tab.
    private weak var tabParent: NSWindow?
    private var pending: [URL] = []

    var all: [ReaderStore] { stores.allObjects }
    var keyStore: ReaderStore? {
        all.first { $0.window?.isKeyWindow == true } ?? all.first { $0.window?.isMainWindow == true } ?? all.first
    }

    func register(_ store: ReaderStore) {
        stores.add(store)
        flush()
    }

    func enqueue(_ urls: [URL]) {
        pending += urls
        flush()
    }

    private func flush() {
        guard !pending.isEmpty, keyStore != nil else { return }
        let urls = pending
        pending = []
        for url in urls { open(url) }
    }

    func open(_ url: URL, from source: ReaderStore? = nil, newTab: Bool = false) {
        var isFolder: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue {
            (source ?? keyStore)?.setWorkspace(url)
            return
        }
        if let existing = all.first(where: { $0.fileURL?.standardizedFileURL == url.standardizedFileURL }) {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let origin = source ?? keyStore
        if !newTab, let origin, origin.canReuseForNewDocument {
            origin.open(url)
        } else if let openWindow {
            tabParent = origin?.window
            openWindow(DocumentTarget(url: url, workspace: origin?.workspace))
        } else {
            origin?.open(url)
        }
    }

    func newTab(from store: ReaderStore?) {
        tabParent = (store ?? keyStore)?.window
        openWindow?(DocumentTarget(workspace: (store ?? keyStore)?.workspace))
    }

    /// New document windows appear as tabs of the window that opened them.
    func adopt(_ window: NSWindow) {
        guard let parent = tabParent, parent !== window, parent.isVisible else { return }
        tabParent = nil
        if !(parent.tabbedWindows ?? []).contains(window) { parent.addTabbedWindow(window, ordered: .above) }
        window.makeKeyAndOrderFront(nil)
    }

    /// Command-W: closes the innermost thing in front — a popover or sheet, About or Settings,
    /// or the current tab — never more than one.
    func closeFrontmost(focused: ReaderStore?) {
        if let owner = all.first(where: { $0.showQuickSettings }) { owner.showQuickSettings = false; return }
        let key = NSApp.keyWindow
        if let key, let owner = all.first(where: { $0.window === key || (key.sheetParent != nil && $0.window === key.sheetParent) }) {
            owner.closeFrontmost()
        } else if let key {
            key.performClose(nil)
        } else {
            focused?.closeFrontmost()
        }
    }

    /// Asks every tab with unsaved work before quitting.
    func confirmQuit() -> Bool {
        for store in all where store.isDirty {
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
