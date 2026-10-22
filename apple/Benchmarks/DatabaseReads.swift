import CSQLite
import Darwin
import Foundation
import TextbookCore

/// Exercises the production actor APIs, including result decoding and actor scheduling.
/// Fixture creation and connection opening are deliberately outside the query budget.
@main
struct DatabaseReadBenchmark {
    struct Metric: Codable {
        let operation: String
        let resultCount: Int
        let samplesMilliseconds: [Double]
        var maximumMilliseconds: Double { samplesMilliseconds.max() ?? 0 }
        var firstMilliseconds: Double { samplesMilliseconds.first ?? 0 }
        var p50Milliseconds: Double { percentile(0.5) }
        var p95Milliseconds: Double { percentile(0.95) }
        var p99Milliseconds: Double { percentile(0.99) }

        private func percentile(_ quantile: Double) -> Double {
            let sorted = samplesMilliseconds.sorted()
            return sorted[max(0, Int(ceil(Double(sorted.count) * quantile)) - 1)]
        }
    }

    struct Report: Encodable {
        struct Summary: Encodable {
            let operation: String
            let resultCount: Int
            let firstMilliseconds: Double
            let p50Milliseconds: Double
            let p95Milliseconds: Double
            let p99Milliseconds: Double
            let maximumMilliseconds: Double
            let samplesMilliseconds: [Double]
        }
        let budgetMilliseconds = 100.0
        let articleCount = 100_000
        let bookmarkCount = 10_000
        let subscriptionCount = 100
        let iterations = 30
        let maximumRowsPerList = 2_000
        let operatingSystem = ProcessInfo.processInfo.operatingSystemVersionString
        let sqliteVersion = String(cString: sqlite3_libversion())
        let measurementScope = "Release production actor reads, including scheduling and Swift result decoding; first and repeated accesses. Excludes DB open/quick_check, fixture import, network, translation execution and UI rendering. OS page cache is not flushed. No concurrent writes in this baseline."
        let passed: Bool
        let metrics: [Summary]
    }

    struct Failure: Error { let message: String }

    static func main() async {
        do {
            try await run()
        } catch {
            FileHandle.standardError.write(Data("Database benchmark failed: \(error)\n".utf8))
            exit(1)
        }
    }

    static func run() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tsumiki-db-benchmark-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FeedLibraryStore(directory: directory)
        var feedIDs: [String] = []
        for number in 0..<100 {
            let subscription = try await store.addSubscription(
                url: URL(string: "https://feed-\(number).example.com/rss")!, title: "Feed \(number)"
            )
            feedIDs.append(subscription.id)
        }
        let content = String(repeating: "日本語の本文。Rust / Swift / Go and agent engineering.\n", count: 30)
        let summary = String(repeating: "日本語の要約。", count: 12)
        try seed(directory: directory, feedIDs: feedIDs, content: content, summary: summary)
        let article = FeedArticle(
            id: "article-000001", feedID: feedIDs[1], title: "記事 1",
            url: URL(string: "https://example.com/articles/1"), summary: summary, content: content
        )
        try await store.saveTranslation(ArticleTranslation(
            articleID: article.id, sourceFingerprint: article.sourceFingerprint,
            targetLanguage: "ja", title: "訳文", body: "保存済みの日本語訳。"
        ))

        var metrics: [Metric] = []
        metrics.append(try await measure("articles.latest.2000", count: 2_000) {
            try await store.articles(limit: 2_000).count
        })
        metrics.append(try await measure("articles.feed.1000", count: 1_000) {
            try await store.articles(feedID: feedIDs[1], limit: 2_000).count
        })
        metrics.append(try await measure("bookmarks.oldest.2000", count: 2_000) {
            try await store.bookmarkedArticles(limit: 2_000).count
        })
        metrics.append(try await measure("subscriptions.100", count: 100) {
            try await store.subscriptions().count
        })
        metrics.append(try await measure("bookmark.lookup", count: 1) {
            try await store.isBookmarked(articleID: article.id) ? 1 : 0
        })
        metrics.append(try await measure("translation.lookup", count: 1) {
            try await store.translation(articleID: article.id, targetLanguage: "ja") == nil ? 0 : 1
        })
        metrics.append(try await measure("reader.threeQueries", count: 4_100) {
            async let subscriptions = store.subscriptions()
            async let articles = store.articles(limit: 2_000)
            async let bookmarks = store.bookmarkedArticles(limit: 2_000)
            let values = try await (subscriptions, articles, bookmarks)
            return values.0.count + values.1.count + values.2.count
        })
        let passed = metrics.allSatisfy { $0.maximumMilliseconds < 100 }
        let report = Report(passed: passed, metrics: metrics.map {
            Report.Summary(
                operation: $0.operation, resultCount: $0.resultCount,
                firstMilliseconds: $0.firstMilliseconds, p50Milliseconds: $0.p50Milliseconds,
                p95Milliseconds: $0.p95Milliseconds, p99Milliseconds: $0.p99Milliseconds,
                maximumMilliseconds: $0.maximumMilliseconds, samplesMilliseconds: $0.samplesMilliseconds
            )
        })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        if CommandLine.arguments.count == 2 {
            try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
        }
        FileHandle.standardOutput.write(data + Data("\n".utf8))
        if !passed { exit(1) }
    }

    static func measure(_ name: String, count: Int, operation: () async throws -> Int) async throws -> Metric {
        let clock = ContinuousClock()
        var samples: [Double] = []
        for _ in 0..<30 {
            let start = clock.now
            let result = try await operation()
            let elapsed = start.duration(to: clock.now).components
            let milliseconds = Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
            guard result == count else { throw Failure(message: "\(name): expected \(count) rows, got \(result)") }
            samples.append(milliseconds)
        }
        return Metric(operation: name, resultCount: count, samplesMilliseconds: samples)
    }

    static func seed(directory: URL, feedIDs: [String], content: String, summary: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(directory.appendingPathComponent("feed-library.sqlite").path, &db) == SQLITE_OK,
              let db else { throw Failure(message: "fixture open") }
        defer { sqlite3_close(db) }
        try execute(db, "BEGIN IMMEDIATE; CREATE TEMP TABLE benchmark_feeds(number INTEGER PRIMARY KEY, id TEXT NOT NULL)")
        do {
            for (number, id) in feedIDs.enumerated() {
                let statement = try prepare(db, "INSERT INTO benchmark_feeds VALUES(?,?)")
                defer { sqlite3_finalize(statement) }
                guard sqlite3_bind_int(statement, 1, Int32(number)) == SQLITE_OK else { throw Failure(message: "fixture bind") }
                try bind(id, to: 2, in: statement)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw Failure(message: "fixture feed") }
            }
            let statement = try prepare(db, """
                WITH RECURSIVE sequence(n) AS (SELECT 0 UNION ALL SELECT n+1 FROM sequence WHERE n<99999)
                INSERT INTO articles(id,feed_id,remote_id,title,url,summary,content,published)
                SELECT printf('article-%06d',n),f.id,'entry-'||n,'記事 '||n,
                       'https://example.com/articles/'||n,?, ?,
                       CASE WHEN n%97=0 THEN NULL ELSE CAST(n/3 AS REAL) END
                FROM sequence JOIN benchmark_feeds f ON f.number=n%100
                """)
            defer { sqlite3_finalize(statement) }
            try bind(summary, to: 1, in: statement)
            try bind(content, to: 2, in: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw Failure(message: "fixture articles: \(String(cString: sqlite3_errmsg(db)))") }
            try execute(db, "INSERT INTO bookmarks SELECT id FROM articles WHERE id<'article-010000'; COMMIT")
        } catch {
            try? execute(db, "ROLLBACK")
            throw error
        }
    }

    static func prepare(_ db: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Failure(message: "fixture prepare")
        }
        return statement
    }

    static func execute(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw Failure(message: "fixture execute") }
    }

    static func bind(_ value: String, to index: Int32, in statement: OpaquePointer) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard value.withCString({ sqlite3_bind_text(statement, index, $0, -1, transient) }) == SQLITE_OK else {
            throw Failure(message: "fixture bind")
        }
    }
}
