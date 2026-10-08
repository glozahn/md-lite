import AppKit
import WebKit

/// A typeset formula: the picture and how far it sits below the text baseline.
struct MathImage {
    let image: NSImage
    let descent: CGFloat
}

/// Typesets TeX with MathJax in a hidden, offline WKWebView, only when a document contains math.
/// Same approach as Mermaid: the library ships xz-compressed and the network is blocked.
@MainActor
final class MathRenderer: NSObject, WKNavigationDelegate {
    static let shared = MathRenderer()
    var onUpdate: (() -> Void)?

    private struct Job { let key: String; let tex: String; let display: Bool; let dark: Bool; let size: CGFloat }

    private var webView: WKWebView?
    private var ready = false
    private var queue: [Job] = []
    private var pending = Set<String>()
    private var working = false
    private var results: [String: MathImage?] = [:]
    private var order: [String] = []
    private var updateScheduled = false
    /// Set when MathJax misbehaved once; formulas then stay as text until the app restarts.
    private var disabled = false


    static var isAvailable: Bool { libraryURL != nil && NSClassFromString("XCTestCase") == nil }

    private static var libraryURL: URL? {
        if let url = Bundle.main.url(forResource: "tex-svg.js", withExtension: "xz") { return url }
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let local = source.appendingPathComponent("Resources/MathJax/tex-svg.js.xz")
        return FileManager.default.fileExists(atPath: local.path) ? local : nil
    }

    /// The typeset formula, nil while it is being typeset (the document redraws when it is ready),
    /// or `.some(nil)` when MathJax could not read it.
    func result(for tex: String, display: Bool, dark: Bool, size: CGFloat) -> MathImage?? {
        let key = "\(display ? "D" : "I")\(dark ? "d" : "l")\(Int(size))|\(tex)"
        if let result = results[key] { return .some(result) }
        guard Self.isAvailable, !disabled else { return .some(nil) }
        if !pending.contains(key) {
            pending.insert(key)
            queue.append(Job(key: key, tex: tex, display: display, dark: dark, size: size))
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
            for job in queue { store(nil, for: job.key) }
            queue.removeAll()
            onUpdate?()
            return
        }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        // Self-contained SVG per formula, no automatic typesetting of the page.
        let setup = "window.MathJax = {startup: {typeset: false, ready: () => { MathJax.startup.defaultReady(); window.mdliteReady = true; }}, svg: {fontCache: 'none'}};"
        configuration.userContentController.addUserScript(WKUserScript(source: setup, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        configuration.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 400), configuration: configuration)
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = self
        webView = view
        let page = "<!doctype html><html><head><meta charset=utf-8><style>html,body{margin:0;background:transparent}#c{display:inline-block;padding:1px 0}</style></head><body><div id=c></div></body></html>"
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

    private func render(_ job: Job) async {
        guard let webView else { return }
        // A formula that takes this long means the engine is stuck: drop the web view (and its memory).
        let watchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled, let self, self.working else { return }
            self.giveUp()
        }
        defer { watchdog.cancel() }
        let script = """
        // The whole engine is in this one file; its loader still waits for a script URL it never gets
        // inside a page made from a string, so finish starting it by hand.
        if (typeof MathJax.tex2svg !== 'function' && MathJax.startup && MathJax.startup.defaultReady) {
          MathJax.startup.defaultReady();
        }
        if (typeof MathJax.tex2svg !== 'function') { throw new Error('MathJax did not start'); }
        const host = document.getElementById('c');
        host.style.fontSize = size + 'px';
        host.style.color = dark ? '#e6e8eb' : '#1f2328';
        host.innerHTML = '';
        const node = MathJax.tex2svg(tex, {display: display});
        const svg = node.querySelector('svg');
        if (!svg || node.querySelector('[data-mjx-error]') || svg.querySelector('[data-mml-node="merror"]')) { throw new Error('bad'); }
        if (display) { node.style.margin = '0'; }
        host.appendChild(node);
        const r = svg.getBoundingClientRect();
        const align = parseFloat(getComputedStyle(svg).verticalAlign) || 0;
        return [Math.ceil(r.width), Math.ceil(r.height), align, r.left, r.top];
        """
        var outcome: MathImage?
        do {
            let value = try await webView.callAsyncJavaScript(script, arguments: ["tex": job.tex, "display": job.display, "dark": job.dark, "size": job.size],
                                                              contentWorld: .page)
            let box = (value as? [Double]) ?? []
            guard box.count == 5, box[0] > 0, box[1] > 0 else { throw NSError(domain: "Math", code: 1) }
            let snapshot = WKSnapshotConfiguration()
            snapshot.rect = CGRect(x: box[3], y: box[4], width: box[0], height: box[1])
            snapshot.afterScreenUpdates = true
            let image = try await webView.takeSnapshot(configuration: snapshot)
            outcome = MathImage(image: image, descent: CGFloat(box[2]))
        } catch {
            outcome = nil
        }
        guard !disabled else { return }
        store(outcome, for: job.key)
        working = false
        scheduleUpdate()
        start()
    }

    private func giveUp() {
        disabled = true
        webView?.stopLoading()
        webView = nil
        ready = false
        working = false
        for job in queue { store(nil, for: job.key) }
        queue.removeAll()
        for key in pending { results[key] = .some(nil) }
        pending.removeAll()
        onUpdate?()
    }

    /// One redraw for a batch of formulas, not one per formula.
    private func scheduleUpdate() {
        guard !updateScheduled else { return }
        updateScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self else { return }
            self.updateScheduled = false
            if self.queue.isEmpty || !self.working { self.onUpdate?() } else { self.scheduleUpdate() }
        }
    }

    private func store(_ result: MathImage?, for key: String) {
        results[key] = .some(result)
        pending.remove(key)
        order.append(key)
        if order.count > 400 { results[order.removeFirst()] = nil }
    }
}

/// Finds TeX in text the way GitHub does: `$…$` inline (no space just inside the dollars,
/// not followed by a digit, not escaped) and `$$…$$` for display.
enum MathSyntax {
    struct Span { let range: Range<String.Index>; let tex: String }

    static func inlineSpans(in text: String) -> [Span] {
        guard text.contains("$") else { return [] }
        var spans: [Span] = []
        var index = text.startIndex
        while let open = text[index...].firstIndex(of: "$") {
            if open > text.startIndex, text[text.index(before: open)] == "\\" { index = text.index(after: open); continue }
            let afterOpen = text.index(after: open)
            guard afterOpen < text.endIndex, text[afterOpen] != "$", !text[afterOpen].isWhitespace else {
                index = afterOpen < text.endIndex ? text.index(after: afterOpen) : text.endIndex
                continue
            }
            var search = afterOpen
            var found: String.Index?
            while let close = text[search...].firstIndex(of: "$") {
                let before = text[text.index(before: close)]
                let after = text.index(after: close)
                if before != "\\", !before.isWhitespace, after == text.endIndex || !text[after].isNumber {
                    found = close
                    break
                }
                search = after
            }
            guard let close = found else { break }
            let tex = String(text[afterOpen..<close])
            if !tex.contains("\n\n") { spans.append(Span(range: open..<text.index(after: close), tex: tex)) }
            index = text.index(after: close)
        }
        return spans
    }

    /// The TeX of a paragraph that is a single `$$…$$` block, if it is one.
    static func displayBlock(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 4, trimmed.hasPrefix("$$"), trimmed.hasSuffix("$$") else { return nil }
        let inner = trimmed.dropFirst(2).dropLast(2)
        guard !inner.contains("$$") else { return nil }
        return inner.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
