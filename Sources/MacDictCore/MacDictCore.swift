import CSQLite
import Combine
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct SourceLicense: Codable, Equatable, Sendable {
    public let name: String
    public let url: URL?

    public init(name: String, url: URL?) {
        self.name = name
        self.url = url
    }
}

public struct DictionaryDefinition: Codable, Equatable, Sendable {
    public let text: String
    public let example: String?
    public let synonyms: [String]
    public let antonyms: [String]

    public init(text: String, example: String?, synonyms: [String], antonyms: [String]) {
        self.text = text
        self.example = example
        self.synonyms = synonyms
        self.antonyms = antonyms
    }
}

public struct DictionaryMeaning: Codable, Equatable, Sendable {
    public let partOfSpeech: String
    public let definitions: [DictionaryDefinition]
    public let synonyms: [String]
    public let antonyms: [String]

    public init(
        partOfSpeech: String,
        definitions: [DictionaryDefinition],
        synonyms: [String],
        antonyms: [String]
    ) {
        self.partOfSpeech = partOfSpeech
        self.definitions = definitions
        self.synonyms = synonyms
        self.antonyms = antonyms
    }
}

public struct DictionaryEntry: Codable, Equatable, Sendable {
    public let word: String
    public let phonetic: String?
    public let audioURL: URL?
    public let meanings: [DictionaryMeaning]
    public let sourceURLs: [URL]
    public let license: SourceLicense?

    public init(
        word: String,
        phonetic: String?,
        audioURL: URL?,
        meanings: [DictionaryMeaning],
        sourceURLs: [URL],
        license: SourceLicense?
    ) {
        self.word = word
        self.phonetic = phonetic
        self.audioURL = audioURL
        self.meanings = meanings
        self.sourceURLs = sourceURLs
        self.license = license
    }

    public var firstDefinition: DictionaryDefinition? {
        meanings.lazy.compactMap(\.definitions.first).first
    }
}

public struct ChineseHint: Codable, Equatable, Sendable {
    public let headword: String
    public let phonetic: String?
    public let lines: [String]

    public init(headword: String, phonetic: String?, lines: [String]) {
        self.headword = headword
        self.phonetic = phonetic
        self.lines = lines
    }

    public var spokenText: String {
        lines.joined(separator: "。")
    }
}

public struct LookupResult: Equatable, Sendable {
    public var query: String
    public var english: DictionaryEntry?
    public var chinese: ChineseHint?

    public init(query: String, english: DictionaryEntry? = nil, chinese: ChineseHint? = nil) {
        self.query = query
        self.english = english
        self.chinese = chinese
    }
}

public enum QueryNormalizer {
    private static let surroundingCharacters = CharacterSet.whitespacesAndNewlines
        .union(.punctuationCharacters)
        .subtracting(CharacterSet(charactersIn: "-'"))

    public static func normalize(_ rawValue: String) -> String? {
        let collapsed = rawValue
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: surroundingCharacters)

        guard !collapsed.isEmpty, collapsed.count <= 80 else {
            return nil
        }
        return collapsed
    }

    public static func cacheKey(_ query: String) -> String {
        query.lowercased(with: Locale(identifier: "en_US_POSIX"))
    }
}

public enum DictionaryAPIError: LocalizedError, Equatable {
    case invalidQuery
    case notFound
    case invalidResponse
    case server(statusCode: Int)
    case emptyEntry

    public var errorDescription: String? {
        switch self {
        case .invalidQuery:
            return "Enter one English word or a short phrase."
        case .notFound:
            return "No English entry was found."
        case .invalidResponse:
            return "The dictionary returned an unreadable response."
        case .server(let statusCode):
            return "The dictionary service returned HTTP \(statusCode)."
        case .emptyEntry:
            return "The dictionary entry did not contain a definition."
        }
    }
}

public actor DictionaryAPIClient {
    private let session: URLSession
    private let decoder: JSONDecoder

    public init(session: URLSession = .shared) {
        self.session = session
        self.decoder = JSONDecoder()
    }

    public func lookup(_ rawQuery: String) async throws -> DictionaryEntry {
        guard let query = QueryNormalizer.normalize(rawQuery) else {
            throw DictionaryAPIError.invalidQuery
        }
        var pathComponentCharacters = CharacterSet.urlPathAllowed
        pathComponentCharacters.remove(charactersIn: "/?#")
        guard let escaped = query.addingPercentEncoding(withAllowedCharacters: pathComponentCharacters),
              let url = URL(string: "https://api.dictionaryapi.dev/api/v2/entries/en/\(escaped)") else {
            throw DictionaryAPIError.invalidQuery
        }

        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("MacDict/0.1 (+https://github.com/thomasz-nyt/mac-dict)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DictionaryAPIError.invalidResponse
        }
        if http.statusCode == 404 {
            throw DictionaryAPIError.notFound
        }
        guard (200..<300).contains(http.statusCode) else {
            throw DictionaryAPIError.server(statusCode: http.statusCode)
        }
        return try Self.parse(data, decoder: decoder)
    }

    public nonisolated static func parse(_ data: Data, decoder: JSONDecoder = JSONDecoder()) throws -> DictionaryEntry {
        let entries: [APIEntry]
        do {
            entries = try decoder.decode([APIEntry].self, from: data)
        } catch {
            throw DictionaryAPIError.invalidResponse
        }
        guard let entry = entries.first else {
            throw DictionaryAPIError.emptyEntry
        }

        let meanings = entry.meanings.compactMap { meaning -> DictionaryMeaning? in
            let definitions = meaning.definitions.compactMap { definition -> DictionaryDefinition? in
                let text = definition.definition.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return DictionaryDefinition(
                    text: text,
                    example: definition.example?.nilIfBlank,
                    synonyms: definition.synonyms ?? [],
                    antonyms: definition.antonyms ?? []
                )
            }
            guard !definitions.isEmpty else { return nil }
            return DictionaryMeaning(
                partOfSpeech: meaning.partOfSpeech.nilIfBlank ?? "meaning",
                definitions: definitions,
                synonyms: meaning.synonyms ?? [],
                antonyms: meaning.antonyms ?? []
            )
        }
        guard !meanings.isEmpty else {
            throw DictionaryAPIError.emptyEntry
        }

        let phonetic = entry.phonetic?.nilIfBlank
            ?? entry.phonetics.compactMap { $0.text?.nilIfBlank }.first
        let audioURL = entry.phonetics
            .compactMap { Self.normalizedURL($0.audio) }
            .first
        let license = entry.license.map {
            SourceLicense(name: $0.name, url: URL(string: $0.url))
        }

        return DictionaryEntry(
            word: entry.word,
            phonetic: phonetic,
            audioURL: audioURL,
            meanings: meanings,
            sourceURLs: entry.sourceUrls.compactMap(URL.init(string:)),
            license: license
        )
    }

    private nonisolated static func normalizedURL(_ value: String?) -> URL? {
        guard let value = value?.nilIfBlank else { return nil }
        if value.hasPrefix("//") {
            return URL(string: "https:\(value)")
        }
        return URL(string: value)
    }
}

private struct APIEntry: Decodable {
    let word: String
    let phonetic: String?
    let phonetics: [APIPhonetic]
    let meanings: [APIMeaning]
    let license: APILicense?
    let sourceUrls: [String]

    enum CodingKeys: String, CodingKey {
        case word, phonetic, phonetics, meanings, license
        case sourceUrls = "sourceUrls"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        word = try container.decode(String.self, forKey: .word)
        phonetic = try container.decodeIfPresent(String.self, forKey: .phonetic)
        phonetics = try container.decodeIfPresent([APIPhonetic].self, forKey: .phonetics) ?? []
        meanings = try container.decodeIfPresent([APIMeaning].self, forKey: .meanings) ?? []
        license = try container.decodeIfPresent(APILicense.self, forKey: .license)
        sourceUrls = try container.decodeIfPresent([String].self, forKey: .sourceUrls) ?? []
    }
}

private struct APIPhonetic: Decodable {
    let text: String?
    let audio: String?
}

private struct APIMeaning: Decodable {
    let partOfSpeech: String
    let definitions: [APIDefinition]
    let synonyms: [String]?
    let antonyms: [String]?
}

private struct APIDefinition: Decodable {
    let definition: String
    let example: String?
    let synonyms: [String]?
    let antonyms: [String]?
}

private struct APILicense: Decodable {
    let name: String
    let url: String
}


public actor DictionaryCache {
    private let directory: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            self.directory = applicationSupport
                .appendingPathComponent("MacDict", isDirectory: true)
                .appendingPathComponent("EnglishCache", isDirectory: true)
        }
        encoder.outputFormatting = [.sortedKeys]
    }

    public func entry(for query: String) -> DictionaryEntry? {
        let url = fileURL(for: query)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(DictionaryEntry.self, from: data)
    }

    public func store(_ entry: DictionaryEntry, for query: String) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(entry)
        try data.write(to: fileURL(for: query), options: .atomic)
    }

    public func removeAll() throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    private func fileURL(for query: String) -> URL {
        let key = QueryNormalizer.cacheKey(query)
        let safeName = Data(key.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return directory.appendingPathComponent("\(safeName).json")
    }
}

public actor ECDICTStore {
    public let databaseURL: URL

    public init(databaseURL: URL? = nil) {
        if let databaseURL {
            self.databaseURL = databaseURL
        } else {
            let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            self.databaseURL = applicationSupport
                .appendingPathComponent("MacDict", isDirectory: true)
                .appendingPathComponent("ecdict.sqlite3")
        }
    }

    public var isInstalled: Bool {
        FileManager.default.fileExists(atPath: databaseURL.path)
    }

    public func lookup(_ rawQuery: String) -> ChineseHint? {
        guard isInstalled,
              let query = QueryNormalizer.normalize(rawQuery)?.lowercased() else {
            return nil
        }

        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else {
            sqlite3_close(database)
            return nil
        }
        defer { sqlite3_close(database) }

        let sql = """
            SELECT word, phonetic, translation FROM entries
            WHERE word = ?1 COLLATE NOCASE
            UNION ALL
            SELECT entries.word, entries.phonetic, entries.translation
            FROM forms JOIN entries ON entries.word = forms.headword
            WHERE forms.form = ?1 COLLATE NOCASE
            LIMIT 1
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            sqlite3_finalize(statement)
            return nil
        }
        defer { sqlite3_finalize(statement) }

        query.withCString { pointer in
            sqlite3_bind_text(statement, 1, pointer, -1, sqliteTransient)
        }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }

        let headword = string(from: statement, column: 0) ?? query
        let phonetic = string(from: statement, column: 1)?.nilIfBlank
        let lines = (string(from: statement, column: 2) ?? "")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else { return nil }
        return ChineseHint(headword: headword, phonetic: phonetic, lines: lines)
    }

    public func suggestions(for rawPrefix: String, limit: Int = 8) -> [String] {
        guard isInstalled,
              let prefix = QueryNormalizer.normalize(rawPrefix)?.lowercased(),
              !prefix.contains(" ") else {
            return []
        }

        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else {
            sqlite3_close(database)
            return []
        }
        defer { sqlite3_close(database) }

        let sql = """
            SELECT word FROM entries
            WHERE word LIKE ?1 ESCAPE '\\' COLLATE NOCASE
            ORDER BY CASE WHEN frequency IS NULL THEN 1 ELSE 0 END, frequency, word
            LIMIT ?2
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            sqlite3_finalize(statement)
            return []
        }
        defer { sqlite3_finalize(statement) }

        let escaped = prefix
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_") + "%"
        escaped.withCString { pointer in
            sqlite3_bind_text(statement, 1, pointer, -1, sqliteTransient)
        }
        sqlite3_bind_int(statement, 2, Int32(max(1, min(limit, 20))))

        var values: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let value = string(from: statement, column: 0) {
                values.append(value)
            }
        }
        return values
    }

    private func string(from statement: OpaquePointer, column: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: pointer)
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)


public enum SpeechTextBuilder {
    public static func headword(from result: LookupResult) -> String {
        result.english?.word ?? result.query
    }

    public static func englishDefinition(from result: LookupResult) -> String? {
        result.english?.firstDefinition?.text
    }

    public static func chineseHint(from result: LookupResult) -> String? {
        result.chinese?.spokenText.nilIfBlank
    }

    public static func fullEntrySegments(from result: LookupResult) -> [(language: String, text: String)] {
        var segments: [(String, String)] = []
        let word = headword(from: result)
        if !word.isEmpty {
            segments.append(("en-US", word))
        }
        if let english = result.english {
            for meaning in english.meanings.prefix(4) {
                for definition in meaning.definitions.prefix(3) {
                    segments.append(("en-US", "\(meaning.partOfSpeech). \(definition.text)"))
                    if let example = definition.example?.nilIfBlank {
                        segments.append(("en-US", "Example. \(example)"))
                    }
                }
            }
        }
        if let chinese = chineseHint(from: result) {
            segments.append(("zh-CN", chinese))
        }
        return segments
    }
}


public actor LookupCoordinator {
    private let api: DictionaryAPIClient
    private let cache: DictionaryCache
    private let ecdict: ECDICTStore

    public init(
        api: DictionaryAPIClient = DictionaryAPIClient(),
        cache: DictionaryCache = DictionaryCache(),
        ecdict: ECDICTStore = ECDICTStore()
    ) {
        self.api = api
        self.cache = cache
        self.ecdict = ecdict
    }

    public func cachedResult(for rawQuery: String) async -> LookupResult? {
        guard let query = QueryNormalizer.normalize(rawQuery) else { return nil }
        async let english = cache.entry(for: query)
        async let chinese = ecdict.lookup(query)
        let cachedEntry = await english
        let hint = await chinese
        let result = LookupResult(query: query, english: cachedEntry, chinese: hint)
        return result.english == nil && result.chinese == nil ? nil : result
    }

    public func lookup(_ rawQuery: String) async throws -> LookupResult {
        guard let query = QueryNormalizer.normalize(rawQuery) else {
            throw DictionaryAPIError.invalidQuery
        }

        async let cachedEnglish = cache.entry(for: query)
        async let chinese = ecdict.lookup(query)
        if let cached = await cachedEnglish {
            return LookupResult(query: query, english: cached, chinese: await chinese)
        }

        async let english = api.lookup(query)
        do {
            let fresh = try await english
            try? await cache.store(fresh, for: query)
            return LookupResult(query: query, english: fresh, chinese: await chinese)
        } catch {
            let hint = await chinese
            if hint != nil {
                return LookupResult(query: query, english: nil, chinese: hint)
            }
            throw error
        }
    }

    public func suggestions(for prefix: String) async -> [String] {
        await ecdict.suggestions(for: prefix)
    }
}

@MainActor
public final class RecentQueriesStore: ObservableObject {
    @Published public private(set) var history: [String]
    @Published public private(set) var favorites: [String]

    private let defaults: UserDefaults
    private let historyKey = "history.v1"
    private let favoritesKey = "favorites.v1"
    private let maximumHistoryCount = 100

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        history = defaults.stringArray(forKey: historyKey) ?? []
        favorites = defaults.stringArray(forKey: favoritesKey) ?? []
    }

    public func record(_ rawQuery: String) {
        guard let query = QueryNormalizer.normalize(rawQuery) else { return }
        history.removeAll { $0.caseInsensitiveCompare(query) == .orderedSame }
        history.insert(query, at: 0)
        history = Array(history.prefix(maximumHistoryCount))
        defaults.set(history, forKey: historyKey)
    }

    public func toggleFavorite(_ rawQuery: String) {
        guard let query = QueryNormalizer.normalize(rawQuery) else { return }
        if let index = favorites.firstIndex(where: { $0.caseInsensitiveCompare(query) == .orderedSame }) {
            favorites.remove(at: index)
        } else {
            favorites.insert(query, at: 0)
        }
        defaults.set(favorites, forKey: favoritesKey)
    }

    public func isFavorite(_ query: String) -> Bool {
        favorites.contains { $0.caseInsensitiveCompare(query) == .orderedSame }
    }

    public func clearHistory() {
        history = []
        defaults.removeObject(forKey: historyKey)
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
