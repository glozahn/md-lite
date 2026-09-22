import AppKit
import Markdown

struct OutlineItem: Identifiable, Equatable {
    let id: Int
    let title: String
    let level: Int
    /// Range in the rendered reading text.
    let range: NSRange
    /// UTF-16 offset of the heading in the Markdown source.
    var source: Int = 0
    var anchor: String = ""
}

struct RenderedDocument {
    let text: NSAttributedString
    let outline: [OutlineItem]
    /// Sorted pairs mapping source offsets to rendered offsets, one per rendered block.
    var blocks: [(source: Int, rendered: Int)] = []
    var remoteImages: [URL] = []

    func renderedOffset(forSource offset: Int) -> Int {
        guard var best = blocks.first else { return 0 }
        for block in blocks { if block.source <= offset { best = block } else { break } }
        return best.rendered
    }
}

/// CommonMark + GitHub Flavored Markdown rendered to native attributed text. No browser runtime.
final class MarkdownRenderer {
    typealias Attributes = [NSAttributedString.Key: Any]

    let size: CGFloat
    let baseURL: URL?
    let accent: NSColor
    let language: String
    var dark = false
    var maxImageWidth: CGFloat = 760
    /// Returns an already downloaded remote image, or nil when remote images are blocked or pending.
    var remoteImage: (URL) -> NSImage? = { _ in nil }
    /// Returns a rendered Mermaid diagram, a failure, or nil while it is still being drawn.
    var mermaid: ((String) -> MermaidResult?)?

    private struct Context {
        var indent: CGFloat = 0
        var color: NSColor = .labelColor
        var spacing: CGFloat?
    }

    private struct HTMLFrame {
        let name: String
        let attributes: [String: String]
        var start = 0
        var decoration: MDBlockDecoration?
        var counter = 1
        var saved: (NSMutableAttributedString, [MDBlockDecoration])?
    }

    private struct TableCell {
        let text: NSAttributedString
        let header: Bool
        let alignment: NSTextAlignment
    }

    private final class HTMLTable {
        var rows: [[TableCell]] = []
        var row: [TableCell]?
        var inHead = false
    }

    private var output = NSMutableAttributedString()
    private var outline: [OutlineItem] = []
    private var blocks: [(source: Int, rendered: Int)] = []
    private var remote: [URL] = []
    private var map = SourceMap("")
    private var source: NSString = ""
    private var decorations: [MDBlockDecoration] = []
    private var html: [HTMLFrame] = []
    private var htmlTables: [HTMLTable] = []
    private var hiddenDepth = 0
    private var linkDepth = 0
    private var listDepth = 0
    private var capturing = 0
    private var slugs: [String: Int] = [:]
    private var currentSource = 0
    private var pictureSource: String?

    init(size: CGFloat = 17, baseURL: URL? = nil, accent: NSColor = .controlAccentColor, language: String = "en") {
        self.size = size
        self.baseURL = baseURL
        self.accent = accent
        self.language = language
    }

    func render(_ text: String) -> RenderedDocument {
        output = NSMutableAttributedString()
        outline = []; blocks = []; remote = []; decorations = []; html = []; htmlTables = []
        hiddenDepth = 0; linkDepth = 0; listDepth = 0; capturing = 0; slugs = [:]; pictureSource = nil
        source = text as NSString
        map = SourceMap(text)
        var parseText = text
        if let front = GFM.frontMatter(in: text) {
            parseText = front.masked
            renderCodeBox(front.yaml, language: "yaml", label: "front matter", Context())
            blocks.append((0, 0))
        }
        let document = Document(parsing: parseText, options: [.disableSmartOpts])
        for child in document.children { block(child, Context()) }
        while !html.isEmpty { closeHTMLFrame(Context()) }
        return RenderedDocument(text: output.copy() as! NSAttributedString, outline: outline, blocks: blocks, remoteImages: remote)
    }

    // MARK: Output helpers

    private var bodyFont: NSFont { .systemFont(ofSize: size) }

    private func paragraphStyle(_ context: Context, spacing: CGFloat? = nil) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = size * 0.3
        style.paragraphSpacing = spacing ?? context.spacing ?? size * 0.75
        style.headIndent = context.indent
        style.firstLineHeadIndent = context.indent
        if let alignment = htmlAlignment { style.alignment = alignment }
        return style
    }

    private func attributes(_ context: Context, font: NSFont? = nil, spacing: CGFloat? = nil) -> Attributes {
        [.font: font ?? bodyFont, .foregroundColor: context.color, .paragraphStyle: paragraphStyle(context, spacing: spacing)]
    }

    private func append(_ string: String, _ attributes: Attributes) {
        guard !string.isEmpty else { return }
        var attributes = attributes
        if !decorations.isEmpty { attributes[.mdBlocks] = decorations }
        output.append(NSAttributedString(string: string, attributes: attributes))
    }

    private func append(_ text: NSAttributedString) {
        let start = output.length
        output.append(text)
        if !decorations.isEmpty { output.addAttribute(.mdBlocks, value: decorations, range: NSRange(location: start, length: text.length)) }
    }

    private func appendAttachment(_ cell: NSTextAttachmentCell, _ attributes: Attributes) {
        let attachment = NSTextAttachment()
        attachment.attachmentCell = cell
        let text = NSMutableAttributedString(attachment: attachment)
        text.addAttributes(attributes, range: NSRange(location: 0, length: text.length))
        append(text)
    }

    private var lastCharacter: unichar? { output.length > 0 ? output.mutableString.character(at: output.length - 1) : nil }
    private var atLineStart: Bool { lastCharacter.map { $0 == 10 || $0 == 0x2028 } ?? true }

    private func ensureNewline(_ attributes: Attributes) {
        if let last = lastCharacter, last != 10 { append("\n", attributes) }
    }

    private func mark(_ node: Markup, from start: Int) {
        guard capturing == 0, output.length > start, let range = map.range(node.range) else { return }
        output.addAttribute(.mdSource, value: range.location, range: NSRange(location: start, length: output.length - start))
        blocks.append((range.location, start))
    }

    private func addDecoration(_ decoration: MDBlockDecoration, over range: NSRange) {
        decoration.range = range
        output.enumerateAttribute(.mdBlocks, in: range) { value, run, _ in
            output.addAttribute(.mdBlocks, value: ((value as? [MDBlockDecoration]) ?? []) + [decoration], range: run)
        }
    }

    private func capture(_ body: () -> Void) -> NSMutableAttributedString {
        let saved = output, savedDecorations = decorations
        output = NSMutableAttributedString()
        decorations = []
        capturing += 1
        body()
        capturing -= 1
        let result = output
        output = saved
        decorations = savedDecorations
        return result
    }

    private func addOutline(title: String, level: Int, range: NSRange, source: Int) {
        guard capturing == 0 else { return }
        let clean = title.replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let base = GFM.slug(clean)
        let count = slugs[base, default: 0]
        slugs[base] = count + 1
        outline.append(OutlineItem(id: outline.count, title: clean, level: level, range: range, source: source,
                                   anchor: count == 0 ? base : "\(base)-\(count)"))
    }

    private func localized(_ key: String) -> String { ReaderLanguage.text(key, language: language) }

    // MARK: Blocks

    private func block(_ node: Markup, _ context: Context) {
        let start = output.length
        switch node {
        case let heading as Heading:
            renderHeading(heading, context)
            mark(node, from: start)
        case let code as CodeBlock:
            renderCode(code.code, info: code.language, context)
            mark(node, from: start)
        case let quote as BlockQuote:
            renderQuote(quote, context)
        case let list as OrderedList:
            renderList(Array(list.listItems), ordered: true, start: Int(list.startIndex), context)
        case let list as UnorderedList:
            renderList(Array(list.listItems), ordered: false, start: 1, context)
        case is ThematicBreak:
            renderRule(context)
            mark(node, from: start)
        case let block as HTMLBlock:
            currentSource = map.range(block.range)?.location ?? currentSource
            renderHTML(block.rawHTML, context)
            if htmlTables.isEmpty { ensureNewline(htmlAttributes(context)) }
            mark(node, from: start)
        case let table as Table:
            renderTable(table, context)
            mark(node, from: start)
        case let paragraph as Paragraph:
            renderParagraph(paragraph, context)
            mark(node, from: start)
        default:
            for child in node.children { block(child, context) }
        }
    }

    private func renderParagraph(_ paragraph: Paragraph, _ context: Context, skipping: Int = 0, attributes: Attributes? = nil) {
        let attributes = attributes ?? self.attributes(context)
        let start = output.length
        let openFrames = html.count
        for (index, child) in paragraph.children.enumerated() where index >= skipping { inline(child, attributes) }
        closeInlineFrames(to: openFrames)
        guard output.length > start else { return }
        append("\n", attributes)
    }

    private func headingAttributes(_ level: Int, _ context: Context) -> Attributes {
        let scale: [CGFloat] = [2.0, 1.5, 1.25, 1.08, 0.97, 0.9]
        let font = NSFont.systemFont(ofSize: size * scale[level - 1], weight: level == 1 ? .bold : .semibold)
        let style = paragraphStyle(context)
        style.paragraphSpacingBefore = output.length == 0 ? 0 : (level <= 2 ? size * 1.45 : size * 1.1)
        style.paragraphSpacing = level <= 2 ? size * 1.0 : size * 0.55
        style.lineSpacing = 2
        return [.font: font, .foregroundColor: level == 6 ? NSColor.secondaryLabelColor : context.color, .paragraphStyle: style]
    }

    private func renderHeading(_ heading: Heading, _ context: Context) {
        let level = min(max(heading.level, 1), 6)
        let attributes = headingAttributes(level, context)
        let start = output.length
        let openFrames = html.count
        for child in heading.children { inline(child, attributes) }
        closeInlineFrames(to: openFrames)
        append("\n", attributes)
        let range = NSRange(location: start, length: output.length - start)
        addOutline(title: heading.plainText, level: level, range: range, source: map.range(heading.range)?.location ?? 0)
        if level <= 2 {
            let rule = MDBlockDecoration(.headingRule)
            rule.indent = context.indent
            addDecoration(rule, over: range)
        }
    }

    private func renderCode(_ code: String, info: String?, _ context: Context) {
        let language = info?.split(whereSeparator: { $0 == " " || $0 == "{" || $0 == "," }).first.map(String.init)
        var text = code
        if text.hasSuffix("\n") { text.removeLast() }
        if language?.lowercased() == "mermaid", let mermaid {
            switch mermaid(text) {
            case .image(let image)?: renderDiagram(image, context)
            case .failure(let message)?: renderCodeBox(text, language: nil, label: "mermaid", context, note: message)
            case nil: renderCodeBox(text, language: nil, label: "mermaid · " + localized("dibujando…"), context)
            }
            return
        }
        renderCodeBox(text, language: language, label: language?.lowercased(), context)
    }

    private func renderCodeBox(_ text: String, language: String?, label: String?, _ context: Context, note: String? = nil, copyable: Bool = true) {
        let decoration = MDBlockDecoration(.code)
        decoration.indent = context.indent
        decoration.padTop = 34
        decoration.padBottom = 15
        decoration.label = label
        decoration.code = copyable ? text : nil
        let font = NSFont.monospacedSystemFont(ofSize: size * 0.8, weight: .regular)
        let body = NSMutableAttributedString(string: text + "\n", attributes: [.font: font, .foregroundColor: MDColors.codeText])
        SyntaxHighlighter.highlight(body, range: NSRange(location: 0, length: body.length - 1), language: language)
        if let note {
            body.append(NSAttributedString(string: "\u{26A0}\u{FE0E} " + note + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: size * 0.72, weight: .medium), .foregroundColor: MDColors.caution]))
        }
        let characterWidth = (" " as NSString).size(withAttributes: [.font: font]).width
        let lines = body.string as NSString
        var location = 0
        while location < lines.length {
            let line = lines.lineRange(for: NSRange(location: location, length: 0))
            let style = NSMutableParagraphStyle()
            style.headIndent = context.indent + 18
            style.firstLineHeadIndent = context.indent + 18
            style.tailIndent = -18
            style.lineSpacing = size * 0.22
            style.paragraphSpacing = 0
            style.defaultTabInterval = characterWidth * 4
            style.tabStops = []
            if line.location == 0 { style.paragraphSpacingBefore = decoration.padTop + size * 0.35 }
            if NSMaxRange(line) >= lines.length { style.paragraphSpacing = decoration.padBottom + size * 0.95 }
            body.addAttribute(.paragraphStyle, value: style, range: line)
            location = NSMaxRange(line)
        }
        decorations.append(decoration)
        let start = output.length
        append(body)
        decorations.removeLast()
        decoration.range = NSRange(location: start, length: output.length - start)
    }

    private func renderDiagram(_ image: NSImage, _ context: Context) {
        let decoration = MDBlockDecoration(.diagram)
        decoration.indent = context.indent
        decoration.padTop = 20
        decoration.padBottom = 20
        let style = paragraphStyle(context)
        style.alignment = .center
        style.headIndent = context.indent + 20
        style.firstLineHeadIndent = context.indent + 20
        style.tailIndent = -20
        style.paragraphSpacingBefore = 20 + size * 0.35
        style.paragraphSpacing = 20 + size * 0.95
        let attributes: Attributes = [.font: bodyFont, .paragraphStyle: style]
        decorations.append(decoration)
        let start = output.length
        appendAttachment(MDImageCell(image: image, size: image.size), attributes)
        append("\n", attributes)
        decorations.removeLast()
        decoration.range = NSRange(location: start, length: output.length - start)
    }

    private func renderQuote(_ quote: BlockQuote, _ context: Context) {
        let alert = GFM.alert(in: quote)
        let color: NSColor
        switch alert {
        case .note?: color = MDColors.note
        case .tip?: color = MDColors.tip
        case .important?: color = MDColors.important
        case .warning?: color = MDColors.warning
        case .caution?: color = MDColors.caution
        case nil: color = NSColor.tertiaryLabelColor
        }
        let decoration = MDBlockDecoration(alert == nil ? .quote : .alert)
        decoration.indent = context.indent
        decoration.color = color
        var inner = context
        inner.indent += alert == nil ? 18 : 20
        if alert == nil { inner.color = .secondaryLabelColor }
        decorations.append(decoration)
        let start = output.length
        if let alert {
            let titleStart = output.length
            var title = attributes(inner, font: .systemFont(ofSize: size * 0.94, weight: .semibold), spacing: size * 0.35)
            title[.foregroundColor] = color
            if let icon = MDSymbols.image(alert.symbol, size: size * 0.86, color: color, weight: .semibold) {
                appendAttachment(MDImageCell(image: icon, size: icon.size, baseline: -size * 0.14), title)
            }
            append(" " + localized(alert.title) + "\n", title)
            output.addAttribute(.mdSource, value: map.range(quote.range)?.location ?? 0, range: NSRange(location: titleStart, length: output.length - titleStart))
            for (index, child) in quote.children.enumerated() {
                if index == 0, let paragraph = child as? Paragraph {
                    let items = Array(paragraph.children)
                    let skip = (items.firstIndex { $0 is SoftBreak || $0 is LineBreak }).map { $0 + 1 } ?? items.count
                    let paragraphStart = output.length
                    renderParagraph(paragraph, inner, skipping: skip)
                    mark(paragraph, from: paragraphStart)
                } else {
                    block(child, inner)
                }
            }
        } else {
            for child in quote.children { block(child, inner) }
        }
        decorations.removeLast()
        decoration.range = NSRange(location: start, length: output.length - start)
    }

    private func isTight(_ items: [ListItem]) -> Bool {
        var previousEnd: Int?
        for item in items {
            guard let range = item.range else { continue }
            if let previousEnd, range.lowerBound.line > previousEnd + 1 { return false }
            var childEnd: Int?
            for child in item.children {
                guard let childRange = child.range else { continue }
                if let childEnd, childRange.lowerBound.line > childEnd + 1 { return false }
                childEnd = childRange.upperBound.line
            }
            previousEnd = range.upperBound.line
        }
        return true
    }

    private func checkboxOffset(_ item: ListItem) -> Int? {
        guard let range = map.range(item.range), range.location < source.length else { return nil }
        let line = source.lineRange(for: NSRange(location: range.location, length: 0))
        let found = source.range(of: "[", options: [], range: NSRange(location: range.location, length: NSMaxRange(line) - range.location))
        return found.location == NSNotFound ? nil : found.location
    }

    private func checkbox(checked: Bool, attributes: Attributes) -> MDImageCell? {
        let image = checked
            ? MDSymbols.image("checkmark.square.fill", size: size * 0.95, color: .white, background: accent)
            : MDSymbols.image("square", size: size * 0.95, color: .tertiaryLabelColor)
        guard let image else { return nil }
        return MDImageCell(image: image, size: image.size, baseline: -size * 0.16)
    }

    private func renderList(_ items: [ListItem], ordered: Bool, start: Int, _ context: Context) {
        let tight = isTight(items)
        let bullets = ["•", "◦", "▪"]
        let bullet = bullets[listDepth % bullets.count]
        let widest = ordered ? "\(start + max(0, items.count - 1))." : bullet
        let markerWidth = ordered ? max(size * 1.05, (widest as NSString).size(withAttributes: [.font: bodyFont]).width) : size * 0.85
        let markerX = context.indent + markerWidth
        let textIndent = markerX + size * 0.5
        listDepth += 1
        for (index, item) in items.enumerated() {
            let style = paragraphStyle(context, spacing: tight ? size * 0.3 : size * 0.7)
            style.firstLineHeadIndent = context.indent
            style.headIndent = textIndent
            style.tabStops = [NSTextTab(textAlignment: .right, location: markerX), NSTextTab(textAlignment: .left, location: textIndent)]
            var line = attributes(context)
            line[.paragraphStyle] = style
            var inner = context
            inner.indent = textIndent
            inner.spacing = tight ? size * 0.3 : nil
            let itemStart = output.length
            append("\t", line)
            if let state = item.checkbox, let cell = checkbox(checked: state == .checked, attributes: line) {
                var box = line
                if let offset = checkboxOffset(item) { box[.mdTask] = offset }
                appendAttachment(cell, box)
            } else {
                var marker = line
                marker[.foregroundColor] = NSColor.secondaryLabelColor
                if ordered { marker[.font] = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular) }
                append(ordered ? "\(start + index)." : bullet, marker)
            }
            append("\t", line)
            var first = true
            for child in item.children {
                if first, let paragraph = child as? Paragraph {
                    var text = line
                    if item.checkbox == .checked { text[.foregroundColor] = NSColor.secondaryLabelColor }
                    renderParagraph(paragraph, inner, attributes: text)
                    mark(paragraph, from: itemStart)
                } else {
                    if first { append("\n", line) }
                    block(child, inner)
                }
                first = false
            }
            if first { append("\n", line) }
        }
        listDepth -= 1
        if listDepth == 0 { setTrailingSpacing(size * 0.75) }
    }

    private func setTrailingSpacing(_ spacing: CGFloat) {
        guard output.length > 0 else { return }
        let last = output.mutableString.paragraphRange(for: NSRange(location: output.length - 1, length: 0))
        guard let current = output.attribute(.paragraphStyle, at: last.location, effectiveRange: nil) as? NSParagraphStyle,
              current.paragraphSpacing < spacing, current.textBlocks.isEmpty else { return }
        let style = current.mutableCopy() as! NSMutableParagraphStyle
        style.paragraphSpacing = spacing
        output.addAttribute(.paragraphStyle, value: style, range: last)
    }

    private func renderRule(_ context: Context) {
        let decoration = MDBlockDecoration(.rule)
        decoration.indent = context.indent
        let style = paragraphStyle(context)
        style.paragraphSpacingBefore = size * 0.7
        style.paragraphSpacing = size * 1.3
        style.lineSpacing = 0
        decorations.append(decoration)
        let start = output.length
        append(" \n", [.font: NSFont.systemFont(ofSize: 3), .paragraphStyle: style])
        decorations.removeLast()
        decoration.range = NSRange(location: start, length: output.length - start)
    }

    private func renderTable(_ table: Table, _ context: Context) {
        let alignments: [NSTextAlignment] = table.columnAlignments.map {
            switch $0 {
            case .center?: return .center
            case .right?: return .right
            default: return .natural
            }
        }
        let rows: [any Markup] = [table.head] + Array(table.body.children)
        var cells: [[TableCell]] = []
        for (rowIndex, row) in rows.enumerated() {
            var line: [TableCell] = []
            for (column, cell) in row.children.enumerated() {
                let font = NSFont.systemFont(ofSize: size * 0.92, weight: rowIndex == 0 ? .semibold : .regular)
                let text = capture {
                    let openFrames = html.count
                    for child in cell.children { inline(child, attributes(context, font: font)) }
                    closeInlineFrames(to: openFrames)
                }
                line.append(TableCell(text: text, header: rowIndex == 0, alignment: column < alignments.count ? alignments[column] : .natural))
            }
            cells.append(line)
        }
        appendTable(cells, context)
    }

    private func appendTable(_ rows: [[TableCell]], _ context: Context) {
        let columns = rows.map(\.count).max() ?? 0
        guard columns > 0 else { return }
        let table = NSTextTable()
        table.numberOfColumns = columns
        table.layoutAlgorithm = .automaticLayoutAlgorithm
        table.collapsesBorders = true
        table.hidesEmptyCells = false
        table.setValue(100, type: .percentageValueType, for: .width)
        if context.indent > 0 { table.setWidth(context.indent, type: .absoluteValueType, for: .margin, edge: .minX) }
        let header = MDColors.dynamic(NSColor(white: 0, alpha: 0.04), NSColor(white: 1, alpha: 0.06))
        let stripe = MDColors.dynamic(NSColor(white: 0, alpha: 0.018), NSColor(white: 1, alpha: 0.025))
        for (rowIndex, row) in rows.enumerated() {
            for column in 0..<columns {
                let cell = column < row.count ? row[column] : TableCell(text: NSAttributedString(), header: false, alignment: .natural)
                let block = NSTextTableBlock(table: table, startingRow: rowIndex, rowSpan: 1, startingColumn: column, columnSpan: 1)
                block.setWidth(size * 0.45, type: .absoluteValueType, for: .padding, edge: .minY)
                block.setWidth(size * 0.45, type: .absoluteValueType, for: .padding, edge: .maxY)
                block.setWidth(size * 0.75, type: .absoluteValueType, for: .padding, edge: .minX)
                block.setWidth(size * 0.75, type: .absoluteValueType, for: .padding, edge: .maxX)
                block.setWidth(1, type: .absoluteValueType, for: .border)
                block.setBorderColor(.separatorColor)
                block.backgroundColor = cell.header ? header : (rowIndex.isMultiple(of: 2) ? stripe : .clear)
                block.verticalAlignment = .middleAlignment
                let style = NSMutableParagraphStyle()
                style.textBlocks = [block]
                style.lineSpacing = 2
                style.alignment = cell.alignment
                let content = NSMutableAttributedString(attributedString: cell.text)
                while let last = content.string.unicodeScalars.last, CharacterSet.whitespacesAndNewlines.contains(last) || last == "\u{2028}" {
                    content.deleteCharacters(in: NSRange(location: content.length - 1, length: 1))
                }
                let font = NSFont.systemFont(ofSize: size * 0.92, weight: cell.header ? .semibold : .regular)
                if content.length == 0 { content.append(NSAttributedString(string: " ", attributes: [.font: font])) }
                content.append(NSAttributedString(string: "\n", attributes: [.font: font, .foregroundColor: context.color]))
                content.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: content.length))
                append(content)
            }
        }
        let spacer = paragraphStyle(context, spacing: 0)
        append("\n", [.font: NSFont.systemFont(ofSize: size * 0.6), .paragraphStyle: spacer])
    }

    // MARK: Inline content

    private func inline(_ node: Markup, _ attributes: Attributes) {
        var a = attributes
        switch node {
        case let text as Markdown.Text:
            guard hiddenDepth == 0 else { return }
            let styled = htmlInline(a)
            if linkDepth == 0, styled[.link] == nil { appendAutolinked(text.string, styled) } else { append(text.string, styled) }
        case is Strong:
            a[.font] = NSFontManager.shared.convert(a[.font] as? NSFont ?? bodyFont, toHaveTrait: .boldFontMask)
            inlineChildren(node, a)
        case is Emphasis:
            a[.font] = NSFontManager.shared.convert(a[.font] as? NSFont ?? bodyFont, toHaveTrait: .italicFontMask)
            inlineChildren(node, a)
        case is Strikethrough:
            a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            inlineChildren(node, a)
        case let code as InlineCode:
            guard hiddenDepth == 0 else { return }
            let pointSize = (a[.font] as? NSFont)?.pointSize ?? size
            a[.font] = NSFont.monospacedSystemFont(ofSize: pointSize * 0.86, weight: .regular)
            a[.backgroundColor] = MDColors.inlineCode
            a[.mdRounded] = true
            append(code.code, htmlInline(a))
        case let link as Markdown.Link:
            if let destination = link.destination, let url = linkURL(destination) {
                a[.link] = url
                a[.toolTip] = destination
            }
            linkDepth += 1
            inlineChildren(link, a)
            linkDepth -= 1
        case let image as Markdown.Image:
            guard hiddenDepth == 0 else { return }
            if let source = image.source, let url = resolve(source) {
                var styled = htmlInline(a)
                if let title = image.title, !title.isEmpty { styled[.toolTip] = title }
                appendImage(url, alt: image.plainText, width: nil, height: nil, styled)
            } else {
                append(image.plainText, a)
            }
        case is SoftBreak:
            append(" ", htmlInline(a))
        case is LineBreak:
            append("\u{2028}", a)
        case let tag as InlineHTML:
            inlineHTML(tag.rawHTML, a)
        default:
            inlineChildren(node, a)
        }
    }

    private func inlineChildren(_ node: Markup, _ attributes: Attributes) {
        for child in node.children { inline(child, attributes) }
    }

    private func appendAutolinked(_ text: String, _ attributes: Attributes) {
        let links = GFM.autolinks(in: text)
        guard !links.isEmpty else { append(text, attributes); return }
        let ns = text as NSString
        var cursor = 0
        for (range, url) in links {
            if range.location > cursor { append(ns.substring(with: NSRange(location: cursor, length: range.location - cursor)), attributes) }
            var link = attributes
            link[.link] = url
            link[.toolTip] = url.absoluteString
            append(ns.substring(with: range), link)
            cursor = NSMaxRange(range)
        }
        if cursor < ns.length { append(ns.substring(from: cursor), attributes) }
    }

    private func resolve(_ destination: String) -> URL? {
        let trimmed = destination.trimmingCharacters(in: .whitespaces)
        if let url = URL(string: trimmed, relativeTo: baseURL) { return url.absoluteURL }
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? trimmed
        return URL(string: encoded, relativeTo: baseURL)?.absoluteURL
    }

    private func linkURL(_ destination: String) -> URL? {
        if destination.hasPrefix("#") {
            let anchor = String(destination.dropFirst()).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
            return URL(string: "x-mdlite-anchor:" + anchor)
        }
        guard let url = resolve(destination), ["https", "http", "mailto", "file"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    private func loadImage(_ url: URL) -> NSImage? {
        switch url.scheme?.lowercased() {
        case "file"?:
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]), (values.fileSize ?? Int.max) <= 20_000_000 else { return nil }
            return NSImage(contentsOf: url)
        case "http"?, "https"?:
            if let image = remoteImage(url) { return image }
            if !remote.contains(url) { remote.append(url) }
            return nil
        case "data"?:
            let text = url.absoluteString
            guard let comma = text.firstIndex(of: ","), text[..<comma].contains(";base64"),
                  let data = Data(base64Encoded: String(text[text.index(after: comma)...])), data.count < 10_000_000 else { return nil }
            return NSImage(data: data)
        default:
            return nil
        }
    }

    private func appendImage(_ url: URL, alt: String, width: CGFloat?, height: CGFloat?, _ attributes: Attributes) {
        if let image = loadImage(url), image.size.width > 0, image.size.height > 0 {
            var size = image.size
            if let width, let height { size = NSSize(width: width, height: height) }
            else if let width { size = NSSize(width: width, height: width * image.size.height / image.size.width) }
            else if let height { size = NSSize(width: height * image.size.width / image.size.height, height: height) }
            let scale = min(1, maxImageWidth / size.width, 1600 / size.height)
            size = NSSize(width: size.width * scale, height: size.height * scale)
            var a = attributes
            if a[.toolTip] == nil, !alt.isEmpty { a[.toolTip] = alt }
            appendAttachment(MDImageCell(image: image, size: size), a)
            return
        }
        var chip = attributes
        let pointSize = (attributes[.font] as? NSFont)?.pointSize ?? size
        chip[.font] = NSFont.systemFont(ofSize: pointSize * 0.82, weight: .medium)
        chip[.foregroundColor] = NSColor.secondaryLabelColor
        chip[.backgroundColor] = MDColors.inlineCode
        chip[.mdRounded] = true
        if ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "") {
            chip[.link] = url
            chip[.toolTip] = url.absoluteString
        }
        let label = alt.isEmpty ? (url.lastPathComponent.isEmpty ? localized("Imagen") : url.lastPathComponent) : alt
        append("\u{2009}\u{25A7} " + label + "\u{2009}", chip)
    }

    // MARK: HTML

    private var htmlAlignment: NSTextAlignment? {
        for frame in html.reversed() {
            if frame.name == "center" { return .center }
            var value = frame.attributes["align"]?.lowercased()
            if value == nil, let style = frame.attributes["style"]?.lowercased(),
               let range = style.range(of: #"text-align\s*:\s*([a-z]+)"#, options: .regularExpression) {
                value = style[range].split(separator: ":").last?.trimmingCharacters(in: .whitespaces)
            }
            switch value {
            case "center"?, "middle"?: return .center
            case "right"?, "end"?: return .right
            case "left"?, "start"?: return .left
            case "justify"?: return .justified
            default: continue
            }
        }
        return nil
    }

    private func htmlInline(_ base: Attributes) -> Attributes {
        guard !html.isEmpty else { return base }
        var a = base
        var font = a[.font] as? NSFont ?? bodyFont
        let inPre = html.contains { $0.name == "pre" }
        for frame in html {
            switch frame.name {
            case "b", "strong", "th", "dt", "summary":
                font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            case "i", "em", "cite", "var", "dfn", "address":
                font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            case "code", "tt", "samp", "kbd":
                font = NSFont.monospacedSystemFont(ofSize: font.pointSize * 0.88, weight: frame.name == "kbd" ? .medium : .regular)
                if !inPre { a[.backgroundColor] = MDColors.inlineCode; a[.mdRounded] = true }
            case "pre":
                font = NSFont.monospacedSystemFont(ofSize: size * 0.8, weight: .regular)
            case "u", "ins":
                a[.underlineStyle] = NSUnderlineStyle.single.rawValue
            case "s", "strike", "del":
                a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            case "mark":
                a[.backgroundColor] = NSColor.systemYellow.withAlphaComponent(0.35)
                a[.mdRounded] = true
            case "small", "figcaption":
                font = NSFontManager.shared.convert(font, toSize: font.pointSize * 0.85)
                if frame.name == "figcaption" { a[.foregroundColor] = NSColor.secondaryLabelColor }
            case "big":
                font = NSFontManager.shared.convert(font, toSize: font.pointSize * 1.15)
            case "sub", "sup":
                font = NSFontManager.shared.convert(font, toSize: font.pointSize * 0.75)
                a[.baselineOffset] = frame.name == "sup" ? size * 0.35 : -size * 0.18
            case "a":
                if let href = frame.attributes["href"], let url = linkURL(href) {
                    a[.link] = url
                    a[.toolTip] = href
                }
            case "abbr":
                if let title = frame.attributes["title"] { a[.toolTip] = title }
            case "blockquote":
                a[.foregroundColor] = NSColor.secondaryLabelColor
            case "h1", "h2", "h3", "h4", "h5", "h6":
                let level = Int(frame.name.dropFirst()) ?? 1
                let heading = headingAttributes(level, Context())
                font = heading[.font] as? NSFont ?? font
            default:
                break
            }
        }
        a[.font] = font
        return a
    }

    private func htmlAttributes(_ context: Context) -> Attributes {
        var context = context
        var a = attributes(context)
        if html.contains(where: { $0.name == "blockquote" }) { context.color = .secondaryLabelColor }
        let lists = html.filter { $0.name == "ul" || $0.name == "ol" }.count
        let quotes = html.filter { $0.name == "blockquote" }.count
        let indent = context.indent + CGFloat(quotes) * 18 + CGFloat(lists) * size * 1.4
        let style = paragraphStyle(context)
        style.firstLineHeadIndent = indent
        style.headIndent = indent
        if let heading = html.last(where: { $0.name.count == 2 && $0.name.hasPrefix("h") && Int($0.name.dropFirst()) != nil }) {
            let headingStyle = headingAttributes(Int(heading.name.dropFirst()) ?? 1, context)[.paragraphStyle] as! NSParagraphStyle
            style.paragraphSpacingBefore = headingStyle.paragraphSpacingBefore
            style.paragraphSpacing = headingStyle.paragraphSpacing
        }
        if lists > 0 {
            style.firstLineHeadIndent = indent - size * 1.4
            style.tabStops = [NSTextTab(textAlignment: .right, location: indent - size * 0.5), NSTextTab(textAlignment: .left, location: indent)]
            style.paragraphSpacing = size * 0.3
        }
        if html.contains(where: { $0.name == "pre" }) {
            style.headIndent += 18
            style.firstLineHeadIndent = style.headIndent
            style.tailIndent = -18
            style.paragraphSpacing = 0
        }
        if html.contains(where: { $0.name == "summary" || $0.name == "dt" }) { style.paragraphSpacing = size * 0.35 }
        if html.contains(where: { $0.name == "dd" }) { style.headIndent += size * 1.4; style.firstLineHeadIndent += size * 1.4 }
        a[.paragraphStyle] = style
        a[.foregroundColor] = context.color
        return htmlInline(a)
    }

    private func renderHTML(_ raw: String, _ context: Context) {
        let tokens = HTML.tokenize(raw)
        var skipUntil: String.Index?
        for token in tokens {
            switch token {
            case .comment:
                continue
            case .text(let text):
                if skipUntil != nil { continue }
                htmlText(text, context)
            case .open(let name, let attributes, let selfClosing, let range):
                if let end = skipUntil, range.lowerBound < end { continue }
                skipUntil = nil
                if name == "svg", hiddenDepth == 0,
                   let close = raw.range(of: "</svg>", options: .caseInsensitive, range: range.lowerBound..<raw.endIndex) {
                    let svg = String(raw[range.lowerBound..<close.upperBound])
                    if let data = svg.data(using: .utf8), let image = NSImage(data: data), image.size.width > 0 {
                        let width = Double(attributes["width"] ?? "").map { CGFloat($0) }
                        appendAttachment(MDImageCell(image: image, size: width.map { NSSize(width: $0, height: $0 * image.size.height / image.size.width) } ?? image.size), htmlAttributes(context))
                    }
                    skipUntil = close.upperBound
                    continue
                }
                openHTML(name, attributes, selfClosing: selfClosing, context)
            case .close(let name):
                if skipUntil != nil { if name == "svg" { skipUntil = nil }; continue }
                if let index = html.lastIndex(where: { $0.name == name }) {
                    while html.count > index { closeHTMLFrame(context) }
                }
            }
        }
    }

    private func htmlText(_ raw: String, _ context: Context) {
        guard hiddenDepth == 0 else { return }
        if let table = htmlTables.last, !html.contains(where: { $0.name == "td" || $0.name == "th" }) {
            _ = table
            return
        }
        var text = HTML.decodeEntities(raw)
        if !html.contains(where: { $0.name == "pre" }) {
            text = text.replacingOccurrences(of: #"[ \t\r\n\f]+"#, with: " ", options: .regularExpression)
            if atLineStart || lastCharacter == 32 { text = String(text.drop(while: { $0 == " " })) }
        } else if atLineStart, text.hasPrefix("\n") {
            text.removeFirst()
        }
        guard !text.isEmpty else { return }
        append(text, htmlAttributes(context))
    }

    private func openHTML(_ name: String, _ attributes: [String: String], selfClosing: Bool, _ context: Context) {
        if hiddenDepth > 0 {
            if !selfClosing {
                html.append(HTMLFrame(name: name, attributes: attributes))
                if HTML.hiddenElements.contains(name) { hiddenDepth += 1 }
            }
            return
        }
        switch name {
        case "br":
            append("\u{2028}", htmlAttributes(context)); return
        case "hr":
            ensureNewline(htmlAttributes(context)); renderRule(context); return
        case "img":
            let src = pictureSource ?? attributes["src"]
            if let src, let url = resolve(src) {
                appendImage(url, alt: attributes["alt"] ?? "", width: dimension(attributes["width"]), height: dimension(attributes["height"]), htmlAttributes(context))
            }
            return
        case "source":
            if html.last?.name == "picture", let media = attributes["media"]?.lowercased(), media.contains("prefers-color-scheme"),
               media.contains(dark ? "dark" : "light"), let srcset = attributes["srcset"] {
                pictureSource = srcset.split(separator: ",").first?.split(separator: " ").first.map(String.init)
            }
            return
        case "input":
            if attributes["type"]?.lowercased() == "checkbox", let cell = checkbox(checked: attributes["checked"] != nil, attributes: htmlAttributes(context)) {
                appendAttachment(cell, htmlAttributes(context))
                append(" ", htmlAttributes(context))
            }
            return
        case _ where HTML.voidElements.contains(name):
            return
        default:
            break
        }
        if HTML.blockElements.contains(name) && name != "td" && name != "th" && name != "tr" { ensureNewline(htmlAttributes(context)) }
        var frame = HTMLFrame(name: name, attributes: attributes)
        frame.start = output.length
        switch name {
        case "blockquote":
            let decoration = MDBlockDecoration(.quote)
            decoration.indent = context.indent + CGFloat(html.filter { $0.name == "blockquote" }.count) * 18
            frame.decoration = decoration
        case "pre":
            let decoration = MDBlockDecoration(.code)
            decoration.indent = context.indent
            decoration.padTop = 14
            decoration.padBottom = 14
            frame.decoration = decoration
        case "ol":
            frame.counter = Int(attributes["start"] ?? "") ?? 1
        case "table":
            htmlTables.append(HTMLTable())
        case "thead":
            htmlTables.last?.inHead = true
        case "tbody", "tfoot":
            htmlTables.last?.inHead = false
        case "tr":
            if let table = htmlTables.last {
                if let row = table.row { table.rows.append(row) }
                table.row = []
            }
        case "td", "th":
            if let table = htmlTables.last, table.row == nil { table.row = [] }
            frame.saved = (output, decorations)
            output = NSMutableAttributedString()
            decorations = []
            capturing += 1
        default:
            break
        }
        if let decoration = frame.decoration { decorations.append(decoration) }
        if HTML.hiddenElements.contains(name) { hiddenDepth += 1 }
        if selfClosing { return }
        html.append(frame)
        if name == "li" {
            let listIndex = html.lastIndex { $0.name == "ul" || $0.name == "ol" }
            var marker = "•"
            if let listIndex, html[listIndex].name == "ol" {
                marker = "\(html[listIndex].counter)."
                html[listIndex].counter += 1
            }
            var a = htmlAttributes(context)
            append("\t", a)
            a[.foregroundColor] = NSColor.secondaryLabelColor
            append(marker, a)
            append("\t", htmlAttributes(context))
        } else if name == "summary" {
            append("\u{25BE} ", htmlAttributes(context))
        }
    }

    private func closeHTMLFrame(_ context: Context) {
        guard let frame = html.last else { return }
        if hiddenDepth > 0 {
            if HTML.hiddenElements.contains(frame.name) { hiddenDepth -= 1 }
            html.removeLast()
            return
        }
        switch frame.name {
        case "td", "th":
            let content = output
            if let saved = frame.saved { output = saved.0; decorations = saved.1 }
            capturing -= 1
            let header = frame.name == "th" || htmlTables.last?.inHead == true
            let alignment: NSTextAlignment
            switch frame.attributes["align"]?.lowercased() {
            case "center"?: alignment = .center
            case "right"?: alignment = .right
            default: alignment = .natural
            }
            if header { content.addAttribute(.font, value: NSFont.systemFont(ofSize: size * 0.92, weight: .semibold), range: NSRange(location: 0, length: content.length)) }
            htmlTables.last?.row?.append(TableCell(text: content, header: header, alignment: alignment))
            html.removeLast()
            return
        case "tr":
            if let table = htmlTables.last, let row = table.row { table.rows.append(row); table.row = nil }
            html.removeLast()
            return
        case "table":
            html.removeLast()
            if let table = htmlTables.popLast() {
                if let row = table.row { table.rows.append(row) }
                ensureNewline(htmlAttributes(context))
                appendTable(table.rows, context)
            }
            return
        case "picture":
            pictureSource = nil
        case "h1", "h2", "h3", "h4", "h5", "h6":
            if output.length > frame.start {
                let level = Int(frame.name.dropFirst()) ?? 1
                ensureNewline(htmlAttributes(context))
                let range = NSRange(location: frame.start, length: output.length - frame.start)
                addOutline(title: output.mutableString.substring(with: range), level: level, range: range, source: currentSource)
                if level <= 2 {
                    let rule = MDBlockDecoration(.headingRule)
                    rule.indent = context.indent
                    addDecoration(rule, over: range)
                }
            }
        default:
            break
        }
        if HTML.blockElements.contains(frame.name) { ensureNewline(htmlAttributes(context)) }
        if let decoration = frame.decoration {
            decorations.removeAll { $0 === decoration }
            decoration.range = NSRange(location: frame.start, length: output.length - frame.start)
            if frame.name == "pre" { setTrailingSpacing(size * 0.9) }
        }
        html.removeLast()
    }

    private func closeInlineFrames(to count: Int) {
        while html.count > count, let last = html.last, !HTML.blockElements.contains(last.name) {
            if HTML.hiddenElements.contains(last.name), hiddenDepth > 0 { hiddenDepth -= 1 }
            html.removeLast()
        }
    }

    private func inlineHTML(_ raw: String, _ attributes: Attributes) {
        for token in HTML.tokenize(raw) {
            switch token {
            case .open(let name, let values, let selfClosing, _):
                guard hiddenDepth == 0 || !selfClosing else { continue }
                switch name {
                case "br":
                    if hiddenDepth == 0 { append("\u{2028}", htmlInline(attributes)) }
                case "img":
                    if hiddenDepth == 0, let src = values["src"], let url = resolve(src) {
                        appendImage(url, alt: values["alt"] ?? "", width: dimension(values["width"]), height: dimension(values["height"]), htmlInline(attributes))
                    }
                case "input":
                    if hiddenDepth == 0, values["type"]?.lowercased() == "checkbox", let cell = checkbox(checked: values["checked"] != nil, attributes: attributes) {
                        appendAttachment(cell, attributes)
                    }
                default:
                    if HTML.hiddenElements.contains(name) { hiddenDepth += 1 }
                    if !selfClosing { html.append(HTMLFrame(name: name, attributes: values, start: output.length)) }
                }
            case .close(let name):
                guard let index = html.lastIndex(where: { $0.name == name }) else { continue }
                while html.count > index {
                    if let last = html.popLast(), HTML.hiddenElements.contains(last.name), hiddenDepth > 0 { hiddenDepth -= 1 }
                }
            case .text(let text):
                if hiddenDepth == 0 { append(HTML.decodeEntities(text), htmlInline(attributes)) }
            case .comment:
                break
            }
        }
    }

    private func dimension(_ value: String?) -> CGFloat? {
        guard var value = value?.trimmingCharacters(in: .whitespaces).lowercased(), !value.isEmpty else { return nil }
        if value.hasSuffix("%") {
            value.removeLast()
            return Double(value).map { CGFloat($0) / 100 * maxImageWidth }
        }
        if value.hasSuffix("px") { value.removeLast(2) }
        return Double(value).map { CGFloat($0) }.flatMap { $0 > 0 ? $0 : nil }
    }
}
