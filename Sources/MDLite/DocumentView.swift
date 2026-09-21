import SwiftUI
import AppKit

enum DocumentMode: String, CaseIterable, Identifiable {
    case read, edit, source
    var id: String { rawValue }
}

/// Commands the store forwards to the live text views.
@MainActor
protocol DocumentEditing: AnyObject {
    func perform(_ action: FormatAction)
    func toggleTask(at offset: Int)
    func find(_ action: NSTextFinder.Action)
}

struct DocumentView: NSViewRepresentable {
    @ObservedObject var store: ReaderStore

    func makeCoordinator() -> DocumentController { DocumentController(store: store) }
    func makeNSView(context: Context) -> NSView { context.coordinator.container }
    func updateNSView(_ nsView: NSView, context: Context) { context.coordinator.sync() }
}

/// Owns the reading view (rendered) and the editor view (styled Markdown source).
@MainActor
final class DocumentController: NSObject, NSTextViewDelegate, DocumentEditing {
    let store: ReaderStore
    let container = NSView()
    private let readerScroll = NSScrollView()
    private let editorScroll = NSScrollView()
    let reader = MDTextView.make()
    let editor = MDTextView.make()

    private var renderVersion = -1
    private var contentVersion = -1
    private var scrollRequest = 0
    private var findRequest = 0
    private var styleKey = ""
    private var mode: DocumentMode?
    private var styler: MarkdownStyler?
    private var analysis = MarkdownStyler.Analysis()
    private var activeLines = NSRange(location: 0, length: 0)
    private var applying = false
    private var restyleWork: DispatchWorkItem?
    private var spyScheduled = false

    init(store: ReaderStore) {
        self.store = store
        super.init()
        for (scroll, text) in [(readerScroll, reader), (editorScroll, editor)] {
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.scrollerStyle = .overlay
            scroll.drawsBackground = false
            scroll.borderType = .noBorder
            scroll.automaticallyAdjustsContentInsets = false
            scroll.contentInsets = NSEdgeInsetsZero
            scroll.documentView = text
            scroll.autoresizingMask = [.width, .height]
            scroll.frame = container.bounds
            scroll.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
            container.addSubview(scroll)
            text.delegate = self
            text.onToggleTask = { [weak self] offset in self?.store.toggleTask(at: offset) }
            text.onOpenLink = { [weak self] url in _ = self?.store.follow(url) }
            text.localize = { [weak store] key in store?.t(key) ?? key }
        }
        reader.isEditable = false
        reader.isSelectable = true
        editor.isEditable = true
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.usesFontPanel = false
        editor.isContinuousSpellCheckingEnabled = false
        editorScroll.isHidden = true
        store.document = self
    }

    // MARK: Sync from the store

    func sync() {
        reader.columnWidth = store.columnWidth
        editor.columnWidth = store.mode == .source ? store.columnWidth + 60 : store.columnWidth
        reader.mdLayoutManager?.accent = store.accentNSColor
        editor.mdLayoutManager?.accent = store.accentNSColor
        for view in [reader, editor] {
            view.mdLayoutManager?.copiedLabel = store.t("Copiado")
            view.linkTextAttributes = [.foregroundColor: store.accentNSColor, .underlineStyle: NSUnderlineStyle.single.rawValue,
                                       .cursor: NSCursor.pointingHand]
        }

        if contentVersion != store.contentVersion {
            contentVersion = store.contentVersion
            applying = true
            editor.string = store.source
            editor.undoManager?.removeAllActions(withTarget: editor.textStorage as Any)
            editor.undoManager?.removeAllActions(withTarget: editor)
            applying = false
            editor.setSelectedRange(NSRange(location: 0, length: 0))
            styleKey = ""
        }
        let key = "\(store.mode.rawValue)|\(store.fontSize)|\(store.accent)|\(store.isDark)|\(store.fileURL?.path ?? "")|\(store.remoteImagesAllowed)"
        if key != styleKey, store.mode != .read {
            styleKey = key
            styler = MarkdownStyler(size: store.fontSize, accent: store.accentNSColor, live: store.mode == .edit,
                                    baseURL: store.fileURL?.deletingLastPathComponent())
            styler?.remoteImage = { [weak store] url in store?.cachedRemoteImage(url) }
            editor.isContinuousSpellCheckingEnabled = store.mode == .edit
            restyle()
        }
        if renderVersion != store.renderVersion {
            let sameDocument = renderVersion >= 0 && !store.didReplaceDocument
            renderVersion = store.renderVersion
            let origin = readerScroll.contentView.bounds.origin
            reader.textStorage?.setAttributedString(store.rendered.text)
            if sameDocument {
                readerScroll.contentView.scroll(to: origin)
                readerScroll.reflectScrolledClipView(readerScroll.contentView)
            }
            store.didReplaceDocument = false
        }
        if mode != store.mode { switchMode(to: store.mode) }
        if scrollRequest != store.scrollRequest.id {
            scrollRequest = store.scrollRequest.id
            performScroll(store.scrollRequest)
            DispatchQueue.main.async { self.updateSpy() }
        }
        if findRequest != store.findRequest {
            findRequest = store.findRequest
            find(.showFindInterface)
        }
    }

    private var visibleText: MDTextView { store.mode == .read ? reader : editor }

    private func switchMode(to new: DocumentMode) {
        let old = mode
        mode = new
        var anchor: Int?
        if let old { anchor = old == .read ? sourceOffsetAtReaderTop() : editor.topVisibleCharacter() }
        readerScroll.isHidden = new != .read
        editorScroll.isHidden = new == .read
        if new == .read {
            container.window?.makeFirstResponder(reader)
            if let anchor { DispatchQueue.main.async { self.reader.scrollCharacterToTop(self.store.rendered.renderedOffset(forSource: anchor)) } }
        } else {
            container.window?.makeFirstResponder(editor)
            if old == .read, let anchor {
                editor.setSelectedRange(NSRange(location: min(anchor, (editor.string as NSString).length), length: 0))
                DispatchQueue.main.async { self.editor.scrollCharacterToTop(anchor) }
            } else {
                DispatchQueue.main.async { self.editor.scrollRangeToVisible(self.editor.selectedRange()) }
            }
        }
        updateSpy()
    }

    private func sourceOffsetAtReaderTop() -> Int {
        guard let storage = reader.textStorage, storage.length > 0 else { return 0 }
        let index = reader.topVisibleCharacter()
        if let value = storage.attribute(.mdSource, at: index, effectiveRange: nil) as? Int { return value }
        var found = 0
        storage.enumerateAttribute(.mdSource, in: NSRange(location: 0, length: index), options: .reverse) { value, _, stop in
            if let value = value as? Int { found = value; stop.pointee = true }
        }
        return found
    }

    private func performScroll(_ request: ScrollRequest) {
        switch request.target {
        case .top:
            visibleText.scrollCharacterToTop(0)
        case .heading(let item):
            if store.mode == .read {
                reader.scrollCharacterToTop(item.range.location)
            } else {
                let location = min(item.source, (editor.string as NSString).length)
                editor.setSelectedRange(NSRange(location: location, length: 0))
                editor.scrollCharacterToTop(location)
            }
        case .none:
            break
        }
    }

    // MARK: Editor styling

    private func currentActiveLines() -> NSRange {
        guard let storage = editor.textStorage else { return NSRange(location: 0, length: 0) }
        return storage.mutableString.lineRange(for: editor.selectedRange())
    }

    private func restyle() {
        guard let styler, let storage = editor.textStorage else { return }
        analysis = styler.analyze(storage.string)
        activeLines = currentActiveLines()
        applying = true
        styler.apply(analysis, to: storage, active: activeLines)
        editor.layoutManager?.invalidateGlyphs(forCharacterRange: NSRange(location: 0, length: storage.length), changeInLength: 0, actualCharacterRange: nil)
        editor.typingAttributes = styler.baseAttributes
        applying = false
    }

    private func scheduleRestyle() {
        restyleWork?.cancel()
        let length = editor.textStorage?.length ?? 0
        guard length > 120_000 else { restyle(); return }
        let work = DispatchWorkItem { [weak self] in self?.restyle() }
        restyleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    func textDidChange(_ notification: Notification) {
        guard !applying, notification.object as? NSTextView === editor else { return }
        store.editorDidChange(editor.string)
        if mode != .read { scheduleRestyle() }
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !applying, notification.object as? NSTextView === editor, mode == .edit,
              let styler, let storage = editor.textStorage else { return }
        let new = currentActiveLines()
        guard new != activeLines else { return }
        let ranges = MarkdownStyler.sensitiveRanges(analysis, old: activeLines, new: new, in: storage)
        activeLines = new
        guard !ranges.isEmpty else { return }
        applying = true
        for range in ranges {
            let lines = storage.mutableString.lineRange(for: NSIntersectionRange(range, NSRange(location: 0, length: storage.length)))
            styler.apply(analysis, to: storage, active: new, range: lines)
            editor.layoutManager?.invalidateGlyphs(forCharacterRange: lines, changeInLength: 0, actualCharacterRange: nil)
        }
        applying = false
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard textView === editor else { return false }
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)): return editor.continueBlockOnNewline()
        case #selector(NSResponder.insertTab(_:)): return editor.shiftListItems(outdent: false)
        case #selector(NSResponder.insertBacktab(_:)): return editor.shiftListItems(outdent: true)
        default: return false
        }
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:)) else { return false }
        return store.follow(url)
    }

    // MARK: Scroll spy

    @objc private func scrolled(_ notification: Notification) {
        guard !spyScheduled else { return }
        spyScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.spyScheduled = false
            self?.updateSpy()
        }
    }

    private func updateSpy() {
        let outline = store.rendered.outline
        guard !outline.isEmpty else { store.setCurrentHeading(nil, progress: progress()); return }
        let heading: Int?
        if store.mode == .read {
            let index = reader.topVisibleCharacter() + 1
            heading = outline.last(where: { $0.range.location <= index })?.id ?? outline.first?.id
        } else {
            let index = editor.topVisibleCharacter() + 1
            heading = outline.last(where: { $0.source <= index })?.id ?? outline.first?.id
        }
        store.setCurrentHeading(heading, progress: progress())
    }

    private func progress() -> Double {
        let scroll = store.mode == .read ? readerScroll : editorScroll
        let total = (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height
        guard total > 1 else { return 1 }
        return min(1, max(0, scroll.contentView.bounds.minY / total))
    }

    // MARK: DocumentEditing

    func perform(_ action: FormatAction) {
        container.window?.makeFirstResponder(editor)
        editor.perform(action)
    }

    func toggleTask(at offset: Int) {
        guard let text = editor.textStorage?.mutableString, offset + 2 < text.length, text.character(at: offset) == 91 else { return }
        let checked = text.character(at: offset + 1) != 32
        editor.replace(NSRange(location: offset + 1, length: 1), with: checked ? " " : "x")
        if store.mode == .read { store.renderNow() }
    }

    func find(_ action: NSTextFinder.Action) {
        let target = visibleText
        container.window?.makeFirstResponder(target)
        let item = NSMenuItem()
        item.tag = action.rawValue
        target.performFindPanelAction(item)
    }
}
