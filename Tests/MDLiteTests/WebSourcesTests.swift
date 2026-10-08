import XCTest
@testable import MDLite

final class WebSourcesTests: XCTestCase {
    func testGitHubLinksBecomeRaw() {
        func raw(_ string: String) -> String { WebSources.rawURL(for: URL(string: string)!).absoluteString }
        XCTAssertEqual(raw("https://github.com/glozahn/md-lite/blob/main/README.md"),
                       "https://raw.githubusercontent.com/glozahn/md-lite/main/README.md")
        XCTAssertEqual(raw("https://github.com/glozahn/md-lite/blob/main/docs/guide/setup.md"),
                       "https://raw.githubusercontent.com/glozahn/md-lite/main/docs/guide/setup.md")
        XCTAssertEqual(raw("https://github.com/glozahn/md-lite"),
                       "https://raw.githubusercontent.com/glozahn/md-lite/HEAD/README.md")
        XCTAssertEqual(raw("https://gist.github.com/someone/abc123"), "https://gist.githubusercontent.com/someone/abc123/raw")
        XCTAssertEqual(raw("https://example.com/notes.md"), "https://example.com/notes.md")
    }

    func testPastedLinks() {
        XCTAssertNotNil(WebSources.link(in: "  https://example.com/a.md \n"))
        XCTAssertNil(WebSources.link(in: "# Title\nhttps://example.com"))
        XCTAssertNil(WebSources.link(in: "file:///etc/hosts"))
        XCTAssertNil(WebSources.link(in: "just words"))
    }

    func testRSSBecomesMarkdown() throws {
        let rss = """
        <?xml version="1.0"?><rss version="2.0"><channel><title>Release notes</title>
        <description>What changed</description>
        <item><title>Version 2 &amp; more</title><link>https://example.com/2</link>
        <pubDate>Tue, 07 Oct 2026 10:00:00 GMT</pubDate>
        <description><![CDATA[<p>New <b>tabs</b> and [links].</p><script>alert(1)</script>]]></description></item>
        <item><title>Version 1</title><link>https://example.com/1</link></item>
        </channel></rss>
        """
        let markdown = try XCTUnwrap(FeedReader.markdown(from: Data(rss.utf8), source: URL(string: "https://example.com/feed")!))
        XCTAssertTrue(markdown.hasPrefix("# Release notes"))
        XCTAssertTrue(markdown.contains("## [Version 2 & more](https://example.com/2)"))
        XCTAssertTrue(markdown.contains("## [Version 1](https://example.com/1)"))
        XCTAssertTrue(markdown.contains("New tabs and \\[links\\]."))
        XCTAssertFalse(markdown.contains("<script"))
        let rendered = MarkdownRenderer().render(markdown)
        XCTAssertEqual(rendered.outline.map(\.title), ["Release notes", "Version 2 & more", "Version 1"])
    }

    func testAtomBecomesMarkdown() throws {
        let atom = """
        <?xml version="1.0" encoding="utf-8"?><feed xmlns="http://www.w3.org/2005/Atom"><title>Blog</title>
        <entry><title>Hello</title><link rel="alternate" href="https://blog.example/hello"/>
        <updated>2026-10-01T09:00:00Z</updated><summary>First post</summary></entry></feed>
        """
        let markdown = try XCTUnwrap(FeedReader.markdown(from: Data(atom.utf8), source: URL(string: "https://blog.example/atom")!))
        XCTAssertTrue(markdown.contains("## [Hello](https://blog.example/hello)"))
        XCTAssertTrue(markdown.contains("First post"))
        XCTAssertTrue(markdown.contains("2026"))
        XCTAssertFalse(markdown.contains("T09:00:00Z"))
        XCTAssertFalse(FeedReader.readableDate("Tue, 07 Oct 2026 10:00:00 GMT").contains("GMT"))
        XCTAssertEqual(FeedReader.readableDate("someday"), "someday")
    }
}
