import AppKit
import Markdown

/// Styles Markdown source in place for the editor. The text itself never changes:
/// in live mode syntax markers are hidden until the caret enters their line (Typora style),
/// in code mode everything stays visible with syntax colors.
final class MarkdownStyler {
    typealias Attributes = [NSAttributedString.Key: Any]

    struct Conceal {
        let range: NSRange
        let scope: NSRange
        var collapse = false
        var decoration: MDBlockDecoration?
    }

    struct Task {
        let range: NSRange
        let checked: Bool
        let scope: NSRange
    }

    struct Analysis {
        var spans: [(NSRange, Attributes)] = []
        var conceals: [Conceal] = []
        var decorations: [MDBlockDecoration] = []
        var bullets: [NSRange] = []
        var tasks: [Task] = []
    }

    private struct Context {
        var font: NSFont
        var indent: CGFloat = 0
        var quoteDepth = 0
    }

    let size: CGFloat
    let accent: NSColor
    let live: Bool
    let baseURL: URL?
    var remoteImage: (URL) -> NSImage? = { _ in nil }

    private var map = SourceMap("")
    private var text: NSString = ""
    private var result = Analysis()
    private var linkShift = 0

    init(size: CGFloat, accent: NSColor, live: Bool, baseURL: URL?) {
        self.size = size
        self.accent = accent
        self.live = live
        self.baseURL = baseURL
    }

    // MARK: Fonts and paragraphs

    var bodyFont: NSFont { live ? .systemFont(ofSize: size) : .monospacedSystemFont(ofSize: size * 0.82, weight: .regular) }
    private var codeFont: NSFont { .monospacedSystemFont(ofSize: size * (live ? 0.8 : 0.82), weight: .regular) }
    private static let tiny = NSFont.systemFont(ofSize: 0.5)

    private func paragraph(indent: CGFloat = 0, head: CGFloat? = nil) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = live ? size * 0.3 : size * 0.22
        style.paragraphSpacing = live ? size * 0.12 : 0
        style.firstLineHeadIndent = indent
        style.headIndent = head ?? indent
        return style
    }

    var baseAttributes: Attributes {
        [.font: bodyFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph()]
    }

    private var markerColor: NSColor { live ? .tertiaryLabelColor : accent }

    private static let collapsed: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.maximumLineHeight = 1
        style.lineSpacing = 0
        style.paragraphSpacing = 0
        return style
    }()

    // MARK: Analysis

    func analyze(_ source: String) -> Analysis {
        text = source as NSString
        map = SourceMap(source)
        result = Analysis()
        var parseText = source
        if let front = GFM.frontMatter(in: source) {
            parseText = front.masked
            span(NSRange(location: 0, length: min(frontMatterLength(front), text.length)), [.font: codeFont, .foregroundColor: NSColor.secondaryLabelColor])
        }
        emptyLines()
        let document = Document(parsing: parseText, options: [.disableSmartOpts])
        let context = Context(font: bodyFont)
        for child in document.children { visit(child, context) }
        return result
    }

    private func frontMatterLength(_ front: (yaml: String, masked: String)) -> Int {
        let lines = front.yaml.components(separatedBy: "\n").count + 2
        var location = 0
        for _ in 0..<lines where location < text.length { location = NSMaxRange(text.lineRange(for: NSRange(location: location, length: 0))) }
        return location
    }

    private func emptyLines() {
        guard live else { return }
        var location = 0
        let small = NSFont.systemFont(ofSize: size * 0.7)
        let style = paragraph()
        style.lineSpacing = 0
        while location < text.length {
            let line = text.lineRange(for: NSRange(location: location, length: 0))
            if line.length <= 1 || text.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                span(line, [.font: small, .paragraphStyle: style])
            }
            location = NSMaxRange(line)
        }
    }

    private func span(_ range: NSRange, _ attributes: Attributes) {
        guard range.length > 0, NSMaxRange(range) <= text.length else { return }
        result.spans.append((range, attributes))
    }

    private func conceal(_ range: NSRange, scope: NSRange, collapse: Bool = false, decoration: MDBlockDecoration? = nil) {
        guard range.length > 0, NSMaxRange(range) <= text.length else { return }
        result.conceals.append(Conceal(range: range, scope: scope, collapse: collapse, decoration: decoration))
    }

    private func lines(_ range: NSRange) -> NSRange {
        guard text.length > 0 else { return NSRange(location: 0, length: 0) }
        let start = min(range.location, text.length)
        let end = min(NSMaxRange(range), text.length)
        return text.lineRange(for: NSRange(location: start, length: max(0, end - start)))
    }

    /// Range of a line without its line terminator.
    private func content(of line: NSRange) -> NSRange {
        var length = line.length
        while length > 0, [10, 13].contains(text.character(at: line.location + length - 1)) { length -= 1 }
        return NSRange(location: line.location, length: length)
    }

    private func match(_ pattern: String, in range: NSRange) -> NSTextCheckingResult? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        return regex.firstMatch(in: text as String, options: [.anchored], range: range)
    }

    private func childRange(_ node: Markup) -> NSRange? {
        var start: Int?, end: Int?
        for child in node.children {
            guard let range = map.range(child.range) else { continue }
            if start == nil { start = range.location }
            end = NSMaxRange(range)
        }
        guard let start, let end, end >= start else { return nil }
        return NSRange(location: start, length: end - start)
    }

    /// cmark reports inline positions on paragraph continuation lines without the stripped
    /// leading whitespace. Snap inline ranges back onto their real delimiters.
    private func corrected(_ node: Markup, _ range: NSRange) -> NSRange {
        let delimiters: ([String], [String])
        switch node {
        case is Strong: delimiters = (["**", "__"], ["**", "__"])
        case is Emphasis: delimiters = (["*", "_"], ["*", "_"])
        case is Strikethrough: delimiters = (["~"], ["~"])
        case is InlineCode: delimiters = (["`"], ["`"])
        case is Markdown.Image: delimiters = (["!["], [")", "]"])
        case is Markdown.Link: delimiters = (["[", "<"], [")", "]", ">"])
        case is InlineHTML: delimiters = (["<"], [">"])
        case let leaf as Markdown.Text:
            let expected = leaf.string as NSString
            guard expected.length > 0, NSMaxRange(range) <= text.length, text.substring(with: range) != leaf.string else { return range }
            let window = NSRange(location: max(0, range.location - 2), length: min(text.length - max(0, range.location - 2), expected.length + 12))
            let found = text.range(of: leaf.string, options: [], range: window)
            return found.location == NSNotFound ? range : found
        default: return range
        }
        func fits(_ candidate: NSRange) -> Bool {
            guard candidate.location >= 0, candidate.length >= 2, NSMaxRange(candidate) <= text.length else { return false }
            let value = text.substring(with: candidate)
            return delimiters.0.contains { value.hasPrefix($0) } && delimiters.1.contains { value.hasSuffix($0) }
        }
        if fits(range) { return range }
        for shift in [1, 2, 3, 4, -1, 5, 6, 7, 8, -2] {
            let candidate = NSRange(location: range.location + shift, length: range.length)
            if fits(candidate) { return candidate }
        }
        return range
    }

    private func visit(_ node: Markup, _ context: Context) {
        guard let reported = map.range(node.range) else {
            for child in node.children { visit(child, context) }
            return
        }
        let range = corrected(node, reported)
        linkShift = range.location - reported.location
        var context = context
        switch node {
        case let heading as Heading:
            styleHeading(heading, range, &context)
        case is Emphasis:
            context.font = NSFontManager.shared.convert(context.font, toHaveTrait: .italicFontMask)
            span(range, [.font: context.font])
            delimiters(range, count: 1)
        case is Strong:
            context.font = NSFontManager.shared.convert(context.font, toHaveTrait: .boldFontMask)
            span(range, [.font: context.font])
            delimiters(range, count: 2)
        case is Strikethrough:
            span(range, [.strikethroughStyle: NSUnderlineStyle.single.rawValue])
            delimiters(range, count: text.substring(with: range).hasPrefix("~~") ? 2 : 1)
        case is InlineCode:
            var ticks = 0
            while ticks < range.length, text.character(at: range.location + ticks) == 96 { ticks += 1 }
            let pointSize = context.font.pointSize
            span(range, [.font: NSFont.monospacedSystemFont(ofSize: pointSize * (live ? 0.86 : 1), weight: .regular),
                         .foregroundColor: live ? NSColor.labelColor : MDColors.string])
            if live, range.length > ticks * 2 {
                span(NSRange(location: range.location + ticks, length: range.length - ticks * 2),
                     [.backgroundColor: MDColors.inlineCode, .mdRounded: true])
            }
            delimiters(range, count: ticks)
            return
        case let link as Markdown.Link:
            styleLink(link.destination, range: range, node: link)
        case let image as Markdown.Image:
            styleImage(image, range: range, context)
            return
        case let text as Markdown.Text:
            for (linkRange, url) in GFM.autolinks(in: text.string) where linkRange.location + linkRange.length <= range.length {
                span(NSRange(location: range.location + linkRange.location, length: linkRange.length),
                     [.foregroundColor: accent, .mdLinkURL: url])
            }
            return
        case is InlineHTML:
            span(range, [.foregroundColor: MDColors.meta])
            return
        case let quote as BlockQuote:
            styleQuote(quote, range, &context)
        case let item as ListItem:
            styleListItem(item, range, context)
        case let code as CodeBlock:
            styleCode(code, range, context)
            return
        case is ThematicBreak:
            let line = lines(range)
            span(line, [.foregroundColor: NSColor.tertiaryLabelColor])
            if live {
                let rule = MDBlockDecoration(.rule)
                rule.indent = context.indent
                let style = paragraph(indent: context.indent)
                style.paragraphSpacingBefore = size * 0.5
                style.paragraphSpacing = size * 0.5
                span(line, [.paragraphStyle: style])
                conceal(content(of: line), scope: line, collapse: true, decoration: rule)
            }
            return
        case is HTMLBlock:
            let line = lines(range)
            span(line, [.font: codeFont, .foregroundColor: NSColor.secondaryLabelColor])
            for (token, color) in SyntaxHighlighter.tokens(in: text as String, range: range, language: "html") { span(token, [.foregroundColor: color]) }
            return
        case is Table:
            styleTable(range, &context)
        default:
            break
        }
        for child in node.children { visit(child, context) }
    }

    private func delimiters(_ range: NSRange, count: Int) {
        guard count > 0, range.length >= count * 2 else { return }
        let scope = lines(range)
        let open = NSRange(location: range.location, length: count)
        let close = NSRange(location: NSMaxRange(range) - count, length: count)
        span(open, [.foregroundColor: markerColor])
        span(close, [.foregroundColor: markerColor])
        conceal(open, scope: scope)
        conceal(close, scope: scope)
    }

    private func headingFont(_ level: Int) -> NSFont {
        guard live else { return NSFontManager.shared.convert(bodyFont, toHaveTrait: .boldFontMask) }
        let scale: [CGFloat] = [2.0, 1.5, 1.25, 1.08, 0.97, 0.9]
        return .systemFont(ofSize: size * scale[max(0, min(5, level - 1))], weight: level == 1 ? .bold : .semibold)
    }

    private func styleHeading(_ heading: Heading, _ range: NSRange, _ context: inout Context) {
        let line = lines(range)
        context.font = headingFont(heading.level)
        let style = paragraph(indent: context.indent)
        if live {
            style.paragraphSpacingBefore = heading.level <= 2 ? size * 0.9 : size * 0.6
            style.paragraphSpacing = heading.level <= 2 ? size * 0.55 : size * 0.3
            style.lineSpacing = 2
        }
        span(line, [.font: context.font, .paragraphStyle: style,
                    .foregroundColor: heading.level == 6 ? NSColor.secondaryLabelColor : NSColor.labelColor])
        let body = content(of: lines(NSRange(location: range.location, length: 0)))
        if let marker = match(#"[ \t]{0,3}#{1,6}(?:[ \t]+|$)"#, in: body) {
            span(marker.range, [.foregroundColor: markerColor])
            conceal(marker.range, scope: line)
            if let closing = try? NSRegularExpression(pattern: #"[ \t]+#+[ \t]*$"#).firstMatch(in: text as String, range: body) {
                span(closing.range, [.foregroundColor: markerColor])
                conceal(closing.range, scope: line)
            }
        } else if range.length > body.length {
            let underline = content(of: lines(NSRange(location: NSMaxRange(range) - 1, length: 0)))
            span(underline, [.foregroundColor: markerColor])
            if live { conceal(underline, scope: line, collapse: true) }
        }
        if live, heading.level <= 2 {
            let rule = MDBlockDecoration(.headingRule)
            rule.indent = context.indent
            rule.range = body
            result.decorations.append(rule)
        }
    }

    private func styleLink(_ destination: String?, range: NSRange, node: Markup) {
        guard var inner = childRange(node), inner.length > 0 else { return }
        inner.location += linkShift
        guard inner.location > range.location, NSMaxRange(inner) < NSMaxRange(range) else { return }
        var attributes: Attributes = [.foregroundColor: accent]
        if live { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if let destination, let url = URL(string: destination, relativeTo: baseURL)?.absoluteURL { attributes[.mdLinkURL] = url }
        span(inner, attributes)
        let scope = lines(range)
        let open = NSRange(location: range.location, length: inner.location - range.location)
        let close = NSRange(location: NSMaxRange(inner), length: NSMaxRange(range) - NSMaxRange(inner))
        for marker in [open, close] where marker.length > 0 {
            span(marker, [.foregroundColor: live ? NSColor.tertiaryLabelColor : NSColor.secondaryLabelColor])
            conceal(marker, scope: scope)
        }
    }

    private func loadImage(_ source: String) -> NSImage? {
        guard let url = URL(string: source, relativeTo: baseURL)?.absoluteURL else { return nil }
        if url.isFileURL {
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 20_000_000 else { return nil }
            return NSImage(contentsOf: url)
        }
        return remoteImage(url)
    }

    private func styleImage(_ image: Markdown.Image, range: NSRange, _ context: Context) {
        let line = lines(range)
        let alone = content(of: line) == range || text.substring(with: content(of: line)).trimmingCharacters(in: .whitespaces) == text.substring(with: range)
        if live, alone, let source = image.source, let picture = loadImage(source), picture.size.width > 0 {
            let width = min(picture.size.width, 680)
            let height = picture.size.height * width / picture.size.width
            let decoration = MDBlockDecoration(.image)
            decoration.image = picture
            decoration.imageSize = NSSize(width: width, height: height)
            decoration.indent = context.indent
            decoration.range = content(of: line)
            result.decorations.append(decoration)
            let style = paragraph(indent: context.indent)
            style.paragraphSpacingBefore = height + 14
            style.paragraphSpacing = size * 0.4
            span(line, [.paragraphStyle: style, .foregroundColor: NSColor.tertiaryLabelColor])
            conceal(content(of: line), scope: line, collapse: true)
            return
        }
        styleLink(image.source, range: range, node: image)
        if var inner = childRange(image) {
            inner.location += linkShift
            span(inner, [.foregroundColor: NSColor.secondaryLabelColor])
        }
    }

    private func alertColor(_ alert: GFM.Alert) -> NSColor {
        switch alert {
        case .note: return MDColors.note
        case .tip: return MDColors.tip
        case .important: return MDColors.important
        case .warning: return MDColors.warning
        case .caution: return MDColors.caution
        }
    }

    private func styleQuote(_ quote: BlockQuote, _ range: NSRange, _ context: inout Context) {
        let block = lines(range)
        let alert = GFM.alert(in: quote)
        if context.quoteDepth == 0 {
            var location = block.location
            while location < NSMaxRange(block) {
                let line = text.lineRange(for: NSRange(location: location, length: 0))
                if let marker = match(#"[ \t]{0,3}(?:>[ \t]?)+"#, in: content(of: line)), marker.range.length > 0 {
                    span(marker.range, [.foregroundColor: markerColor])
                    conceal(marker.range, scope: line)
                }
                location = NSMaxRange(line)
            }
        }
        context.quoteDepth += 1
        if live {
            let decoration = MDBlockDecoration(alert == nil ? .quote : .alert)
            decoration.indent = context.indent
            decoration.color = alert.map(alertColor) ?? .tertiaryLabelColor
            decoration.range = content(of: block)
            result.decorations.append(decoration)
            context.indent += alert == nil ? 18 : 20
            span(block, [.paragraphStyle: paragraph(indent: context.indent)])
            let first = text.lineRange(for: NSRange(location: block.location, length: 0))
            let last = text.lineRange(for: NSRange(location: max(block.location, NSMaxRange(block) - 1), length: 0))
            let top = paragraph(indent: context.indent)
            top.paragraphSpacingBefore = size * 0.5
            let bottom = paragraph(indent: context.indent)
            bottom.paragraphSpacing = size * 0.5
            if first == last { top.paragraphSpacing = size * 0.5 }
            span(first, [.paragraphStyle: top])
            if first != last { span(last, [.paragraphStyle: bottom]) }
        }
        if alert == nil { span(block, [.foregroundColor: NSColor.secondaryLabelColor]) }
        if let alert {
            let first = content(of: text.lineRange(for: NSRange(location: block.location, length: 0)))
            span(first, [.foregroundColor: alertColor(alert), .font: NSFontManager.shared.convert(context.font, toHaveTrait: .boldFontMask)])
        }
    }

    private func styleListItem(_ item: ListItem, _ range: NSRange, _ context: Context) {
        let line = text.lineRange(for: NSRange(location: range.location, length: 0))
        guard let marker = match(#"([ \t]*(?:>[ \t]?)*[ \t]*)([-+*]|\d{1,9}[.)])([ \t]+|$)(\[[ xX]\][ \t]+)?"#, in: content(of: line)) else { return }
        let symbol = marker.range(at: 2)
        span(symbol, [.foregroundColor: live ? NSColor.secondaryLabelColor : accent])
        let isTask = marker.range(at: 4).location != NSNotFound
        if live, text.substring(with: symbol).count == 1, "-+*".contains(text.substring(with: symbol)) {
            if isTask {
                conceal(NSRange(location: symbol.location, length: marker.range(at: 4).location - symbol.location), scope: line)
            } else {
                result.bullets.append(symbol)
            }
        }
        if isTask {
            let box = NSRange(location: marker.range(at: 4).location, length: 3)
            let checked = text.substring(with: box).lowercased() == "[x]"
            span(box, [.foregroundColor: markerColor])
            result.tasks.append(Task(range: box, checked: checked, scope: line))
            if checked {
                let rest = NSRange(location: NSMaxRange(marker.range), length: NSMaxRange(content(of: line)) - NSMaxRange(marker.range))
                span(rest, [.foregroundColor: NSColor.secondaryLabelColor])
            }
        }
        if live {
            var visible = text.substring(with: marker.range)
            if isTask, result.bullets.last != symbol {
                let hidden = NSRange(location: symbol.location - marker.range.location, length: marker.range(at: 4).location - symbol.location)
                visible = (visible as NSString).replacingCharacters(in: hidden, with: "")
            }
            var width = (visible as NSString).size(withAttributes: [.font: context.font]).width
            if result.bullets.last == symbol { width += 1 }
            span(line, [.paragraphStyle: paragraph(indent: context.indent, head: context.indent + width)])
        }
    }

    private func styleCode(_ code: CodeBlock, _ range: NSRange, _ context: Context) {
        let block = lines(range)
        let blockText = text.substring(with: block) as NSString
        let first = text.lineRange(for: NSRange(location: block.location, length: 0))
        let fence = #"[ \t]{0,3}(`{3,}|~{3,})"#
        let fenced = match(fence, in: content(of: first)) != nil
        var inner = block
        var closing: NSRange?
        if fenced {
            inner = NSRange(location: NSMaxRange(first), length: max(0, NSMaxRange(block) - NSMaxRange(first)))
            let lastStart = blockText.lineRange(for: NSRange(location: max(0, blockText.length - 1), length: 0)).location + block.location
            let last = text.lineRange(for: NSRange(location: lastStart, length: 0))
            if last.location > first.location, match(fence + #"[ \t]*$"#, in: content(of: last)) != nil {
                closing = last
                inner.length = max(0, last.location - inner.location)
            }
        }
        span(block, [.font: codeFont, .foregroundColor: live ? MDColors.codeText : NSColor.labelColor])
        for (token, color) in SyntaxHighlighter.tokens(in: text as String, range: inner, language: code.language) {
            span(token, [.foregroundColor: color])
        }
        for fenceLine in [fenced ? first : nil, closing].compactMap({ $0 }) {
            span(content(of: fenceLine), [.foregroundColor: NSColor.tertiaryLabelColor])
            if live { conceal(content(of: fenceLine), scope: block, collapse: true) }
        }
        guard live else { return }
        let decoration = MDBlockDecoration(.code)
        decoration.indent = context.indent
        decoration.padTop = 32
        decoration.padBottom = 14
        decoration.label = code.language?.split(separator: " ").first.map { $0.lowercased() }
        var copy = text.substring(with: inner)
        if copy.hasSuffix("\n") { copy.removeLast() }
        decoration.code = copy
        decoration.range = content(of: block)
        result.decorations.append(decoration)
        var location = block.location
        while location < NSMaxRange(block) {
            let line = text.lineRange(for: NSRange(location: location, length: 0))
            let style = paragraph(indent: context.indent + 18)
            style.tailIndent = -18
            style.lineSpacing = size * 0.2
            style.paragraphSpacing = 0
            if line.location == block.location { style.paragraphSpacingBefore = decoration.padTop + 8 }
            if NSMaxRange(line) >= NSMaxRange(block) { style.paragraphSpacing = decoration.padBottom + 10 }
            span(line, [.paragraphStyle: style])
            location = NSMaxRange(line)
        }
    }

    private func styleTable(_ range: NSRange, _ context: inout Context) {
        let block = lines(range)
        let mono = NSFont.monospacedSystemFont(ofSize: size * (live ? 0.82 : 0.82), weight: .regular)
        context.font = mono
        span(block, [.font: mono])
        let first = text.lineRange(for: NSRange(location: block.location, length: 0))
        span(first, [.font: NSFont.monospacedSystemFont(ofSize: mono.pointSize, weight: .semibold)])
        if let regex = try? NSRegularExpression(pattern: #"\||(?m)^[ \t|:\-]+$"#) {
            for found in regex.matches(in: text as String, range: block) {
                span(found.range, [.foregroundColor: NSColor.tertiaryLabelColor])
            }
        }
    }

    // MARK: Applying

    static func overlaps(_ scope: NSRange, _ active: NSRange) -> Bool {
        NSIntersectionRange(scope, active).length > 0
    }

    /// Applies the analysis to `storage`, restricted to `range` when given.
    func apply(_ analysis: Analysis, to storage: NSTextStorage, active: NSRange, range limit: NSRange? = nil) {
        let full = NSRange(location: 0, length: storage.length)
        let target = limit.map { NSIntersectionRange($0, full) } ?? full
        guard target.length > 0 || limit == nil else { return }
        func clip(_ range: NSRange) -> NSRange? {
            let clipped = NSIntersectionRange(range, target)
            return clipped.length > 0 ? clipped : nil
        }
        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: target)
        for (range, attributes) in analysis.spans {
            if let clipped = clip(range) { storage.addAttributes(attributes, range: clipped) }
        }
        var blocks = analysis.decorations
        if live {
            for conceal in analysis.conceals where !Self.overlaps(conceal.scope, active) {
                if let decoration = conceal.decoration { decoration.range = conceal.range; blocks.append(decoration) }
            }
        }
        for decoration in blocks.sorted(by: { $0.range.location == $1.range.location ? $0.range.length > $1.range.length : $0.range.location < $1.range.location }) {
            guard let clipped = clip(decoration.range) else { continue }
            storage.enumerateAttribute(.mdBlocks, in: clipped) { value, run, _ in
                storage.addAttribute(.mdBlocks, value: ((value as? [MDBlockDecoration]) ?? []) + [decoration], range: run)
            }
        }
        if live {
            for bullet in analysis.bullets {
                if let clipped = clip(bullet) { storage.addAttribute(.mdGlyph, value: "•", range: clipped) }
            }
            for task in analysis.tasks {
                guard let clipped = clip(task.range) else { continue }
                storage.addAttribute(.mdTask, value: task.range.location, range: clipped)
                if !Self.overlaps(task.scope, active) {
                    storage.addAttributes([.mdTaskBox: task.checked, .foregroundColor: NSColor.clear], range: clipped)
                }
            }
            for conceal in analysis.conceals where !Self.overlaps(conceal.scope, active) {
                guard let clipped = clip(conceal.range) else { continue }
                // Null glyphs at the start of a paragraph are laid out on the previous line
                // fragment, and a line made only of them gets no fragment at all. Markers there
                // keep real glyphs instead: transparent and tiny.
                let lineStart = storage.mutableString.lineRange(for: NSRange(location: clipped.location, length: 0)).location
                if conceal.collapse || clipped.location == lineStart {
                    storage.addAttributes([.foregroundColor: NSColor.clear, .font: Self.tiny], range: clipped)
                } else {
                    storage.addAttribute(.mdConceal, value: true, range: clipped)
                }
                if conceal.collapse {
                    let line = storage.mutableString.lineRange(for: clipped)
                    if let lineClip = clip(line) {
                        storage.addAttribute(.font, value: Self.tiny, range: lineClip)
                        let current = storage.attribute(.paragraphStyle, at: lineClip.location, effectiveRange: nil) as? NSParagraphStyle
                        let style = (Self.collapsed.mutableCopy() as! NSMutableParagraphStyle)
                        style.paragraphSpacingBefore = current?.paragraphSpacingBefore ?? 0
                        style.paragraphSpacing = current?.paragraphSpacing ?? 0
                        style.firstLineHeadIndent = current?.firstLineHeadIndent ?? 0
                        style.headIndent = current?.headIndent ?? 0
                        storage.addAttribute(.paragraphStyle, value: style, range: lineClip)
                    }
                }
            }
        }
        storage.endEditing()
    }

    /// Ranges whose appearance depends on whether the caret is inside `active`.
    static func sensitiveRanges(_ analysis: Analysis, old: NSRange, new: NSRange, in storage: NSTextStorage) -> [NSRange] {
        var ranges: [NSRange] = []
        for conceal in analysis.conceals where overlaps(conceal.scope, old) != overlaps(conceal.scope, new) {
            ranges.append(conceal.collapse ? storage.mutableString.lineRange(for: conceal.range) : conceal.range)
        }
        for task in analysis.tasks where overlaps(task.scope, old) != overlaps(task.scope, new) {
            ranges.append(task.range)
        }
        return ranges
    }
}
