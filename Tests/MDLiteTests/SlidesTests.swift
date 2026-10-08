import XCTest
@testable import MDLite

final class SlidesTests: XCTestCase {
    func testSplitsOnRulesWithBlankLineBefore() {
        let deck = "# One\n\nHello\n\n---\n\n# Two\n\n---\n\n# Three"
        XCTAssertEqual(Slides.split(deck).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }, ["# One\n\nHello", "# Two", "# Three"])
    }

    func testSetextHeadingIsNotABreak() {
        XCTAssertEqual(Slides.split("Title\n---\n\nText").count, 1)
    }

    func testIgnoresRulesInsideCodeAndFrontMatter() {
        let deck = "---\ntitle: Deck\n---\n# A\n\n```\n\n---\n```\n\n---\n\n# B"
        let slides = Slides.split(deck)
        XCTAssertEqual(slides.count, 2)
        XCTAssertTrue(slides[0].contains("```\n\n---\n```"))
    }

    func testDropsEmptySlides() {
        XCTAssertEqual(Slides.split("\n---\n\n# Only\n\n---\n").count, 1)
    }
}
