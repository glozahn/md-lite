import AppKit

extension NSAttributedString.Key {
    /// Stack of block decorations (code boxes, quote bars, rules) drawn behind the text.
    static let mdBlocks = NSAttributedString.Key("MDBlocks")
    /// Characters laid out as null glyphs: present in the source, invisible on screen.
    static let mdConceal = NSAttributedString.Key("MDConceal")
    /// A one-character glyph drawn in place of the source character (list bullets).
    static let mdGlyph = NSAttributedString.Key("MDGlyph")
    /// UTF-16 offset in the Markdown source where the rendered block starts.
    static let mdSource = NSAttributedString.Key("MDSource")
    /// UTF-16 offset of a task list checkbox (`[`) in the Markdown source.
    static let mdTask = NSAttributedString.Key("MDTask")
    /// Editor-only: checkbox drawn over the `[ ]` characters. Value is a Bool (checked).
    static let mdTaskBox = NSAttributedString.Key("MDTaskBox")
    /// Background runs drawn as rounded capsules (inline code, kbd).
    static let mdRounded = NSAttributedString.Key("MDRounded")
    /// Editor-only: link target opened with Command-click.
    static let mdLinkURL = NSAttributedString.Key("MDLinkURL")
}

enum MDColors {
    static func dynamic(_ light: NSColor, _ dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
    }
    static func hex(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
    static let codeBackground = dynamic(NSColor(white: 0, alpha: 0.035), NSColor(white: 1, alpha: 0.05))
    static let codeBorder = dynamic(NSColor(white: 0, alpha: 0.055), NSColor(white: 1, alpha: 0.06))
    static let inlineCode = dynamic(NSColor(white: 0, alpha: 0.055), NSColor(white: 1, alpha: 0.1))
    static let codeText = dynamic(hex(0x24292F), hex(0xE6EDF3))
    static let keyword = dynamic(hex(0x9B2393), hex(0xFF7AB2))
    static let string = dynamic(hex(0xC41A16), hex(0xFF8170))
    static let comment = dynamic(hex(0x6E7781), hex(0x8B949E))
    static let number = dynamic(hex(0x1C00CF), hex(0xD9C97C))
    static let type = dynamic(hex(0x0B4F79), hex(0x5DD8FF))
    static let function = dynamic(hex(0x326D74), hex(0x67B7A4))
    static let attribute = dynamic(hex(0x815F03), hex(0xE3A869))
    static let added = dynamic(hex(0x1A7F37), hex(0x7EE787))
    static let removed = dynamic(hex(0xCF222E), hex(0xFF7B72))
    static let meta = dynamic(hex(0x6639BA), hex(0xD2A8FF))
    static let note = dynamic(hex(0x0969DA), hex(0x4493F8))
    static let tip = dynamic(hex(0x1A7F37), hex(0x3FB950))
    static let important = dynamic(hex(0x8250DF), hex(0xAB7DF8))
    static let warning = dynamic(hex(0x9A6700), hex(0xD29922))
    static let caution = dynamic(hex(0xCF222E), hex(0xF85149))
}

/// Block-level ornament drawn by `MDLayoutManager` behind a character range.
final class MDBlockDecoration: NSObject {
    enum Kind { case code, diagram, quote, alert, rule, headingRule, image }
    let kind: Kind
    var range = NSRange(location: 0, length: 0)
    var indent: CGFloat = 0
    var padTop: CGFloat = 0
    var padBottom: CGFloat = 0
    var color: NSColor = .tertiaryLabelColor
    var label: String?
    var code: String?
    var image: NSImage?
    var imageSize: NSSize = .zero
    var copyRect: NSRect?
    var copiedAt: Date?
    init(_ kind: Kind) { self.kind = kind }
}

/// Image attachment that shrinks to the available line width.
final class MDImageCell: NSTextAttachmentCell {
    let picture: NSImage
    let preferred: NSSize
    let baseline: CGFloat

    init(image: NSImage, size: NSSize, baseline: CGFloat = 0) {
        picture = image
        preferred = size
        self.baseline = baseline
        super.init(imageCell: nil)
    }
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func cellSize() -> NSSize { preferred }
    override func wantsToTrackMouse() -> Bool { false }
    override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect,
                            glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        let available = max(24, lineFrag.width - textContainer.lineFragmentPadding * 2 - 2)
        let scale = min(1, available / max(1, preferred.width))
        return NSRect(x: 0, y: baseline, width: preferred.width * scale, height: preferred.height * scale)
    }
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        picture.draw(in: cellFrame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                     hints: [.interpolation: NSImageInterpolation.high.rawValue])
    }
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex charIndex: Int, layoutManager: NSLayoutManager) {
        draw(withFrame: cellFrame, in: controlView)
    }
}

enum MDSymbols {
    private static var cache: [String: NSImage] = [:]
    static func image(_ name: String, size: CGFloat, color: NSColor, weight: NSFont.Weight = .regular) -> NSImage? {
        let key = "\(name)|\(size)|\(color.hash)|\(weight.rawValue)"
        if let cached = cache[key] { return cached }
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        cache[key] = image
        return image
    }
}

/// TextKit 1 layout manager: hides Markdown syntax, swaps bullet glyphs and draws block ornaments.
final class MDLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {
    var accent: NSColor = .controlAccentColor
    var copyLabel = "Copy"
    var copiedLabel = "Copied"

    override init() {
        super.init()
        delegate = self
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Glyph generation

    func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
                       characterIndexes charIndexes: UnsafePointer<Int>, font aFont: NSFont,
                       forGlyphRange glyphRange: NSRange) -> Int {
        guard let storage = textStorage, glyphRange.length > 0 else { return 0 }
        let first = charIndexes[0], last = charIndexes[glyphRange.length - 1]
        guard first <= last, last < storage.length else { return 0 }
        var special = false
        storage.enumerateAttributes(in: NSRange(location: first, length: last - first + 1)) { attrs, _, stop in
            if attrs[.mdConceal] != nil || attrs[.mdGlyph] != nil { special = true; stop.pointee = true }
        }
        guard special else { return 0 }
        var newProps = Array(UnsafeBufferPointer(start: props, count: glyphRange.length))
        var newGlyphs = Array(UnsafeBufferPointer(start: glyphs, count: glyphRange.length))
        for i in 0..<glyphRange.length {
            let index = charIndexes[i]
            if storage.attribute(.mdConceal, at: index, effectiveRange: nil) != nil {
                newProps[i] = .null
            } else if let replacement = storage.attribute(.mdGlyph, at: index, effectiveRange: nil) as? String,
                      var unit = replacement.utf16.first {
                var glyph: CGGlyph = 0
                if CTFontGetGlyphsForCharacters(aFont as CTFont, &unit, &glyph, 1) { newGlyphs[i] = glyph }
            }
        }
        layoutManager.setGlyphs(newGlyphs, properties: newProps, characterIndexes: charIndexes, font: aFont, forGlyphRange: glyphRange)
        return glyphRange.length
    }

    // MARK: Drawing

    override func fillBackgroundRectArray(_ rectArray: UnsafePointer<NSRect>, count rectCount: Int,
                                          forCharacterRange charRange: NSRange, color: NSColor) {
        // Table cells also paint their background through here; only text backgrounds get rounded.
        guard let storage = textStorage, charRange.location < storage.length,
              storage.attribute(.mdRounded, at: charRange.location, effectiveRange: nil) != nil,
              (storage.attribute(.backgroundColor, at: charRange.location, effectiveRange: nil) as? NSColor) == color else {
            super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color)
            return
        }
        let font = storage.attribute(.font, at: charRange.location, effectiveRange: nil) as? NSFont
        let textHeight = (font.map { $0.ascender - $0.descender } ?? 14) + 3
        color.setFill()
        for i in 0..<rectCount {
            var rect = rectArray[i]
            if rect.height > textHeight { rect.size.height = textHeight }
            NSBezierPath(roundedRect: rect.insetBy(dx: -2.5, dy: 0), xRadius: 4, yRadius: 4).fill()
        }
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let container = textContainers.first, storage.length > 0 else { return }
        let chars = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        var seen = Set<ObjectIdentifier>()
        storage.enumerateAttribute(.mdBlocks, in: chars) { value, _, _ in
            guard let list = value as? [MDBlockDecoration] else { return }
            for decoration in list where seen.insert(ObjectIdentifier(decoration)).inserted {
                draw(decoration, origin: origin, container: container)
            }
        }
        storage.enumerateAttribute(.mdTaskBox, in: chars) { value, range, _ in
            guard let checked = value as? Bool else { return }
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let rect = boundingRect(forGlyphRange: glyphs, in: container).offsetBy(dx: origin.x, dy: origin.y)
            let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
            let side = (font?.pointSize ?? 16) * 1.02
            let symbol = MDSymbols.image(checked ? "checkmark.square.fill" : "square", size: side,
                                         color: checked ? accent : .tertiaryLabelColor)
            let box = NSRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
            symbol?.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    /// Union of the glyph areas (without paragraph spacing) of a character range.
    private func usedBounds(_ range: NSRange, in container: NSTextContainer) -> (used: NSRect, firstLine: NSRect)? {
        guard let storage = textStorage, range.length > 0, NSMaxRange(range) <= storage.length else { return nil }
        let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        var used = NSRect.null
        var firstLine = NSRect.null
        enumerateLineFragments(forGlyphRange: glyphs) { lineRect, usedRect, _, _, _ in
            if firstLine.isNull { firstLine = lineRect }
            let slice = NSRect(x: lineRect.minX, y: usedRect.minY, width: lineRect.width, height: usedRect.height)
            used = used.isNull ? slice : used.union(slice)
        }
        return used.isNull ? nil : (used, firstLine)
    }

    private func draw(_ decoration: MDBlockDecoration, origin: NSPoint, container: NSTextContainer) {
        guard let (bounds, firstLine) = usedBounds(decoration.range, in: container) else { return }
        let padding = container.lineFragmentPadding
        let left = origin.x + padding + decoration.indent
        let width = max(0, container.size.width - padding * 2 - decoration.indent)
        switch decoration.kind {
        case .code, .diagram:
            let rect = NSRect(x: left, y: origin.y + bounds.minY - decoration.padTop, width: width,
                              height: bounds.height + decoration.padTop + decoration.padBottom)
            let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
            MDColors.codeBackground.setFill()
            path.fill()
            MDColors.codeBorder.setStroke()
            path.lineWidth = 1
            path.stroke()
            if decoration.kind == .code { drawCodeHeader(decoration, in: rect) }
        case .quote, .alert:
            let rect = NSRect(x: left, y: origin.y + bounds.minY - 4, width: width, height: bounds.height + 8)
            if decoration.kind == .alert {
                decoration.color.withAlphaComponent(0.06).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
            }
            decoration.color.setFill()
            NSBezierPath(roundedRect: NSRect(x: rect.minX, y: rect.minY, width: 3, height: rect.height), xRadius: 1.5, yRadius: 1.5).fill()
        case .rule:
            NSColor.separatorColor.setFill()
            NSRect(x: left, y: origin.y + bounds.midY.rounded(), width: width, height: 1).fill()
        case .headingRule:
            NSColor.separatorColor.withAlphaComponent(0.6).setFill()
            NSRect(x: left, y: origin.y + bounds.maxY + 6, width: width, height: 1).fill()
        case .image:
            guard let image = decoration.image else { return }
            let scale = min(1, width / max(1, decoration.imageSize.width))
            let size = NSSize(width: decoration.imageSize.width * scale, height: decoration.imageSize.height * scale)
            let rect = NSRect(x: left, y: origin.y + firstLine.minY + 6, width: size.width, height: size.height)
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                       hints: [.interpolation: NSImageInterpolation.high.rawValue])
        }
    }

    private func drawCodeHeader(_ decoration: MDBlockDecoration, in rect: NSRect) {
        guard decoration.padTop >= 24 else { return }
        let labelFont = NSFont.systemFont(ofSize: 10.5, weight: .medium)
        if let label = decoration.label, !label.isEmpty {
            NSAttributedString(string: label, attributes: [.font: labelFont, .foregroundColor: NSColor.tertiaryLabelColor])
                .draw(at: NSPoint(x: rect.minX + 16, y: rect.minY + 9))
        }
        guard decoration.code != nil else { return }
        let copied = decoration.copiedAt.map { Date().timeIntervalSince($0) < 1.4 } ?? false
        let icon = MDSymbols.image(copied ? "checkmark" : "doc.on.doc", size: 11.5,
                                   color: copied ? accent : .tertiaryLabelColor, weight: .medium)
        let iconRect = NSRect(x: rect.maxX - 30, y: rect.minY + 8, width: 15, height: 15)
        icon?.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        var hit = iconRect.insetBy(dx: -8, dy: -6)
        if copied {
            let text = NSAttributedString(string: copiedLabel, attributes: [.font: labelFont, .foregroundColor: accent])
            let x = iconRect.minX - text.size().width - 5
            text.draw(at: NSPoint(x: x, y: rect.minY + 9))
            hit = hit.union(NSRect(x: x, y: hit.minY, width: iconRect.minX - x, height: hit.height))
        }
        decoration.copyRect = hit
    }
}

/// Text view with a centered reading column, clickable code-copy buttons and task checkboxes.
final class MDTextView: NSTextView {
    var columnWidth: CGFloat = 760 { didSet { updateInsets() } }
    var minimumInset: CGFloat = 36
    var verticalInset: CGFloat = 30
    var onToggleTask: ((Int) -> Void)?
    var onOpenLink: ((URL) -> Void)?
    var localize: (String) -> String = { $0 }

    static func make() -> MDTextView {
        let storage = NSTextStorage()
        let layout = MDLayoutManager()
        layout.allowsNonContiguousLayout = true
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 6
        layout.addTextContainer(container)
        let view = MDTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.drawsBackground = false
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.smartInsertDeleteEnabled = false
        return view
    }

    var mdLayoutManager: MDLayoutManager? { layoutManager as? MDLayoutManager }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateInsets()
    }

    /// The clip view scrolls by moving its bounds; the document itself always sits at the origin.
    /// Autoresizing from a zero-sized clip view would otherwise push it above the visible area.
    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(.zero)
    }

    func updateInsets() {
        let horizontal = max(minimumInset, floor((bounds.width - columnWidth) / 2))
        let inset = NSSize(width: horizontal, height: verticalInset)
        if textContainerInset != inset { textContainerInset = inset }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let decoration = codeBlock(at: point), let rect = decoration.copyRect, rect.contains(point), let code = decoration.code {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(code, forType: .string)
            decoration.copiedAt = Date()
            setNeedsDisplay(rect.insetBy(dx: -90, dy: -4))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.needsDisplay = true }
            return
        }
        if let index = characterIndex(at: point), let storage = textStorage {
            if let task = storage.attribute(.mdTask, at: index, effectiveRange: nil) as? Int,
               storage.attribute(.mdConceal, at: index, effectiveRange: nil) == nil,
               !isEditable || storage.attribute(.mdTaskBox, at: index, effectiveRange: nil) != nil {
                onToggleTask?(task)
                return
            }
            if isEditable, event.modifierFlags.contains(.command),
               let url = storage.attribute(.mdLinkURL, at: index, effectiveRange: nil) as? URL {
                onOpenLink?(url)
                return
            }
        }
        super.mouseDown(with: event)
    }

    private func codeBlock(at point: NSPoint) -> MDBlockDecoration? {
        guard let layout = layoutManager, let container = textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        let local = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = layout.glyphIndex(for: local, in: container)
        let index = min(storage.length - 1, layout.characterIndexForGlyph(at: glyph))
        let list = storage.attribute(.mdBlocks, at: index, effectiveRange: nil) as? [MDBlockDecoration]
        return list?.last(where: { $0.kind == .code && $0.copyRect != nil })
    }

    func characterIndex(at point: NSPoint) -> Int? {
        guard let layout = layoutManager, let container = textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        let local = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = layout.glyphIndex(for: local, in: container, fractionOfDistanceThroughGlyph: nil)
        guard glyph < layout.numberOfGlyphs else { return nil }
        let rect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        guard rect.insetBy(dx: -3, dy: -2).contains(local) else { return nil }
        return layout.characterIndexForGlyph(at: glyph)
    }

    /// Character index of the first line visible at the top of the scroll view.
    func topVisibleCharacter() -> Int {
        guard let layout = layoutManager, let container = textContainer, let storage = textStorage, storage.length > 0 else { return 0 }
        let point = NSPoint(x: 8, y: visibleRect.minY - textContainerOrigin.y + 12)
        let glyph = layout.glyphIndex(for: point, in: container)
        return min(storage.length - 1, layout.characterIndexForGlyph(at: glyph))
    }

    /// Scrolls so the line containing `index` sits near the top of the viewport.
    func scrollCharacterToTop(_ index: Int, offset: CGFloat = 14) {
        guard let layout = layoutManager, let container = textContainer, let scroll = enclosingScrollView,
              let storage = textStorage else { return }
        let clamped = max(0, min(index, max(0, storage.length - 1)))
        guard storage.length > 0 else { scroll.contentView.scroll(to: .zero); return }
        let glyph = layout.glyphIndexForCharacter(at: clamped)
        layout.ensureLayout(forGlyphRange: NSRange(location: 0, length: min(layout.numberOfGlyphs, glyph + 1)))
        _ = container
        let line = layout.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
        let maxY = max(0, frame.height - scroll.contentView.bounds.height)
        let y = min(maxY, max(0, line.minY + textContainerOrigin.y - offset - (index == 0 ? 40 : 0)))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}
