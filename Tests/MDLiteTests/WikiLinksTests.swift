import XCTest
@testable import MDLite

final class WikiLinksTests: XCTestCase {
    func testFindsTargetsAndLabels() {
        let spans = WikiLinks.spans(in: "See [[Ideas]] and [[notes/Plan|the plan]], not [[]] or [x].")
        XCTAssertEqual(spans.map(\.target), ["Ideas", "notes/Plan"])
        XCTAssertEqual(spans.map(\.label), ["Ideas", "the plan"])
    }

    func testURLRoundTrip() throws {
        let url = try XCTUnwrap(WikiLinks.url(for: "My Note#Part"))
        XCTAssertEqual(WikiLinks.target(of: url), "My Note#Part")
    }

    func testResolvesAndFindsMentions() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sub = folder.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = sub.appendingPathComponent("Ideas.md")
        let a = folder.appendingPathComponent("a.md")
        let b = folder.appendingPathComponent("b.md")
        try "# Ideas".write(to: target, atomically: true, encoding: .utf8)
        try "intro\nsee [[ideas]] here\nother".write(to: a, atomically: true, encoding: .utf8)
        try "a [link](sub/Ideas.md)\nideas without link".write(to: b, atomically: true, encoding: .utf8)
        let files = [target, a, b]
        XCTAssertEqual(WikiLinks.resolve("Ideas", from: a, in: files)?.standardizedFileURL, target.standardizedFileURL)
        XCTAssertNil(WikiLinks.resolve("Missing", from: a, in: files))
        let mentions = WikiLinks.mentions(of: target, in: files)
        XCTAssertEqual(mentions.map(\.text), ["see [[ideas]] here", "a [link](sub/Ideas.md)"])
        XCTAssertEqual(mentions.first?.offset, 6)
    }
}
