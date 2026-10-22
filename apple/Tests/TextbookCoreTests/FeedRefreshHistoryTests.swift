import Foundation
import XCTest
import CSQLite
@testable import TextbookCore

@MainActor
final class FeedRefreshHistoryTests: XCTestCase {
    func testSuccessHistorySurvivesReopenIsMonotonicAndRemovalClearsIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FeedLibraryStore(directory: directory)
        let sub = try await store.addSubscription(url: URL(string: "https://history.example/feed")!)
        let newest = Date(timeIntervalSince1970: 1_000)
        let recorded = try await store.recordSuccessfulRefreshIfSubscribed(id: sub.id, at: newest)
        XCTAssertTrue(recorded)
        try await store.recordSuccessfulRefreshIfSubscribed(id: sub.id, at: Date(timeIntervalSince1970: 500))
        let reopened = try FeedLibraryStore(directory: directory)
        let dates = try await reopened.lastSuccessfulRefreshes()
        XCTAssertEqual(dates, [sub.id: newest])
        try await reopened.removeSubscription(id: sub.id)
        let lateRecorded = try await store.recordSuccessfulRefreshIfSubscribed(id: sub.id, at: Date())
        XCTAssertFalse(lateRecorded)
        _ = try await store.addSubscription(url: sub.url)
        let cleared = try await store.lastSuccessfulRefreshes()
        XCTAssertTrue(cleared.isEmpty)
        do {
            try await store.recordSuccessfulRefreshIfSubscribed(id: sub.id, at: Date(timeIntervalSinceReferenceDate: .infinity))
            XCTFail("Nonfinite history must be rejected")
        } catch { XCTAssertEqual(error as? FeedError, .corrupted) }
    }

    func testLegacyLibraryGainsEmptyHistoryWithoutChangingArticles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FeedLibraryStore(directory: directory)
        let sub = try await store.addSubscription(url: URL(string: "https://history.example/feed")!)
        let article = FeedArticle(id: "saved", feedID: sub.id, title: "Original", url: nil, content: "Keep this body")
        try await store.saveFetchedFeed(ParsedFeed(id: sub.id, sourceURL: sub.url, title: "Feed", articles: [article]))
        try await store.setBookmarked(articleID: article.id, bookmarked: true)
        let raw = try RefreshHistoryDatabase(directory: directory)
        try raw.execute("DROP TABLE feed_refresh_success")
        let reopened = try FeedLibraryStore(directory: directory)
        let saved = try await reopened.bookmarkedArticles()
        let dates = try await reopened.lastSuccessfulRefreshes()
        XCTAssertEqual(saved, [article])
        XCTAssertTrue(dates.isEmpty)
    }

    func testUnknownHistorySchemaIsRefusedWithoutMutation() throws {
        for name in ["feed_refresh_success", "FEED_REFRESH_SUCCESS", "feed_refresh_future"] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            _ = try FeedLibraryStore(directory: directory)
            let raw = try RefreshHistoryDatabase(directory: directory)
            try raw.execute("DROP TABLE feed_refresh_success; CREATE TABLE \(name)(payload TEXT); INSERT INTO \(name) VALUES('retain');")
            let before = try raw.text("SELECT group_concat(sql) FROM sqlite_master ORDER BY name")
            XCTAssertThrowsError(try FeedLibraryStore(directory: directory))
            XCTAssertEqual(try raw.text("SELECT group_concat(sql) FROM sqlite_master ORDER BY name"), before)
            XCTAssertEqual(try raw.text("SELECT payload FROM \(name)"), "retain")
        }
    }
}

private final class RefreshHistoryDatabase {
    let db: OpaquePointer
    init(directory: URL) throws {
        var opened: OpaquePointer?
        guard sqlite3_open(directory.appendingPathComponent("feed-library.sqlite").path, &opened) == SQLITE_OK,
              let opened else { throw FeedError.unavailable }
        db = opened
    }
    deinit { sqlite3_close(db) }
    func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw FeedError.unavailable }
    }
    func text(_ sql: String) throws -> String {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw FeedError.unavailable }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else { throw FeedError.corrupted }
        return String(cString: value)
    }
}
