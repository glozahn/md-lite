import AppKit
import Markdown

struct OutlineItem: Identifiable {
    let id: Int
    let title: String
    let level: Int
    let range: NSRange
}

struct RenderedDocument {
    let text: NSAttributedString
    let outline: [OutlineItem]
}

/// CommonMark/GFM parsing with native attributed text output. No browser runtime.
final class MarkdownRenderer {
    let size: CGFloat
    let baseURL: URL?
    private let output = NSMutableAttributedString()
    private var outline: [OutlineItem] = []

    init(size: CGFloat = 17, baseURL: URL? = nil) {
        self.size = size
        self.baseURL = baseURL
    }

    func render(_ source: String) -> RenderedDocument {
        output.setAttributedString(NSAttributedString())
        outline = []
        let document = Document(parsing: source)
        for child in document.children { block(child) }
        return RenderedDocument(text: output.copy() as! NSAttributedString, outline: outline)
    }

    private func style(indent: CGFloat = 0) -> NSMutableParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 5
        p.paragraphSpacing = 12
        p.headIndent = indent
        p.firstLineHeadIndent = indent
        return p
    }

    private func attributes(font: NSFont? = nil, indent: CGFloat = 0) -> [NSAttributedString.Key: Any] {
        [.font: font ?? NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.labelColor,
         .paragraphStyle: style(indent: indent)]
    }

    private func append(_ text: String, _ attrs: [NSAttributedString.Key: Any]) {
        output.append(NSAttributedString(string: text, attributes: attrs))
    }

    private func block(_ node: any Markup, depth: Int = 0, quote: Bool = false) {
        let indent = CGFloat(depth) * 22 + (quote ? 20 : 0)
        var attrs = attributes(indent: indent)
        if quote { attrs[.foregroundColor] = NSColor.secondaryLabelColor }
        switch node {
        case let heading as Heading:
            let start = output.length
            let scale: [CGFloat] = [2.05, 1.5, 1.2, 1.08, 1, 0.95]
            attrs[.font] = NSFont.systemFont(ofSize: size * scale[heading.level - 1], weight: .semibold)
            let p = style(indent: indent)
            p.paragraphSpacingBefore = heading.level == 1 ? 8 : 18
            p.paragraphSpacing = 12
            attrs[.paragraphStyle] = p
            inlineChildren(heading, attrs)
            append("\n", attrs)
            outline.append(OutlineItem(id: outline.count, title: heading.plainText, level: heading.level,
                                       range: NSRange(location: start, length: output.length - start)))
        case let code as CodeBlock:
            attrs[.font] = NSFont.monospacedSystemFont(ofSize: size * 0.84, weight: .regular)
            attrs[.backgroundColor] = NSColor.quaternaryLabelColor.withAlphaComponent(0.10)
            attrs[.foregroundColor] = NSColor.secondaryLabelColor
            let p = style(indent: indent + 14)
            p.lineSpacing = 4
            p.paragraphSpacingBefore = 10
            p.paragraphSpacing = 16
            attrs[.paragraphStyle] = p
            append(code.code.trimmingCharacters(in: .newlines) + "\n", attrs)
        case is BlockQuote:
            for child in node.children { block(child, depth: depth, quote: true) }
        case let list as OrderedList:
            for (index, child) in list.children.enumerated() {
                listItem(child, marker: "\(Int(list.startIndex) + index).", depth: depth, quote: quote)
            }
        case is UnorderedList:
            for child in node.children { listItem(child, marker: "•", depth: depth, quote: quote) }
        case is ThematicBreak:
            attrs[.foregroundColor] = NSColor.separatorColor
            append("────────────────────────────\n", attrs)
        case let html as HTMLBlock:
            attrs[.font] = NSFont.monospacedSystemFont(ofSize: size * 0.85, weight: .regular)
            append(html.rawHTML + "\n", attrs)
        case is Table:
            // Tab stops keep simple GFM tables selectable and entirely native.
            for section in node.children {
                if section is Table.Head { tableRow(section, header: true, attrs: attrs) }
                else { for row in section.children { tableRow(row, header: false, attrs: attrs) } }
            }
        case is Paragraph:
            inlineChildren(node, attrs)
            append("\n", attrs)
        default:
            for child in node.children { block(child, depth: depth, quote: quote) }
        }
    }

    private func tableRow(_ node: any Markup, header: Bool, attrs: [NSAttributedString.Key: Any]) {
        var a = attrs
        a[.font] = NSFont.monospacedSystemFont(ofSize: size * 0.83, weight: header ? .semibold : .regular)
        for (index, cell) in node.children.enumerated() {
            if index > 0 { append("   │   ", a) }
            inlineChildren(cell, a)
        }
        append("\n", a)
    }

    private func listItem(_ item: any Markup, marker: String, depth: Int, quote: Bool) {
        var attrs = attributes(indent: CGFloat(depth + 1) * 22 + (quote ? 20 : 0))
        let p = style(indent: CGFloat(depth + 1) * 22 + (quote ? 20 : 0))
        p.firstLineHeadIndent = CGFloat(depth) * 22 + (quote ? 20 : 0)
        p.paragraphSpacing = 7
        attrs[.paragraphStyle] = p
        var bullet = marker
        if let item = item as? ListItem, let checkbox = item.checkbox {
            bullet = checkbox == .checked ? "☑" : "☐"
        }
        append(bullet + "  ", attrs)
        var first = true
        for child in item.children {
            if first, child is Paragraph {
                inlineChildren(child, attrs)
                append("\n", attrs)
            } else { block(child, depth: depth + 1, quote: quote) }
            first = false
        }
    }

    private func inlineChildren(_ node: any Markup, _ attrs: [NSAttributedString.Key: Any]) {
        for child in node.children { inline(child, attrs) }
    }

    private func inline(_ node: any Markup, _ attrs: [NSAttributedString.Key: Any]) {
        var a = attrs
        switch node {
        case let text as Markdown.Text: append(text.string, a)
        case is Strong:
            a[.font] = NSFontManager.shared.convert(a[.font] as! NSFont, toHaveTrait: .boldFontMask)
            inlineChildren(node, a)
        case is Emphasis:
            a[.font] = NSFontManager.shared.convert(a[.font] as! NSFont, toHaveTrait: .italicFontMask)
            inlineChildren(node, a)
        case is Strikethrough:
            a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            inlineChildren(node, a)
        case let code as InlineCode:
            a[.font] = NSFont.monospacedSystemFont(ofSize: size * 0.87, weight: .medium)
            a[.foregroundColor] = NSColor.systemTeal
            a[.backgroundColor] = NSColor.systemTeal.withAlphaComponent(0.08)
            append(code.code, a)
        case let link as Markdown.Link:
            if let destination = link.destination, let url = resolve(destination), allowedLink(url) {
                a[.link] = url
            }
            inlineChildren(link, a)
        case let image as Markdown.Image:
            if let source = image.source, let url = resolve(source), url.isFileURL,
               let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
               (values.fileSize ?? Int.max) <= 20_000_000,
               let picture = NSImage(contentsOf: url), picture.size.width > 0 {
                let attachment = NSTextAttachment()
                attachment.image = picture
                let ratio = min(1, 620 / picture.size.width, 480 / max(1, picture.size.height))
                attachment.bounds = NSRect(x: 0, y: 0, width: picture.size.width * ratio, height: picture.size.height * ratio)
                output.append(NSAttributedString(attachment: attachment))
            } else {
                if let source = image.source, let url = resolve(source), allowedLink(url) { a[.link] = url }
                a[.foregroundColor] = NSColor.secondaryLabelColor
                append("[Imagen: \(image.plainText.isEmpty ? "abrir imagen" : image.plainText)]", a)
            }
        case is SoftBreak: append(" ", a)
        case is LineBreak: append("\n", a)
        case let html as InlineHTML:
            append(html.rawHTML.lowercased().hasPrefix("<br") ? "\n" : html.rawHTML, a)
        default: inlineChildren(node, a)
        }
    }

    private func resolve(_ destination: String) -> URL? {
        URL(string: destination, relativeTo: baseURL)?.absoluteURL
    }
    private func allowedLink(_ url: URL) -> Bool {
        ["https", "http", "mailto", "file"].contains(url.scheme?.lowercased() ?? "")
    }
}
