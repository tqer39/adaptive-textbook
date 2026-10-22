import Foundation
import XCTest
import CSQLite
@testable import TextbookCore

@MainActor
final class FeedLibraryQueryTests: XCTestCase {
    func testGlobalFilteredAndBookmarkedReadsKeepDateAndIDOrdering() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try FeedSubscription(url: URL(string: "https://first.example/feed")!)
        let second = try FeedSubscription(url: URL(string: "https://second.example/feed")!)
        let tie = Date(timeIntervalSinceReferenceDate: 100)
        let older = Date(timeIntervalSinceReferenceDate: 50)
        let articles = [
            FeedArticle(id: "b-tie", feedID: second.id, remoteID: "remote-b", title: "B", url: URL(string: "https://second.example/b"), summary: "要約B", content: "本文B", publishedAt: tie),
            FeedArticle(id: "n-b", feedID: second.id, title: "Null B", url: nil, summary: "要約NB", content: "本文NB"),
            FeedArticle(id: "n-a", feedID: first.id, title: "Null A", url: nil, summary: "要約NA", content: "本文NA"),
            FeedArticle(id: "c-old", feedID: first.id, title: "Old", url: URL(string: "https://first.example/old"), summary: "要約C", content: "本文C", publishedAt: older),
            FeedArticle(id: "a-tie", feedID: first.id, remoteID: "remote-a", title: "A", url: URL(string: "https://first.example/a"), summary: "要約A", content: "本文A", publishedAt: tie),
        ]
        let store = try FeedLibraryStore(directory: directory)
        try await store.saveFetchedFeed(ParsedFeed(id: first.id, sourceURL: first.url, title: "First", articles: articles.filter { $0.feedID == first.id }))
        try await store.saveFetchedFeed(ParsedFeed(id: second.id, sourceURL: second.url, title: "Second", articles: articles.filter { $0.feedID == second.id }))
        try await store.setBookmarked(articleID: "n-a", bookmarked: true)
        try await store.setBookmarked(articleID: "b-tie", bookmarked: true)
        try await store.setBookmarked(articleID: "a-tie", bookmarked: true)

        let global = try await store.articles()
        let filtered = try await store.articles(feedID: first.id)
        let bookmarked = try await store.bookmarkedArticles()
        XCTAssertEqual(global.map(\.id), ["a-tie", "b-tie", "c-old", "n-a", "n-b"])
        XCTAssertEqual(filtered.map(\.id), ["a-tie", "c-old", "n-a"])
        XCTAssertEqual(bookmarked.map(\.id), ["a-tie", "b-tie", "n-a"])
        XCTAssertEqual(filtered.first, articles.first { $0.id == "a-tie" })
    }

    func testArticleReadLimitsRemainBoundedFromZeroThroughMaximum() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let subscription = try FeedSubscription(url: URL(string: "https://bounds.example/feed")!)
        let articles = (0 ... 2_000).map { index in
            FeedArticle(
                id: String(format: "article-%04d", index), feedID: subscription.id,
                title: "Title \(index)", url: URL(string: "https://bounds.example/\(index)"),
                summary: "要約 \(index)", content: "本文 \(index)",
                publishedAt: Date(timeIntervalSinceReferenceDate: TimeInterval(index))
            )
        }
        let store = try FeedLibraryStore(directory: directory)
        try await store.saveFetchedFeed(ParsedFeed(id: subscription.id, sourceURL: subscription.url, title: "Bounds", articles: articles))

        let zero = try await store.articles(limit: 0)
        let negative = try await store.articles(limit: -1)
        XCTAssertTrue(zero.isEmpty)
        XCTAssertTrue(negative.isEmpty)
        let bounded = try await store.articles(limit: 20_000)
        XCTAssertEqual(bounded.count, 2_000)
        XCTAssertEqual(bounded.first?.id, "article-2000")
        XCTAssertEqual(bounded.last?.id, "article-0001")
        XCTAssertEqual(bounded.last?.content, "本文 1")
    }

    func testReopeningSchemaV1AddsReadIndexesWithoutChangingStoredData() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = directory.appendingPathComponent("feed-library.sqlite")
        let subscription = try FeedSubscription(url: URL(string: "https://legacy.example/feed")!)
        let article = FeedArticle(
            id: "legacy-article", feedID: subscription.id, remoteID: "legacy-remote", title: "Legacy",
            url: URL(string: "https://legacy.example/article"), summary: "元の要約", content: "元の本文",
            publishedAt: Date(timeIntervalSinceReferenceDate: 123)
        )
        let translation = ArticleTranslation(
            articleID: article.id, sourceFingerprint: article.sourceFingerprint,
            targetLanguage: "ja", title: "保存済み翻訳", body: "保存済み本文"
        )
        do {
            let legacy = try QueryTestDatabase(url: database)
            try legacy.execute("CREATE TABLE subscriptions(id TEXT PRIMARY KEY,url TEXT NOT NULL UNIQUE,title TEXT,etag TEXT,last_modified TEXT);CREATE TABLE articles(id TEXT PRIMARY KEY,feed_id TEXT NOT NULL,remote_id TEXT,title TEXT NOT NULL,url TEXT,summary TEXT NOT NULL,content TEXT NOT NULL,published REAL);CREATE TABLE bookmarks(article_id TEXT PRIMARY KEY REFERENCES articles(id));CREATE TABLE translations(article_id TEXT NOT NULL REFERENCES articles(id),source_fingerprint TEXT NOT NULL,target_language TEXT NOT NULL,title TEXT NOT NULL,body TEXT NOT NULL,PRIMARY KEY(article_id,target_language));PRAGMA user_version=1;")
            try legacy.execute("INSERT INTO subscriptions(id,url,title) VALUES(?,?,?)", values: [subscription.id, subscription.url.absoluteString, "Legacy Feed"])
            try legacy.execute("INSERT INTO articles(id,feed_id,remote_id,title,url,summary,content,published) VALUES(?,?,?,?,?,?,?,123)", values: [article.id, article.feedID, article.remoteID, article.title, article.url?.absoluteString, article.summary, article.content])
            try legacy.execute("INSERT INTO bookmarks(article_id) VALUES(?)", values: [article.id])
            try legacy.execute("INSERT INTO translations(article_id,source_fingerprint,target_language,title,body) VALUES(?,?,?,?,?)", values: [translation.articleID, translation.sourceFingerprint, translation.targetLanguage, translation.title, translation.body])
        }

        let reopened = try FeedLibraryStore(url: database)
        let reopenedArticles = try await reopened.articles()
        let reopenedBookmarks = try await reopened.bookmarkedArticles()
        let reopenedTranslation = try await reopened.translation(articleID: article.id, targetLanguage: "ja")
        XCTAssertEqual(reopenedArticles, [article])
        XCTAssertEqual(reopenedBookmarks, [article])
        XCTAssertEqual(reopenedTranslation, translation)
        let inspected = try QueryTestDatabase(url: database)
        XCTAssertEqual(try inspected.scalarInteger("SELECT count(*) FROM sqlite_master WHERE type='index' AND name IN ('articles_published_id','articles_feed_published_id')"), 2)
        XCTAssertEqual(try inspected.scalarInteger("PRAGMA user_version"), 1)
    }

    func testOpeningFullyIndexedStoreDoesNotRequireWriterLock() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("feed-library.sqlite")
        let subscription = try FeedSubscription(url: URL(string: "https://locked.example/feed")!)
        let article = FeedArticle(
            id: "locked-article", feedID: subscription.id, remoteID: "locked-remote", title: "Locked",
            url: URL(string: "https://locked.example/article"), summary: "元の要約", content: "元の本文",
            publishedAt: Date(timeIntervalSinceReferenceDate: 456)
        )
        let translation = ArticleTranslation(
            articleID: article.id, sourceFingerprint: article.sourceFingerprint,
            targetLanguage: "ja", title: "保存済み翻訳", body: "保存済み本文"
        )
        let populated = try FeedLibraryStore(url: database)
        try await populated.saveFetchedFeed(ParsedFeed(
            id: subscription.id, sourceURL: subscription.url, title: "Locked Feed", articles: [article]
        ))
        try await populated.setBookmarked(articleID: article.id, bookmarked: true)
        try await populated.saveTranslation(translation)

        let writer = try QueryTestDatabase(url: database)
        try writer.execute("BEGIN IMMEDIATE")
        defer { try? writer.execute("ROLLBACK") }

        let reopened = try FeedLibraryStore(url: database)
        let reopenedArticles = try await reopened.articles()
        let reopenedBookmarks = try await reopened.bookmarkedArticles()
        let reopenedTranslation = try await reopened.translation(articleID: article.id, targetLanguage: "ja")
        XCTAssertEqual(reopenedArticles, [article])
        XCTAssertEqual(reopenedBookmarks, [article])
        XCTAssertEqual(reopenedTranslation, translation)
    }

    func testReopeningDoesNotAcceptWrongDefinitionsWithRequiredIndexNames() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("feed-library.sqlite")
        let subscription = try FeedSubscription(url: URL(string: "https://wrong-index.example/feed")!)
        let article = FeedArticle(
            id: "wrong-index-article", feedID: subscription.id, title: "Wrong index",
            url: URL(string: "https://wrong-index.example/article"), summary: "元の要約", content: "元の本文",
            publishedAt: Date(timeIntervalSinceReferenceDate: 789)
        )
        let translation = ArticleTranslation(
            articleID: article.id, sourceFingerprint: article.sourceFingerprint,
            targetLanguage: "ja", title: "保存済み翻訳", body: "保存済み本文"
        )
        let populated = try FeedLibraryStore(url: database)
        try await populated.saveFetchedFeed(ParsedFeed(
            id: subscription.id, sourceURL: subscription.url, title: "Wrong Index Feed", articles: [article]
        ))
        try await populated.setBookmarked(articleID: article.id, bookmarked: true)
        try await populated.saveTranslation(translation)

        let malformed = try QueryTestDatabase(url: database)
        try malformed.execute("DROP INDEX articles_published_id;DROP INDEX articles_feed_published_id;CREATE INDEX articles_published_id ON subscriptions(id);CREATE INDEX articles_feed_published_id ON articles(feed_id,published ASC,id ASC) WHERE published IS NOT NULL;")

        let reopened = try FeedLibraryStore(url: database)
        let reopenedArticles = try await reopened.articles()
        let reopenedBookmarks = try await reopened.bookmarkedArticles()
        let reopenedTranslation = try await reopened.translation(articleID: article.id, targetLanguage: "ja")
        XCTAssertEqual(reopenedArticles, [article])
        XCTAssertEqual(reopenedBookmarks, [article])
        XCTAssertEqual(reopenedTranslation, translation)

        let inspected = try QueryTestDatabase(url: database)
        XCTAssertEqual(try inspected.scalarInteger("SELECT count(*) FROM pragma_index_list('articles') il WHERE il.\"unique\"=0 AND il.partial=0 AND (SELECT group_concat(name||':'||\"desc\"||':'||upper(coll),',') FROM pragma_index_xinfo(il.name) WHERE key=1)='published:1:BINARY,id:0:BINARY'"), 1)
        XCTAssertEqual(try inspected.scalarInteger("SELECT count(*) FROM pragma_index_list('articles') il WHERE il.\"unique\"=0 AND il.partial=0 AND (SELECT group_concat(name||':'||\"desc\"||':'||upper(coll),',') FROM pragma_index_xinfo(il.name) WHERE key=1)='feed_id:0:BINARY,published:1:BINARY,id:0:BINARY'"), 1)
    }

    func testReopeningAvoidsUppercaseSchemaNameCollisionsAndThenNeedsNoWriterLock() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("feed-library.sqlite")
        let subscription = try FeedSubscription(url: URL(string: "https://uppercase-index.example/feed")!)
        let article = FeedArticle(
            id: "uppercase-index-article", feedID: subscription.id, remoteID: "uppercase-remote",
            title: "Uppercase index", url: URL(string: "https://uppercase-index.example/article"),
            summary: "元の要約", content: "元の本文", publishedAt: Date(timeIntervalSinceReferenceDate: 987)
        )
        let translation = ArticleTranslation(
            articleID: article.id, sourceFingerprint: article.sourceFingerprint,
            targetLanguage: "ja", title: "保存済み翻訳", body: "保存済み本文"
        )
        let populated = try FeedLibraryStore(url: database)
        try await populated.saveFetchedFeed(ParsedFeed(
            id: subscription.id, sourceURL: subscription.url, title: "Uppercase Index Feed", articles: [article]
        ))
        try await populated.setBookmarked(articleID: article.id, bookmarked: true)
        try await populated.saveTranslation(translation)

        let malformed = try QueryTestDatabase(url: database)
        try malformed.execute("DROP INDEX articles_published_id;DROP INDEX articles_feed_published_id;CREATE INDEX ARTICLES_PUBLISHED_ID ON subscriptions(id);CREATE INDEX ARTICLES_FEED_PUBLISHED_ID ON articles(feed_id,published ASC,id ASC) WHERE published IS NOT NULL;CREATE TABLE ARTICLES_PUBLISHED_ID_QUERY_V1_1(marker TEXT);CREATE VIEW ARTICLES_FEED_PUBLISHED_ID_QUERY_V1_1 AS SELECT id FROM subscriptions;")

        let repaired = try FeedLibraryStore(url: database)
        let repairedArticles = try await repaired.articles()
        let repairedBookmarks = try await repaired.bookmarkedArticles()
        let repairedTranslation = try await repaired.translation(articleID: article.id, targetLanguage: "ja")
        XCTAssertEqual(repairedArticles, [article])
        XCTAssertEqual(repairedBookmarks, [article])
        XCTAssertEqual(repairedTranslation, translation)

        let inspected = try QueryTestDatabase(url: database)
        let wrongIndexesPreserved = try inspected.scalarInteger("SELECT count(*) FROM sqlite_master WHERE type='index' AND name IN ('ARTICLES_PUBLISHED_ID','ARTICLES_FEED_PUBLISHED_ID')")
        let occupiedSuffixesPreserved = try inspected.scalarInteger("SELECT count(*) FROM sqlite_master WHERE (type='table' AND name='ARTICLES_PUBLISHED_ID_QUERY_V1_1') OR (type='view' AND name='ARTICLES_FEED_PUBLISHED_ID_QUERY_V1_1')")
        let requiredIndexes = try inspected.scalarInteger("SELECT count(*) FROM pragma_index_list('articles') il WHERE il.\"unique\"=0 AND il.partial=0 AND (SELECT group_concat(name||':'||\"desc\"||':'||upper(coll),',') FROM pragma_index_xinfo(il.name) WHERE key=1) IN ('published:1:BINARY,id:0:BINARY','feed_id:0:BINARY,published:1:BINARY,id:0:BINARY')")
        let generatedSuffixes = try inspected.scalarInteger("SELECT count(*) FROM sqlite_master WHERE type='index' AND name IN ('articles_published_id_query_v1_2','articles_feed_published_id_query_v1_2')")
        XCTAssertEqual(wrongIndexesPreserved, 2)
        XCTAssertEqual(occupiedSuffixesPreserved, 2)
        XCTAssertEqual(requiredIndexes, 2)
        XCTAssertEqual(generatedSuffixes, 2)

        let writer = try QueryTestDatabase(url: database)
        try writer.execute("BEGIN IMMEDIATE")
        defer { try? writer.execute("ROLLBACK") }

        let reopened = try FeedLibraryStore(url: database)
        let reopenedArticles = try await reopened.articles()
        let reopenedBookmarks = try await reopened.bookmarkedArticles()
        let reopenedTranslation = try await reopened.translation(articleID: article.id, targetLanguage: "ja")
        XCTAssertEqual(reopenedArticles, [article])
        XCTAssertEqual(reopenedBookmarks, [article])
        XCTAssertEqual(reopenedTranslation, translation)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}

private final class QueryTestDatabase {
    private let db: OpaquePointer

    init(url: URL) throws {
        var opened: OpaquePointer?
        guard sqlite3_open(url.path, &opened) == SQLITE_OK, let opened else {
            if let opened { sqlite3_close(opened) }
            throw FeedError.unavailable
        }
        db = opened
    }

    deinit { sqlite3_close(db) }

    func execute(_ sql: String, values: [String?] = []) throws {
        if values.isEmpty {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw FeedError.unavailable }
            return
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw FeedError.unavailable }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let result: Int32
            if let value {
                result = value.withCString { sqlite3_bind_text(statement, Int32(offset + 1), $0, -1, transient) }
            } else {
                result = sqlite3_bind_null(statement, Int32(offset + 1))
            }
            guard result == SQLITE_OK else { throw FeedError.unavailable }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw FeedError.unavailable }
    }

    func scalarInteger(_ sql: String) throws -> Int64 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw FeedError.unavailable }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_type(statement, 0) == SQLITE_INTEGER else { throw FeedError.corrupted }
        return sqlite3_column_int64(statement, 0)
    }
}
