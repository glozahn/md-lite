import AppKit
import WebKit

enum MermaidResult {
    case image(NSImage)
    case failure(String)
}

/// Renders Mermaid diagrams offline in a hidden WKWebView, only when a document contains one.
/// The library ships xz-compressed inside the app and network access is blocked.
@MainActor
final class MermaidRenderer: NSObject, WKNavigationDelegate {
    static let shared = MermaidRenderer()
    var onUpdate: (() -> Void)?

    private var webView: WKWebView?
    private var ready = false
    private var queue: [(key: String, code: String, dark: Bool)] = []
    private var pending = Set<String>()
    private var working = false
    private var results: [String: MermaidResult] = [:]
    private var order: [String] = []

    nonisolated static func key(_ code: String, dark: Bool) -> String { (dark ? "d:" : "l:") + code }

    static var isAvailable: Bool { libraryURL != nil && NSClassFromString("XCTestCase") == nil }

    private static var libraryURL: URL? {
        if let url = Bundle.main.url(forResource: "mermaid.min.js", withExtension: "xz") { return url }
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let local = source.appendingPathComponent("Resources/Mermaid/mermaid.min.js.xz")
        return FileManager.default.fileExists(atPath: local.path) ? local : nil
    }

    func result(for code: String, dark: Bool) -> MermaidResult? {
        let key = Self.key(code, dark: dark)
        if let result = results[key] { return result }
        guard Self.isAvailable else { return .failure("Mermaid is not available in this build.") }
        if !pending.contains(key) {
            pending.insert(key)
            queue.append((key, code, dark))
            start()
        }
        return nil
    }

    private func start() {
        if webView == nil { boot(); return }
        guard ready, !working, !queue.isEmpty else { return }
        working = true
        let job = queue.removeFirst()
        Task { await render(job) }
    }

    private func boot() {
        guard let url = Self.libraryURL, let data = try? Data(contentsOf: url),
              let decoded = try? (data as NSData).decompressed(using: .lzma) as Data,
              let script = String(data: decoded, encoding: .utf8) else {
            fail(all: "Unable to load Mermaid.")
            return
        }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800), configuration: configuration)
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = self
        webView = view
        let page = "<!doctype html><html><head><meta charset=utf-8><style>html,body{margin:0;background:transparent}#c{display:inline-block}</style></head><body><div id=c></div></body></html>"
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "mdlite-offline",
            encodedContentRuleList: #"[{"trigger":{"url-filter":"^https?:"},"action":{"type":"block"}},{"trigger":{"url-filter":"^wss?:"},"action":{"type":"block"}},{"trigger":{"url-filter":"^ftp:"},"action":{"type":"block"}}]"#) { [weak self] list, _ in
            Task { @MainActor in
                if let list { self?.webView?.configuration.userContentController.add(list) }
                self?.webView?.loadHTMLString(page, baseURL: nil)
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            self.ready = true
            self.start()
        }
    }

    private func render(_ job: (key: String, code: String, dark: Bool)) async {
        guard let webView else { return }
        let script = """
        mermaid.initialize({startOnLoad: false, securityLevel: 'strict', theme: dark ? 'dark' : 'neutral',
          fontFamily: '-apple-system, BlinkMacSystemFont, Helvetica, sans-serif',
          themeVariables: {background: 'transparent'}});
        const host = document.getElementById('c');
        host.innerHTML = '';
        const {svg} = await mermaid.render('m' + Math.random().toString(36).slice(2), code);
        host.innerHTML = svg;
        const el = host.querySelector('svg');
        el.style.maxWidth = 'none';
        const box = el.viewBox.baseVal;
        if (box && box.width) { el.setAttribute('width', box.width); el.setAttribute('height', box.height); }
        const r = host.getBoundingClientRect();
        return [Math.ceil(r.width), Math.ceil(r.height)];
        """
        var outcome: MermaidResult
        do {
            let value = try await webView.callAsyncJavaScript(script, arguments: ["code": job.code, "dark": job.dark], contentWorld: .page)
            let size = (value as? [Double]) ?? [0, 0]
            guard size.count == 2, size[0] > 0, size[1] > 0 else { throw NSError(domain: "Mermaid", code: 1) }
            webView.frame.size = NSSize(width: size[0], height: size[1])
            let snapshot = WKSnapshotConfiguration()
            snapshot.rect = CGRect(x: 0, y: 0, width: size[0], height: size[1])
            snapshot.afterScreenUpdates = true
            outcome = .image(try await webView.takeSnapshot(configuration: snapshot))
        } catch {
            let message = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
            outcome = .failure(message.replacingOccurrences(of: "Error: ", with: ""))
        }
        store(outcome, for: job.key)
        working = false
        onUpdate?()
        start()
    }

    private func store(_ result: MermaidResult, for key: String) {
        results[key] = result
        pending.remove(key)
        order.append(key)
        if order.count > 60 { results[order.removeFirst()] = nil }
    }

    private func fail(all message: String) {
        for job in queue { store(.failure(message), for: job.key) }
        queue.removeAll()
        onUpdate?()
    }
}
