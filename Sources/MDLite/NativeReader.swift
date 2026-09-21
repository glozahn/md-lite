import SwiftUI
import AppKit

struct NativeReader: NSViewRepresentable {
    @ObservedObject var store: ReaderStore

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let text = NSTextView()
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.isRichText = true
        text.usesFindBar = true
        text.isIncrementalSearchingEnabled = true
        text.textContainerInset = NSSize(width: 38, height: 32)
        text.minSize = NSSize(width: 0, height: 0)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.linkTextAttributes = [.foregroundColor: NSColor.systemTeal, .underlineStyle: NSUnderlineStyle.single.rawValue]
        scroll.documentView = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? NSTextView else { return }
        if !text.attributedString().isEqual(to: store.rendered.text) {
            let origin = scroll.contentView.bounds.origin
            text.textStorage?.setAttributedString(store.rendered.text)
            text.frame.size.width = scroll.contentSize.width
            scroll.contentView.scroll(to: origin)
        }
        if let range = store.scrollTarget, range.location <= text.string.utf16.count {
            text.scrollRangeToVisible(range)
            DispatchQueue.main.async { store.scrollTarget = nil }
        }
        if context.coordinator.findRequest != store.findRequest {
            context.coordinator.findRequest = store.findRequest
            scroll.window?.makeFirstResponder(text)
            let item = NSMenuItem()
            item.tag = NSTextFinder.Action.showFindInterface.rawValue
            text.performFindPanelAction(item)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var findRequest = 0 }
}
