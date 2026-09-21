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
        XCTAssertTrue(result.text.string.contains("3.  Tres"))
        XCTAssertTrue(result.text.string.contains("4.  Cuatro"))
        XCTAssertTrue(result.text.string.contains("•  Dos"))
        XCTAssertTrue(result.text.string.contains("let x = 1"))
        XCTAssertTrue(result.text.string.contains("A\nB"))
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
