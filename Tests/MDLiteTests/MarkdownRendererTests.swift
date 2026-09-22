import XCTest
import AppKit
@testable import MDLite

final class MarkdownRendererTests: XCTestCase {
    func testHeadingsAndUnicodeRanges() {
        let result = MarkdownRenderer().render("# Hola 🌿\n\nTexto.\n\nSegundo\n-------\n")
        XCTAssertEqual(result.outline.map(\.title), ["Hola 🌿", "Segundo"])
        XCTAssertEqual(result.outline.map(\.level), [1, 2])
        for heading in result.outline {
            XCTAssertEqual((result.text.string as NSString).substring(with: heading.range), heading.title + "\n")
        }
    }
    func testReferenceLinksAndEmphasis() {
        let result = MarkdownRenderer().render("**Fuerte** y *suave* [guía][ref].\n\n[ref]: https://example.com\n")
        XCTAssertEqual(result.text.string, "Fuerte y suave guía.\n")
        let font = result.text.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
        XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
        let position = (result.text.string as NSString).range(of: "guía").location
        XCTAssertEqual((result.text.attribute(.link, at: position, effectiveRange: nil) as? URL)?.absoluteString, "https://example.com")
    }
    func testListsCodeAndBreaks() {
        let result = MarkdownRenderer().render("3. Tres\n4. Cuatro\n\n- Uno\n  - Dos\n\n```swift\nlet x = 1\n```\n\nA  \nB\n")
        XCTAssertTrue(result.text.string.contains("3.\tTres"))
        XCTAssertTrue(result.text.string.contains("4.\tCuatro"))
        XCTAssertTrue(result.text.string.contains("•\tUno"))
        XCTAssertTrue(result.text.string.contains("◦\tDos"))
        XCTAssertTrue(result.text.string.contains("let x = 1"))
        XCTAssertTrue(result.text.string.contains("A\u{2028}B"))
    }
    func testUnsafeLinksAreNotInteractive() {
        let result = MarkdownRenderer().render("[bad](javascript:alert) [ok](https://example.com)")
        XCTAssertNil(result.text.attribute(.link, at: 0, effectiveRange: nil))
        XCTAssertNotNil(result.text.attribute(.link, at: 4, effectiveRange: nil))
    }
    func testRendererReuseDoesNotAccumulate() {
        let renderer = MarkdownRenderer()
        _ = renderer.render("# Primero")
        let result = renderer.render("# Segundo")
        XCTAssertEqual(result.outline.count, 1)
        XCTAssertEqual(result.text.string, "Segundo\n")
    }
    func testRelativeLinks() {
        let result = MarkdownRenderer(baseURL: URL(fileURLWithPath: "/tmp/docs", isDirectory: true)).render("[Archivo](other.md)")
        XCTAssertEqual((result.text.attribute(.link, at: 0, effectiveRange: nil) as? URL)?.path, "/tmp/docs/other.md")
    }
}

extension MarkdownRendererTests {
    func testNativeTableCellsAndAlignment() {
        let result = MarkdownRenderer().render("| Name | Count |\n| :--- | ---: |\n| **Long entry** | 42 |\n| Short | 7 |\n\n## After table")
        let text = result.text.string as NSString
        let firstStyle = result.text.attribute(.paragraphStyle, at: text.range(of: "Name").location, effectiveRange: nil) as! NSParagraphStyle
        let countStyle = result.text.attribute(.paragraphStyle, at: text.range(of: "42").location, effectiveRange: nil) as! NSParagraphStyle
        let firstCell = firstStyle.textBlocks.first as! NSTextTableBlock
        let countCell = countStyle.textBlocks.first as! NSTextTableBlock
        XCTAssertTrue(firstCell.table === countCell.table)
        XCTAssertEqual(firstCell.table.numberOfColumns, 2)
        XCTAssertEqual(countCell.startingRow, 1)
        XCTAssertEqual(countCell.startingColumn, 1)
        XCTAssertEqual(countStyle.alignment, .right)
        XCTAssertEqual(text.substring(with: result.outline[0].range), "After table\n")
        XCTAssertFalse(result.text.string.contains("│"))
    }

    func testHTMLBlocksRenderInsteadOfShowingTags() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mdlite-html-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let image = NSImage(size: NSSize(width: 40, height: 20), flipped: false) { rect in NSColor.red.setFill(); rect.fill(); return true }
        let png = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        try? png.write(to: folder.appendingPathComponent("icon.png"))
        let source = "# Title\n\n<p align=\"center\">\n  <img src=\"icon.png\" alt=\"Logo\" width=\"80\" />\n</p>\n\nA <kbd>⌘</kbd> key &amp; <b>bold</b>.\n"
        let result = MarkdownRenderer(baseURL: URL(fileURLWithPath: folder.path, isDirectory: true)).render(source)
        let text = result.text.string
        XCTAssertFalse(text.contains("<p"))
        XCTAssertFalse(text.contains("<img"))
        XCTAssertFalse(text.contains("<kbd>"))
        let attachment = (text as NSString).range(of: "\u{FFFC}")
        XCTAssertNotEqual(attachment.location, NSNotFound)
        let style = result.text.attribute(.paragraphStyle, at: attachment.location, effectiveRange: nil) as! NSParagraphStyle
        XCTAssertEqual(style.alignment, .center)
        let cell = (result.text.attribute(.attachment, at: attachment.location, effectiveRange: nil) as! NSTextAttachment).attachmentCell as! MDImageCell
        XCTAssertEqual(cell.preferred.width, 80, accuracy: 0.5)
        XCTAssertTrue(text.contains("A ⌘ key & bold."))
        let bold = result.text.attribute(.font, at: (text as NSString).range(of: "bold").location, effectiveRange: nil) as! NSFont
        XCTAssertTrue(NSFontManager.shared.traits(of: bold).contains(.boldFontMask))
    }

    func testCenteredDivWrapsMarkdownAndHidesComments() {
        let result = MarkdownRenderer().render("<div align=\"center\">\n\n# Centered\n\n</div>\n\n<!-- hidden -->\n\nLeft\n")
        let text = result.text.string as NSString
        let heading = result.text.attribute(.paragraphStyle, at: text.range(of: "Centered").location, effectiveRange: nil) as! NSParagraphStyle
        let left = result.text.attribute(.paragraphStyle, at: text.range(of: "Left").location, effectiveRange: nil) as! NSParagraphStyle
        XCTAssertEqual(heading.alignment, .center)
        XCTAssertNotEqual(left.alignment, .center)
        XCTAssertFalse(result.text.string.contains("hidden"))
    }

    func testHTMLTableAndScriptFiltering() {
        let result = MarkdownRenderer().render("<table><tr><th>Key</th><th>Value</th></tr><tr><td>a</td><td>1</td></tr></table>\n\n<script>alert(1)</script>\n")
        let text = result.text.string as NSString
        XCTAssertFalse(result.text.string.contains("alert"))
        let style = result.text.attribute(.paragraphStyle, at: text.range(of: "Value").location, effectiveRange: nil) as! NSParagraphStyle
        XCTAssertEqual((style.textBlocks.first as? NSTextTableBlock)?.table.numberOfColumns, 2)
    }

    func testGitHubAlerts() {
        let result = MarkdownRenderer(language: "en").render("> [!NOTE]\n> Internal packages are shared.\n")
        XCTAssertTrue(result.text.string.contains("Note\n"))
        XCTAssertTrue(result.text.string.contains("Internal packages are shared."))
        XCTAssertFalse(result.text.string.contains("[!NOTE]"))
        let decorations = result.text.attribute(.mdBlocks, at: 0, effectiveRange: nil) as? [MDBlockDecoration]
        XCTAssertEqual(decorations?.first?.kind, .alert)
    }

    func testExtendedAutolinksAndNoSmartPunctuation() {
        let result = MarkdownRenderer().render("Visit www.example.com/path. Mail me@example.org -- \"quoted\" `x`\n")
        let text = result.text.string as NSString
        XCTAssertEqual((result.text.attribute(.link, at: text.range(of: "www.example.com").location, effectiveRange: nil) as? URL)?.absoluteString,
                       "http://www.example.com/path")
        XCTAssertNil(result.text.attribute(.link, at: text.range(of: ". Mail").location, effectiveRange: nil))
        XCTAssertEqual((result.text.attribute(.link, at: text.range(of: "me@").location, effectiveRange: nil) as? URL)?.absoluteString,
                       "mailto:me@example.org")
        XCTAssertTrue(result.text.string.contains("-- \"quoted\""))
    }

    func testCodeBlocksAreSingleBoxesWithCopyAndHighlighting() {
        let result = MarkdownRenderer().render("```swift\nlet value = \"hi\"\nreturn value\n```\n")
        let text = result.text.string as NSString
        let decorations = result.text.attribute(.mdBlocks, at: 0, effectiveRange: nil) as? [MDBlockDecoration]
        let box = decorations?.first
        XCTAssertEqual(box?.kind, .code)
        XCTAssertEqual(box?.code, "let value = \"hi\"\nreturn value")
        XCTAssertEqual(box?.label, "swift")
        XCTAssertEqual(box?.range.length, text.length)
        let second = result.text.attribute(.paragraphStyle, at: text.range(of: "return").location, effectiveRange: nil) as! NSParagraphStyle
        XCTAssertEqual(second.paragraphSpacingBefore, 0)
        let keyword = result.text.attribute(.foregroundColor, at: text.range(of: "let").location, effectiveRange: nil) as? NSColor
        XCTAssertEqual(keyword, MDColors.keyword)
    }

    func testTaskListsAnchorsAndFrontMatter() {
        let source = "---\ntitle: Demo\n---\n# My Title\n\n- [ ] Todo\n- [x] Done\n\n[jump](#my-title)\n"
        let result = MarkdownRenderer().render(source)
        XCTAssertEqual(result.outline.first?.anchor, "my-title")
        XCTAssertEqual(result.outline.first?.source, (source as NSString).range(of: "# My Title").location)
        var tasks: [Int] = []
        result.text.enumerateAttribute(.mdTask, in: NSRange(location: 0, length: result.text.length)) { value, _, _ in
            if let value = value as? Int { tasks.append(value) }
        }
        XCTAssertEqual(tasks, [(source as NSString).range(of: "[ ]").location, (source as NSString).range(of: "[x]").location])
        let link = result.text.attribute(.link, at: (result.text.string as NSString).range(of: "jump").location, effectiveRange: nil) as? URL
        XCTAssertEqual(link?.absoluteString, "x-mdlite-anchor:my-title")
        XCTAssertTrue(result.text.string.contains("title: Demo"))
    }

    func testSourceMapHandlesMultibyteText() {
        let source = "é🌿\n## Título\n"
        let result = MarkdownRenderer().render(source)
        XCTAssertEqual(result.outline.first?.source, (source as NSString).range(of: "## Título").location)
        XCTAssertEqual(result.renderedOffset(forSource: (source as NSString).range(of: "## Título").location), result.outline.first?.range.location)
    }

    func testHTMLEntitiesDecode() {
        XCTAssertEqual(HTML.decodeEntities("&lt;a&gt; &amp; &#169; &#x1F600; &nbsp;"), "<a> & © 😀 \u{00A0}")
    }
}

final class EditorTests: XCTestCase {
    private func styled(_ source: String, live: Bool = true) -> (MarkdownStyler.Analysis, NSString) {
        let styler = MarkdownStyler(size: 17, accent: .systemBlue, live: live, baseURL: nil)
        return (styler.analyze(source), source as NSString)
    }

    func testLiveStylerConcealsMarkersOutsideActiveLine() {
        let (analysis, text) = styled("# Title\n\nSome **bold** and `code`.\n")
        let concealed = analysis.conceals.map { text.substring(with: $0.range) }
        XCTAssertTrue(concealed.contains("# "))
        XCTAssertEqual(concealed.filter { $0 == "**" }.count, 2)
        XCTAssertEqual(concealed.filter { $0 == "`" }.count, 2)

        let storage = NSTextStorage(string: text as String)
        let styler = MarkdownStyler(size: 17, accent: .systemBlue, live: true, baseURL: nil)
        let secondLine = text.lineRange(for: NSRange(location: text.range(of: "Some").location, length: 0))
        styler.apply(analysis, to: storage, active: secondLine)
        func hidden(_ index: Int) -> Bool {
            storage.attribute(.mdConceal, at: index, effectiveRange: nil) != nil
                || (storage.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor) == .clear
        }
        XCTAssertTrue(hidden(0), "Heading marker hidden when caret is elsewhere")
        XCTAssertFalse(hidden(text.range(of: "**").location), "Active line shows markers")
        XCTAssertEqual(storage.string, text as String, "Styling never changes the text")
    }

    func testContinuationLinesKeepMarkersAligned() {
        let (analysis, text) = styled("First line of a paragraph\n Texto **nuevo** y [link](https://a.b) aquí.\n")
        let hidden = analysis.conceals.map { text.substring(with: $0.range) }
        XCTAssertEqual(hidden.filter { $0 == "**" }.count, 2)
        XCTAssertTrue(hidden.contains("["))
        XCTAssertTrue(hidden.contains("](https://a.b)"))
    }

    func testCodeModeKeepsEverythingVisible() {
        let (analysis, text) = styled("# Title\n\n- [ ] task\n", live: false)
        let storage = NSTextStorage(string: text as String)
        MarkdownStyler(size: 17, accent: .systemBlue, live: false, baseURL: nil).apply(analysis, to: storage, active: NSRange(location: 0, length: 0))
        var concealed = false
        storage.enumerateAttribute(.mdConceal, in: NSRange(location: 0, length: storage.length)) { value, _, _ in if value != nil { concealed = true } }
        storage.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: storage.length)) { value, _, _ in if (value as? NSColor) == .clear { concealed = true } }
        XCTAssertFalse(concealed)
    }

    func testFencedCodeFencesCollapseAndCopyContent() {
        let (analysis, text) = styled("Intro\n\n```js\nconst a = 1\n```\n")
        let fences = analysis.conceals.filter { $0.collapse }.map { text.substring(with: $0.range) }
        XCTAssertEqual(fences, ["```js", "```"])
        XCTAssertEqual(analysis.decorations.first { $0.kind == .code }?.code, "const a = 1")
    }

    @MainActor
    func testListContinuationAndFormatting() {
        let view = MDTextView.make()
        view.string = "- first"
        view.setSelectedRange(NSRange(location: 7, length: 0))
        XCTAssertTrue(view.continueBlockOnNewline())
        XCTAssertEqual(view.string, "- first\n- ")
        XCTAssertTrue(view.continueBlockOnNewline())
        XCTAssertEqual(view.string, "- first\n")

        view.string = "1. one"
        view.setSelectedRange(NSRange(location: 6, length: 0))
        XCTAssertTrue(view.continueBlockOnNewline())
        XCTAssertEqual(view.string, "1. one\n2. ")

        view.string = "- [x] done"
        view.setSelectedRange(NSRange(location: 10, length: 0))
        XCTAssertTrue(view.continueBlockOnNewline())
        XCTAssertEqual(view.string, "- [x] done\n- [ ] ")

        view.string = "word"
        view.setSelectedRange(NSRange(location: 0, length: 4))
        view.perform(.bold)
        XCTAssertEqual(view.string, "**word**")
        view.perform(.bold)
        XCTAssertEqual(view.string, "word")
        view.perform(.heading2)
        XCTAssertEqual(view.string, "## word")
        view.perform(.heading2)
        XCTAssertEqual(view.string, "word")
        view.perform(.bulletList)
        XCTAssertEqual(view.string, "- word")
        view.perform(.bulletList)
        XCTAssertEqual(view.string, "word")
    }

    func testWorkspaceScannerFindsMarkdownAndSkipsNoise() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mdlite-ws-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("docs/guides"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("node_modules/pkg"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("images"), withIntermediateDirectories: true)
        for file in ["README.md", "docs/guides/setup.markdown", "docs/b.md", "node_modules/pkg/readme.md", "images/logo.png", ".hidden.md"] {
            try Data("# x".utf8).write(to: root.appendingPathComponent(file))
        }
        let tree = WorkspaceScanner.scan(root)
        XCTAssertEqual(tree.map(\.name), ["docs", "README.md"])
        XCTAssertEqual(tree.first?.children?.map(\.name), ["guides", "b.md"])
        XCTAssertEqual(tree.first?.children?.first?.children?.map(\.name), ["setup.markdown"])
    }

    func testUpdateVersionComparison() {
        XCTAssertTrue(UpdateChecker.isNewer("v0.3.0", than: "0.2.2"))
        XCTAssertTrue(UpdateChecker.isNewer("1.0", than: "0.9.9"))
        XCTAssertFalse(UpdateChecker.isNewer("v0.3.0", than: "0.3.0"))
        XCTAssertFalse(UpdateChecker.isNewer("0.2.10", than: "0.3.0"))
    }
}
