import XCTest
@testable import MDLite

final class ReadingPreferencesTests: XCTestCase {
    func testSystemLanguageSelection() {
        XCTAssertEqual(ReaderLanguage.resolve("system", preferred: ["es-HN", "en-US"]), "es")
        XCTAssertEqual(ReaderLanguage.resolve("system", preferred: ["en-GB", "es"]), "en")
        XCTAssertEqual(ReaderLanguage.resolve("system", preferred: ["fr", "es-MX"]), "es")
        XCTAssertEqual(ReaderLanguage.resolve("system", preferred: ["ja"]), "en")
        XCTAssertEqual(ReaderLanguage.resolve("en", preferred: ["es"]), "en")
        XCTAssertEqual(ReaderLanguage.resolve("es", preferred: ["en"]), "es")
    }

    @MainActor
    func testPastedDocumentSurvivesPreferenceChanges() {
        let store = ReaderStore()
        let language = store.language
        let accent = store.accent
        defer { store.language = language; store.accent = accent }
        let input = "# My own text\n\n**Keep this**"
        XCTAssertTrue(store.readPastedText(input))
        store.language = "es"
        store.accent = "purple"
        XCTAssertEqual(store.source, input)
        XCTAssertEqual(store.title, "Texto pegado")
        XCTAssertEqual(store.rendered.outline.first?.title, "My own text")
        store.language = "en"
        XCTAssertEqual(store.source, input)
        XCTAssertEqual(store.title, "Pasted Text")
        XCTAssertFalse(store.readPastedText("  \n"))
        XCTAssertEqual(store.source, input)
        XCTAssertFalse(store.readPastedText(String(repeating: "a", count: 5_000_001)))
        XCTAssertEqual(store.source, input)
        store.welcome()
        XCTAssertTrue(store.isWelcome)
        XCTAssertTrue(store.source.contains("A little space"))
    }
}
