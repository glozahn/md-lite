import AppKit
import Combine

/// What was open when MD Lite quit: windows, their panes and tabs, and working folders.
/// Unsaved text is not part of it; that is kept by the recovery files.
@MainActor
enum Session {
    struct Tab: Codable, Equatable {
        var path: String?
        var link: String?
        var mode: String
    }

    struct PaneState: Codable, Equatable {
        var tabs: [Tab]
        var selected: Int
    }

    struct WindowState: Codable, Equatable {
        var panes: [PaneState]
        var focusedPane: Int
        var workspace: String?
    }

    private static let key = "session"
    private static var pending: [WindowState]?
    private static var loaded = false
    private static var saveWork: DispatchWorkItem?

    /// The next window to bring back. Only answers while the app is starting.
    static func nextWindow() -> WindowState? {
        if !loaded {
            loaded = true
            if let data = UserDefaults.standard.data(forKey: key) {
                pending = (try? JSONDecoder().decode([WindowState].self, from: data))?.filter { !$0.panes.isEmpty }
            }
        }
        guard var windows = pending, !windows.isEmpty else { return nil }
        let first = windows.removeFirst()
        pending = windows
        return first
    }

    /// Windows still to reopen after the first one; opened once that window is on screen.
    static func reopenRemainingWindows() {
        guard let windows = pending, !windows.isEmpty, let open = DocumentRouter.shared.openWindow else { return }
        for _ in windows { open(DocumentTarget()) }
    }

    static func finishStartup() { pending = nil }

    static func state(of bench: Workbench) -> WindowState? {
        let panes: [PaneState] = bench.panes.compactMap { pane in
            var tabs: [Tab] = []
            var selected = 0
            for store in pane.tabs {
                let tab: Tab
                if let file = store.fileURL { tab = Tab(path: file.path, link: nil, mode: store.mode.rawValue) }
                else if let link = store.remoteURL { tab = Tab(path: nil, link: link.absoluteString, mode: store.mode.rawValue) }
                else { continue }
                if store.id == pane.selectedID { selected = tabs.count }
                tabs.append(tab)
            }
            return tabs.isEmpty ? nil : PaneState(tabs: tabs, selected: selected)
        }
        guard !panes.isEmpty || bench.workspace != nil else { return nil }
        let focused = bench.panes.firstIndex { $0.id == bench.focusedPaneID } ?? 0
        return WindowState(panes: panes, focusedPane: min(focused, max(0, panes.count - 1)), workspace: bench.workspace?.path)
    }

    static func save() {
        saveWork?.cancel()
        let windows = DocumentRouter.shared.workbenches.compactMap(state(of:))
        if let data = try? JSONEncoder().encode(windows) { UserDefaults.standard.set(data, forKey: key) }
    }

    static func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }
}

/// Where each file was being read, so it opens there again. Kept for the most recent files only.
@MainActor
enum ReadingPositions {
    private static let key = "readingPositions"
    private static let limit = 300
    private static var cache: [[String: Any]]?
    private static var saveWork: DispatchWorkItem?

    private static var entries: [[String: Any]] {
        get { cache ?? (UserDefaults.standard.array(forKey: key) as? [[String: Any]]) ?? [] }
        set { cache = newValue }
    }

    static func offset(for url: URL) -> Int? {
        entries.first { $0["path"] as? String == url.path }?["offset"] as? Int
    }

    static func remember(_ offset: Int, for url: URL) {
        var list = entries.filter { $0["path"] as? String != url.path }
        if offset > 0 { list.insert(["path": url.path, "offset": offset], at: 0) }
        entries = Array(list.prefix(limit))
        saveWork?.cancel()
        let work = DispatchWorkItem { flush() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    static func flush() {
        saveWork?.cancel()
        guard let cache else { return }
        UserDefaults.standard.set(cache, forKey: key)
    }
}
