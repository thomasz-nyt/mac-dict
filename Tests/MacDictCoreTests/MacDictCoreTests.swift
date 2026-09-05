import Foundation
import XCTest
@testable import MacDictCore


final class QueryNormalizerTests: XCTestCase {
    func testTrimsSurroundingPunctuationAndCollapsesWhitespace() {
        XCTAssertEqual(QueryNormalizer.normalize("  “hello”  \n"), "hello")
        XCTAssertEqual(QueryNormalizer.normalize("state   of   mind"), "state of mind")
    }

    func testPreservesApostrophesAndHyphens() {
        XCTAssertEqual(QueryNormalizer.normalize("mother-in-law"), "mother-in-law")
        XCTAssertEqual(QueryNormalizer.normalize("don't"), "don't")
    }

    func testRejectsEmptyAndUnreasonablyLongQueries() {
        XCTAssertNil(QueryNormalizer.normalize("…"))
        XCTAssertNil(QueryNormalizer.normalize(String(repeating: "a", count: 81)))
    }

    func testCacheKeyIsCaseInsensitive() {
        XCTAssertEqual(QueryNormalizer.cacheKey("Read"), QueryNormalizer.cacheKey("read"))
    }
}


final class DictionaryAPIClientTests: XCTestCase {
    func testParsesDefinitionExampleAttributionAndProtocolRelativeAudio() throws {
        let fixtureURL = Bundle.module.url(forResource: "hello", withExtension: "json")!
        let entry = try DictionaryAPIClient.parse(Data(contentsOf: fixtureURL))

        XCTAssertEqual(entry.word, "hello")
        XCTAssertEqual(entry.phonetic, "/həˈləʊ/")
        XCTAssertEqual(entry.audioURL?.absoluteString, "https://api.dictionaryapi.dev/media/pronunciations/en/hello-us.mp3")
        XCTAssertEqual(entry.firstDefinition?.text, "A greeting used when meeting someone.")
        XCTAssertEqual(entry.firstDefinition?.example, "Hello, everyone.")
        XCTAssertEqual(entry.license?.name, "CC BY-SA 3.0")
        XCTAssertEqual(entry.sourceURLs.first?.host, "en.wiktionary.org")
    }

    func testRejectsResponseWithoutDefinitions() {
        let data = Data(#"[{"word":"empty","phonetics":[],"meanings":[]}]"#.utf8)
        XCTAssertThrowsError(try DictionaryAPIClient.parse(data)) { error in
            XCTAssertEqual(error as? DictionaryAPIError, .emptyEntry)
        }
    }

    func testRejectsNonEntryResponse() {
        let data = Data(#"{"title":"No Definitions Found"}"#.utf8)
        XCTAssertThrowsError(try DictionaryAPIClient.parse(data)) { error in
            XCTAssertEqual(error as? DictionaryAPIError, .invalidResponse)
        }
    }
}


final class DictionaryCacheTests: XCTestCase {
    func testRoundTripAndRemoval() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let cache = DictionaryCache(directory: directory)
        let entry = DictionaryEntry(
            word: "read",
            phonetic: "/riːd/",
            audioURL: nil,
            meanings: [
                DictionaryMeaning(
                    partOfSpeech: "verb",
                    definitions: [
                        DictionaryDefinition(
                            text: "To interpret written symbols.",
                            example: "I read every day.",
                            synonyms: [],
                            antonyms: []
                        )
                    ],
                    synonyms: [],
                    antonyms: []
                )
            ],
            sourceURLs: [],
            license: SourceLicense(name: "CC BY-SA 3.0", url: nil)
        )

        try await cache.store(entry, for: "Read")
        let cached = await cache.entry(for: "read")
        XCTAssertEqual(cached, entry)
        try await cache.removeAll()
        let removed = await cache.entry(for: "read")
        XCTAssertNil(removed)
    }
}


final class SpeechTextBuilderTests: XCTestCase {
    func testFullEntryReadsEnglishBeforeChineseAndOmitsAttribution() {
        let result = LookupResult(
            query: "hello",
            english: DictionaryEntry(
                word: "hello",
                phonetic: nil,
                audioURL: nil,
                meanings: [
                    DictionaryMeaning(
                        partOfSpeech: "interjection",
                        definitions: [
                            DictionaryDefinition(
                                text: "A greeting.",
                                example: "Hello there.",
                                synonyms: [],
                                antonyms: []
                            )
                        ],
                        synonyms: [],
                        antonyms: []
                    )
                ],
                sourceURLs: [URL(string: "https://example.com")!],
                license: SourceLicense(name: "Example license", url: nil)
            ),
            chinese: ChineseHint(headword: "hello", phonetic: nil, lines: ["你好", "喂"])
        )

        let segments = SpeechTextBuilder.fullEntrySegments(from: result)
        XCTAssertEqual(segments.map(\.language), ["en-US", "en-US", "en-US", "zh-CN"])
        XCTAssertEqual(segments.last?.text, "你好。喂")
        XCTAssertFalse(segments.map(\.text).joined().contains("example.com"))
    }
}


final class RecentQueriesStoreTests: XCTestCase {
    func testHistoryDeduplicatesCaseInsensitivelyAndFavoritesToggle() async {
        await MainActor.run {
            let suite = "RecentQueriesStoreTests-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = RecentQueriesStore(defaults: defaults)

            store.record("Hello")
            store.record("world")
            store.record("hello")
            XCTAssertEqual(store.history, ["hello", "world"])

            store.toggleFavorite("hello")
            XCTAssertTrue(store.isFavorite("HELLO"))
            store.toggleFavorite("Hello")
            XCTAssertFalse(store.isFavorite("hello"))

            store.clearHistory()
            XCTAssertTrue(store.history.isEmpty)
        }
    }
}
