import XCTest
import AppKit
@testable import MDLite

final class FileTypesTests: XCTestCase {
    func testKinds() {
        func kind(_ name: String) -> DocumentKind? { FileTypes.kind(of: URL(fileURLWithPath: "/tmp/" + name)) }
        XCTAssertEqual(kind("README.md"), .markdown)
        XCTAssertEqual(kind("schema.SQL"), .code(language: "sql"))
        XCTAssertEqual(kind("deploy.sh"), .code(language: "shell"))
        XCTAssertEqual(kind("config.yml"), .code(language: "yaml"))
        XCTAssertEqual(kind("Cargo.toml"), .code(language: "ini"))
        XCTAssertEqual(kind("notes.txt"), .text)
        XCTAssertEqual(kind("people.csv"), .table(separator: ","))
        XCTAssertEqual(kind("people.tsv"), .table(separator: "\t"))
        XCTAssertEqual(kind("server.log"), .log)
        XCTAssertEqual(kind("Dockerfile"), .code(language: "dockerfile"))
        XCTAssertEqual(kind("Dockerfile.dev"), .code(language: "dockerfile"))
        XCTAssertEqual(kind("Makefile"), .code(language: "makefile"))
        XCTAssertEqual(kind(".env.local"), .code(language: "ini"))
        XCTAssertNil(kind("photo.jpg"))
        XCTAssertNil(kind("archive.zip"))
        XCTAssertTrue(DocumentKind.log.isReadOnly)
        XCTAssertFalse(DocumentKind.code(language: "sql").isReadOnly)
    }

    func testDelimitedParsing() {
        let csv = "name,quote,city\r\nAda,\"Hello, \"\"world\"\"\",London\nGrace,\"two\nlines\",\n"
        let rows = FileTypes.parseDelimited(csv, separator: ",")
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[1], ["Ada", "Hello, \"world\"", "London"])
        XCTAssertEqual(rows[2], ["Grace", "two\nlines", ""])
        XCTAssertEqual(FileTypes.parseDelimited("a\tb\n1\t2", separator: "\t"), [["a", "b"], ["1", "2"]])
    }

    func testCSVBecomesATable() {
        let markdown = FileTypes.markdownTable(from: "name,note\nAda,a|b *x*\nGrace\n", separator: ",")
        let lines = markdown.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines[0], "| name | note |")
        XCTAssertEqual(lines[1], "| --- | --- |")
        XCTAssertEqual(lines[2], "| Ada | a\\|b \\*x\\* |")
        XCTAssertEqual(lines[3], "| Grace |  |")
        let rendered = MarkdownRenderer().render(file: "name,age\nAda,36\n", kind: .table(separator: ","))
        XCTAssertNotNil(rendered.text.attribute(.paragraphStyle, at: 0, effectiveRange: nil))
        XCTAssertTrue(rendered.text.string.contains("Ada"))
        let many = "n\n" + (1...30).map(String.init).joined(separator: "\n")
        XCTAssertTrue(FileTypes.markdownTable(from: many, separator: ",", limit: 10).contains("*10 / 30*"))
    }

    func testMinifiedJSONIsIndentedInOrder() {
        let minified = #"{"zeta":1,"alpha":{"list":[1,2,{"inner":"a,b:c"}],"empty":{}},"note":"say \"hi\"","padding":"\#(String(repeating: "x", count: 200))"}"#
        let pretty = FileTypes.prettyJSON(minified)
        XCTAssertTrue(pretty.contains("\n"))
        XCTAssertLessThan(pretty.range(of: "zeta")!.lowerBound, pretty.range(of: "alpha")!.lowerBound)
        XCTAssertTrue(pretty.contains(#""inner": "a,b:c""#))
        XCTAssertTrue(pretty.contains(#""empty": {}"#))
        XCTAssertTrue(pretty.contains(#""say \"hi\"""#))
        let compact = pretty.filter { !$0.isWhitespace }
        XCTAssertEqual(compact, minified.filter { !$0.isWhitespace })
        // Already formatted or broken JSON is left alone.
        XCTAssertEqual(FileTypes.prettyJSON("{\n  \"a\": 1\n}"), "{\n  \"a\": 1\n}")
        let broken = "{" + String(repeating: "x", count: 300)
        XCTAssertEqual(FileTypes.prettyJSON(broken), broken)
    }

    func testCodeAndTextRenderAsWritten() {
        let sql = "SELECT * FROM users -- *not* markdown\n# not a heading\n"
        let code = MarkdownRenderer().render(file: sql, kind: .code(language: "sql"))
        XCTAssertTrue(code.outline.isEmpty)
        XCTAssertTrue(code.text.string.contains("# not a heading"))
        XCTAssertTrue(code.text.string.contains("*not*"))
        let text = MarkdownRenderer().render(file: "# Title?\n**plain**\n", kind: .text)
        XCTAssertEqual(text.text.string, "# Title?\n**plain**\n")
        XCTAssertTrue(text.outline.isEmpty)
    }
}
