import AppKit

/// A Markdown document as slides: a `---` line with a blank line before it starts a new slide
/// (right under a line of text, `---` stays a heading underline, as in CommonMark).
enum Slides {
    static func split(_ source: String) -> [String] {
        var text = source
        if let front = GFM.frontMatter(in: source) { text = front.masked }
        var slides: [String] = []
        var current: [String] = []
        var fence: String?
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let open = fence {
                if trimmed.hasPrefix(open) { fence = nil }
            } else if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fence = String(trimmed.prefix(3))
            } else if trimmed == "---", current.last.map({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? true {
                slides.append(current.joined(separator: "\n"))
                current = []
                continue
            }
            current.append(line)
        }
        slides.append(current.joined(separator: "\n"))
        return slides.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

/// View ▸ Present: one slide at a time over the whole screen. Arrows, space and clicks move;
/// Escape ends. Text is set large and shrinks only when a slide would not fit.
@MainActor
final class Presentation: NSObject, NSWindowDelegate {
    private static var current: Presentation?

    private let store: ReaderStore
    private let slides: [String]
    private var index: Int
    private let window: PresentationWindow
    private let text = MDTextView.make()
    private let counter = NSTextField(labelWithString: "")
    private var observer: NSObjectProtocol?
    private var previousOptions: NSApplication.PresentationOptions = []

    static func start(_ store: ReaderStore) {
        guard current == nil, store.kind.isMarkdown else { return }
        let slides = Slides.split(store.source)
        guard !slides.isEmpty else { return }
        let presentation = Presentation(store: store, slides: slides)
        current = presentation
        presentation.show()
    }

    private init(store: ReaderStore, slides: [String]) {
        self.store = store
        self.slides = slides
        // Start on the slide you were reading.
        let offset = store.document?.sourceOffsetAtTop() ?? 0
        var start = 0
        var consumed = 0
        let source = store.source as NSString
        for (number, slide) in slides.enumerated() {
            let found = source.range(of: slide, options: [], range: NSRange(location: min(consumed, source.length), length: source.length - min(consumed, source.length)))
            guard found.location != NSNotFound else { break }
            if found.location <= offset { start = number }
            consumed = NSMaxRange(found)
        }
        index = start
        let screen = store.workbench?.window?.screen ?? NSScreen.main ?? NSScreen.screens[0]
        window = PresentationWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
    }

    private func show() {
        let dark = store.isDark
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.backgroundColor = dark ? NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.11, alpha: 1) : NSColor(calibratedRed: 0.985, green: 0.98, blue: 0.97, alpha: 1)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.collectionBehavior = [.fullScreenNone, .canJoinAllSpaces]
        window.onKey = { [weak self] event in self?.key(event) ?? false }
        window.onClick = { [weak self] event in self?.move(event.modifierFlags.contains(.shift) ? -1 : 1) }

        let content = NSView(frame: window.contentRect(forFrameRect: window.frame))
        text.isEditable = false
        text.isSelectable = false
        text.frame = content.bounds
        text.autoresizingMask = [.width, .height]
        text.mdLayoutManager?.accent = store.accentNSColor
        text.onOpenLink = { NSWorkspace.shared.open($0) }
        content.addSubview(text)

        counter.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        counter.textColor = .tertiaryLabelColor
        counter.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(counter)
        NSLayoutConstraint.activate([
            counter.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            counter.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -22)
        ])
        window.contentView = content

        previousOptions = NSApp.presentationOptions
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        window.makeKeyAndOrderFront(nil)
        NSCursor.setHiddenUntilMouseMoves(true)
        // Diagrams and formulas arrive later; draw the slide again when they do.
        observer = NotificationCenter.default.addObserver(forName: .mermaidDidRender, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.render() }
        }
        render()
    }

    private func key(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53: end()                                    // escape
        case 124, 125, 121, 36, 76: move(1)               // right, down, page down, return, enter
        case 123, 126, 116: move(-1)                      // left, up, page up
        case 49: move(event.modifierFlags.contains(.shift) ? -1 : 1)  // space
        case 115: go(to: 0)                               // home
        case 119: go(to: slides.count - 1)                // end
        default:
            if event.charactersIgnoringModifiers == "q" || (event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == ".") {
                end()
            } else {
                return false
            }
        }
        return true
    }

    private func move(_ step: Int) {
        if index + step >= slides.count { end(); return }
        go(to: index + step)
    }

    private func go(to number: Int) {
        let clamped = max(0, min(slides.count - 1, number))
        guard clamped != index else { return }
        index = clamped
        render()
    }

    private func render() {
        let bounds = window.contentView?.bounds ?? window.frame
        let width = min(bounds.width - 160, 1100)
        let available = bounds.height - 120
        // Large type first, smaller only when the slide does not fit.
        var size = min(40, max(24, bounds.height / 26))
        var rendered = NSAttributedString()
        var height: CGFloat = 0
        while true {
            rendered = attributed(slides[index], size: size, width: width)
            height = measure(rendered, width: width)
            if height <= available || size <= 14 { break }
            size = max(14, (size * 0.88).rounded(.down))
        }
        text.columnWidth = width
        text.minimumInset = 80
        text.verticalInset = max(40, (bounds.height - height) / 2)
        text.updateInsets()
        text.textStorage?.setAttributedString(rendered)
        text.setSelectedRange(NSRange(location: 0, length: 0))
        counter.stringValue = "\(index + 1) / \(slides.count)"
    }

    private func attributed(_ slide: String, size: CGFloat, width: CGFloat) -> NSAttributedString {
        let renderer = MarkdownRenderer(size: size, baseURL: (store.fileURL ?? store.remoteURL)?.deletingLastPathComponent(),
                                        accent: store.accentNSColor, language: store.resolvedLanguage)
        let dark = store.isDark
        renderer.dark = dark
        renderer.maxImageWidth = width
        renderer.remoteImage = { [weak store] url in store?.cachedRemoteImage(url) }
        renderer.mermaid = { code in MermaidRenderer.shared.result(for: code, dark: dark) }
        renderer.math = { tex, display in MathRenderer.shared.result(for: tex, display: display, dark: dark, size: size) }
        return renderer.render(slide).text
    }

    private func measure(_ string: NSAttributedString, width: CGFloat) -> CGFloat {
        let storage = NSTextStorage(attributedString: string)
        let layout = MDLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 6
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        return ceil(layout.usedRect(for: container).height)
    }

    private func end() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        NSApp.presentationOptions = previousOptions
        window.orderOut(nil)
        store.workbench?.window?.makeKeyAndOrderFront(nil)
        Presentation.current = nil
    }

    func windowDidResignKey(_ notification: Notification) {
        // Switching away with ⌘Tab ends the show, so the menu bar and Dock come back.
        if Presentation.current === self { end() }
    }
}

/// A borderless window that can still take the keyboard.
final class PresentationWindow: NSWindow {
    var onKey: ((NSEvent) -> Bool)?
    var onClick: ((NSEvent) -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onKey?(event) == true { return }
        if event.type == .leftMouseUp, let onClick {
            // Links still open; anywhere else, a click moves on.
            if let view = contentView?.hitTest(event.locationInWindow) as? MDTextView,
               let index = view.characterIndexForInsertion(at: view.convert(event.locationInWindow, from: nil)) as Int?,
               index < (view.textStorage?.length ?? 0), view.textStorage?.attribute(.link, at: index, effectiveRange: nil) != nil {
                super.sendEvent(event)
                return
            }
            onClick(event)
            return
        }
        super.sendEvent(event)
    }
}
