import Foundation
import XCTest
import CSQLite
@testable import TextbookCore

/// Independent corruption fixtures derived from SQLite's generated shadow tables.
/// https://www.sqlite.org/fts5.html
/// Contentless FTS without contentless_unindexed omits _content; contentless-delete
/// adds origin to _docsize. The pinned 3.54.1 amalgamation generates these schemas
/// in sqlite3Fts5IndexOpen() and sqlite3Fts5StorageOpen().
@MainActor
final class SearchShadowIndependentRegressionTests: XCTestCase {
    func testUnexpectedContentShadowIsRefusedWithoutMutation() async throws {
        let fixture = try await seedFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let raw = try ShadowRegressionDatabase(url: fixture.databaseURL)
        XCTAssertFalse(try raw.tableNames().contains("article_search_fts_content"))
        try raw.execute("""
            CREATE TABLE article_search_fts_content(unexpected TEXT NOT NULL);
            INSERT INTO article_search_fts_content VALUES('preserve this unexpected table');
            """)

        try assertRefusedWithoutMutation(fixture, raw: raw)
    }

    func testDocsizeExtraColumnIsRefusedWithoutMutation() async throws {
        let fixture = try await seedFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let raw = try ShadowRegressionDatabase(url: fixture.databaseURL)
        XCTAssertEqual(
            try raw.strings("SELECT name FROM pragma_table_info('article_search_fts_docsize') ORDER BY cid"),
            ["id", "sz", "origin"]
        )
        try raw.execute("""
            ALTER TABLE article_search_fts_docsize ADD COLUMN unexpected TEXT;
            UPDATE article_search_fts_docsize SET unexpected='preserve this extra column';
            """)

        try assertRefusedWithoutMutation(fixture, raw: raw)
    }

    func testConfigChangedDefinitionWithSameColumnsIsRefusedWithoutMutation() async throws {
        let fixture = try await seedFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let raw = try ShadowRegressionDatabase(url: fixture.databaseURL)
        try replaceConfigDefinition(raw)
        // A column-name-only check cannot distinguish this from the real table.
        XCTAssertEqual(
            try raw.strings("SELECT name FROM pragma_table_info('article_search_fts_config') ORDER BY cid"),
            ["k", "v"]
        )

        try assertRefusedWithoutMutation(fixture, raw: raw)
    }

    func testMalformedV1ShadowIsRefusedBeforeV2Migration() async throws {
        let fixture = try await seedFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let raw = try ShadowRegressionDatabase(url: fixture.databaseURL)
        try downgradeSearchMetadataToV1(raw)
        try raw.execute("ALTER TABLE article_search_fts_docsize ADD COLUMN unexpected TEXT")

        try assertRefusedWithoutMutation(fixture, raw: raw)
        XCTAssertEqual(try raw.rows("SELECT schema_version FROM article_search_metadata"), [["integer:1"]])
        XCTAssertTrue(try raw.strings("SELECT name FROM sqlite_schema WHERE name='article_search_documents_order'").isEmpty)
    }

    func testGeneratedV2ShadowSchemaRemainsUsableOnReopen() async throws {
        let fixture = try await seedFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let raw = try ShadowRegressionDatabase(url: fixture.databaseURL)
        let shadowNames = try raw.tableNames().filter { $0.hasPrefix("article_search_fts_") }
        XCTAssertEqual(Set(shadowNames), Set([
            "article_search_fts_data", "article_search_fts_idx",
            "article_search_fts_docsize", "article_search_fts_config",
        ]))
        let before = try raw.snapshot()

        let reopened = try FeedLibraryStore(directory: fixture.directory)
        try await assertSavedValuesAreSearchable(fixture, store: reopened)

        XCTAssertEqual(try raw.snapshot(), before, "A valid current schema must not require a rebuild")
    }

    func testValidV1MigrationRetainsGeneratedShadowsAndSavedValues() async throws {
        let fixture = try await seedFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let raw = try ShadowRegressionDatabase(url: fixture.databaseURL)
        try downgradeSearchMetadataToV1(raw)
        let before = try raw.snapshot()

        let migrated = try FeedLibraryStore(directory: fixture.directory)
        try await assertSavedValuesAreSearchable(fixture, store: migrated)

        let after = try raw.snapshot()
        XCTAssertEqual(try raw.rows("SELECT schema_version FROM article_search_metadata"), [["integer:2"]])
        XCTAssertEqual(
            try raw.strings("SELECT name FROM sqlite_schema WHERE name='article_search_documents_order'"),
            ["article_search_documents_order"]
        )
        for name in before.tables.keys where name != "article_search_metadata" {
            XCTAssertEqual(after.tables[name], before.tables[name], "Migration changed stored values in \(name)")
        }
        let shadowNames = Set([
            "article_search_fts_data", "article_search_fts_idx",
            "article_search_fts_docsize", "article_search_fts_config",
        ].map(ShadowRegressionDatabase.encodedText))
        let shadowsBefore = before.schema.filter { $0.count > 1 && shadowNames.contains($0[1]) }
        for definition in shadowsBefore {
            XCTAssertTrue(after.schema.contains(definition), "Migration replaced a generated shadow definition")
        }
    }

    private func assertRefusedWithoutMutation(
        _ fixture: ShadowRegressionFixture,
        raw: ShadowRegressionDatabase,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(try raw.rows("SELECT id,title,content FROM articles").count, 1, file: file, line: line)
        XCTAssertEqual(try raw.rows("SELECT article_id,title,body FROM translations").count, 1, file: file, line: line)
        let before = try raw.snapshot()

        XCTAssertThrowsError(try FeedLibraryStore(directory: fixture.directory), file: file, line: line) { error in
            XCTAssertEqual(error as? FeedError, .corrupted, file: file, line: line)
        }

        XCTAssertEqual(
            try raw.snapshot(), before,
            "Reject unfamiliar shadow definitions without migration, rebuild, or user-data changes",
            file: file, line: line
        )
    }

    private func assertSavedValuesAreSearchable(
        _ fixture: ShadowRegressionFixture,
        store: FeedLibraryStore
    ) async throws {
        for query in ["ShadowSourceWitness", "保持する日本語"] {
            let page = try await store.searchArticles(ArticleSearchRequest(text: query))
            XCTAssertEqual(page.results.map(\.article), [fixture.article], query)
            XCTAssertEqual(page.results.first?.translation, fixture.translation, query)
            XCTAssertEqual(page.results.first?.isBookmarked, true, query)
        }
    }

    private func downgradeSearchMetadataToV1(_ raw: ShadowRegressionDatabase) throws {
        try raw.execute("""
            BEGIN IMMEDIATE;
            DROP INDEX article_search_documents_order;
            UPDATE article_search_metadata SET schema_version=1 WHERE singleton=1;
            COMMIT;
            """)
    }

    private func replaceConfigDefinition(_ raw: ShadowRegressionDatabase) throws {
        try raw.execute("""
            BEGIN IMMEDIATE;
            CREATE TEMP TABLE independent_config_backup AS SELECT k,v FROM article_search_fts_config;
            DROP TABLE article_search_fts_config;
            CREATE TABLE article_search_fts_config(k PRIMARY KEY,v CHECK(1)) WITHOUT ROWID;
            INSERT INTO article_search_fts_config(k,v) SELECT k,v FROM independent_config_backup;
            DROP TABLE independent_config_backup;
            COMMIT;
            """)
    }

    private func seedFixture() async throws -> ShadowRegressionFixture {
        XCTAssertEqual(String(cString: sqlite3_libversion()), "3.54.1")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("independent-search-shadow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        do {
            let subscription = try FeedSubscription(url: URL(string: "https://shadow-regression.example/feed")!)
            let article = FeedArticle(
                id: "shadow-independent-article", feedID: subscription.id,
                title: "Original shadow fixture", url: URL(string: "https://shadow-regression.example/article"),
                summary: "Saved summary", content: "ShadowSourceWitness: preserve this original body."
            )
            let translation = ArticleTranslation(
                articleID: article.id, sourceFingerprint: article.sourceFingerprint,
                targetLanguage: "ja", title: "保持する日本語の表題", body: "保持する日本語の本文です。"
            )
            let store = try FeedLibraryStore(directory: directory)
            try await store.saveFetchedFeed(ParsedFeed(
                id: subscription.id, sourceURL: subscription.url, title: "Shadow fixture", articles: [article]
            ))
            try await store.saveTranslation(translation)
            _ = try await store.setBookmarked(articleID: article.id, bookmarked: true)
            return ShadowRegressionFixture(directory: directory, article: article, translation: translation)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}

private struct ShadowRegressionFixture {
    let directory: URL
    let article: FeedArticle
    let translation: ArticleTranslation
    var databaseURL: URL { directory.appendingPathComponent("feed-library.sqlite") }
}

private struct ShadowRegressionSnapshot: Equatable {
    let schema: [[String]]
    let tables: [String: [[String]]]
    let userVersion: [[String]]
    let journalMode: [[String]]
}

private final class ShadowRegressionDatabase {
    private let db: OpaquePointer

    init(url: URL) throws {
        var opened: OpaquePointer?
        let status = sqlite3_open_v2(url.path, &opened, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard status == SQLITE_OK, let opened else {
            if let opened { sqlite3_close_v2(opened) }
            throw FeedError.unavailable
        }
        db = opened
    }

    deinit { sqlite3_close_v2(db) }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }

    func tableNames() throws -> [String] {
        try strings("""
            SELECT name FROM sqlite_schema
            WHERE type='table' AND sql NOT LIKE 'CREATE VIRTUAL TABLE%'
            ORDER BY name
            """)
    }

    func snapshot() throws -> ShadowRegressionSnapshot {
        var tables: [String: [[String]]] = [:]
        for name in try tableNames() {
            let escaped = name.replacingOccurrences(of: "\"", with: "\"\"")
            tables[name] = try rows("SELECT * FROM \"\(escaped)\"").sorted { $0.lexicographicallyPrecedes($1) }
        }
        return ShadowRegressionSnapshot(
            schema: try rows("SELECT type,name,tbl_name,rootpage,sql FROM sqlite_schema ORDER BY type,name"),
            tables: tables, userVersion: try rows("PRAGMA user_version"), journalMode: try rows("PRAGMA journal_mode")
        )
    }

    func strings(_ sql: String) throws -> [String] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        var result: [String] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard sqlite3_column_type(statement, 0) == SQLITE_TEXT,
                      let bytes = sqlite3_column_text(statement, 0) else { throw failure() }
                result.append(String(cString: bytes))
            case SQLITE_DONE: return result
            default: throw failure()
            }
        }
    }

    func rows(_ sql: String) throws -> [[String]] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        var result: [[String]] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                var row: [String] = []
                for column in 0..<sqlite3_column_count(statement) {
                    switch sqlite3_column_type(statement, column) {
                    case SQLITE_INTEGER: row.append("integer:\(sqlite3_column_int64(statement, column))")
                    case SQLITE_FLOAT: row.append("real:\(sqlite3_column_double(statement, column).bitPattern)")
                    case SQLITE_TEXT:
                        let count = Int(sqlite3_column_bytes(statement, column))
                        guard let bytes = sqlite3_column_text(statement, column) else { throw failure() }
                        row.append("text:" + Data(bytes: bytes, count: count).base64EncodedString())
                    case SQLITE_BLOB:
                        let count = Int(sqlite3_column_bytes(statement, column))
                        if count == 0 { row.append("blob:") }
                        else {
                            guard let bytes = sqlite3_column_blob(statement, column) else { throw failure() }
                            row.append("blob:" + Data(bytes: bytes, count: count).base64EncodedString())
                        }
                    case SQLITE_NULL: row.append("null")
                    default: throw failure()
                    }
                }
                result.append(row)
            case SQLITE_DONE: return result
            default: throw failure()
            }
        }
    }

    static func encodedText(_ value: String) -> String {
        "text:" + Data(value.utf8).base64EncodedString()
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        return statement
    }

    private func failure() -> NSError {
        NSError(domain: "IndependentShadowSQLite", code: Int(sqlite3_errcode(db)), userInfo: [
            NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db)),
        ])
    }
}
