import CSQLite
import CryptoKit
import Darwin
import Foundation
@_spi(Testing) import TextbookCore

/// Release-only, local synthetic-data acceptance gate. No personal DB or network is used.
/// Setup/backfill are reported separately; every measured public call includes actor waiting
/// and complete Swift article/translation materialization. No warmups or discarded samples.
@main
struct FullTextSearchBenchmark {
    static let iterations = 30
    static let budgetMilliseconds = 100.0
    static let articleCount = 100_000
    static let writerIndex = articleCount - 1

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    struct Sample: Encodable {
        let startedNanoseconds: UInt64
        let finishedNanoseconds: UInt64
        let milliseconds: Double
        let resultIDs: [String]
        let cursors: [Int64]
        let originalBytes: Int
        let translationBytes: Int
        let writerCommitsBefore: Int
        let writerCommitsAfter: Int
        let heldGate: Int?
        let failure: String?
        var processCPUMilliseconds: Double? = nil
    }

    struct PaginationSample: Encodable {
        let phase: String
        let query: String
        let text: String
        let feedID: String?
        let bookmarksOnly: Bool
        let limit: Int
        let before: Int64?
        let nextCursor: Int64?
        let sample: Sample
    }

    struct Metric: Encodable {
        let condition: String
        let query: String
        let text: String
        let feedID: String?
        let bookmarksOnly: Bool
        let limit: Int
        let expectedMatches: Int
        let before: Int64?
        var samples: [Sample] = []
        var maximumMilliseconds = 0.0
        var firstMilliseconds = 0.0
        var passed = false
    }

    struct WriteEvent: Encodable, Sendable {
        let action: String
        let revision: Int
        let startedNanoseconds: UInt64
        let finishedNanoseconds: UInt64
        let sourceFingerprint: String
        let succeeded: Bool
    }

    struct HeldEvent: Encodable {
        let gate: Int
        let query: String
        let revision: Int
        let dirtyNanoseconds: UInt64
        let releasedNanoseconds: UInt64
        let committedNanoseconds: UInt64
        let watchdogExpired: Bool
        let oldMarker: String
        let newMarker: String
        let oldVisibleWhileHeld: Bool
        let newInvisibleWhileHeld: Bool
        let newVisibleAfterCommit: Bool
        let oldInvisibleAfterCommit: Bool
    }

    struct Check: Encodable {
        let name: String
        let passed: Bool
        let detail: String
    }

    struct Corpus: Encodable {
        var articles = 0
        var japaneseTranslations = 0
        var subscriptions = 0
        var bookmarks = 0
        var minimumOriginalBytes = Int.max
        var maximumOriginalBytes = 0
        var minimumTranslationBytes = Int.max
        var maximumTranslationBytes = 0
        var totalOriginalBytes: Int64 = 0
        var totalTranslationBytes: Int64 = 0
        var sha256 = ""
    }

    struct Report: Encodable {
        let formatVersion = 2
        let corpusVersion = "fulltext-adversarial-v1-seed-20261022"
        let budgetMilliseconds = FullTextSearchBenchmark.budgetMilliseconds
        let iterations = FullTextSearchBenchmark.iterations
        let operatingSystem = ProcessInfo.processInfo.operatingSystemVersionString
        let processorCount = ProcessInfo.processInfo.activeProcessorCount
        let physicalMemoryBytes = ProcessInfo.processInfo.physicalMemory
        let sqliteVersion = String(cString: sqlite3_libversion())
        let sqliteSourceID = String(cString: sqlite3_sourceid())
        let buildConfiguration = "swiftc -O -swift-version 6; TextbookCore release; vendored CSQLite object files"
        let measurementScope = "Release -O; production search API, actor scheduling and complete article/translation values. All first and repeated samples included. Independent oracle checks run after timing. Setup, backfill, validation, UI debounce/rendering excluded. One causal writer-commit wait at the midpoint of each continuous30-sample group is outside search timing. OS/SQLite page caches are not flushed; result caching is not substituted."
        let requiredMetricGroups = Self.requiredMetricCount
        var corpus = Corpus()
        var fixtureMilliseconds = 0.0
        var backfillMilliseconds = 0.0
        var diagnosticDatabaseDirectory: String?
        var journalMode = ""
        var metrics: [Metric] = []
        var paginationSamples: [PaginationSample] = []
        var heldWrites: [HeldEvent] = []
        var continuousWrites: [WriteEvent] = []
        var continuousStartedNanoseconds: UInt64?
        var continuousStoppedNanoseconds: UInt64?
        var continuousDirtyCallbacks = 0
        var checks: [Check] = []
        var failures: [String] = []
        var passed = false
        var isPassing: Bool {
            failures.isEmpty && !metrics.isEmpty && metrics.allSatisfy(\.passed) &&
                checks.allSatisfy(\.passed) && metrics.count == Self.requiredMetricCount &&
                !paginationSamples.isEmpty && paginationSamples.allSatisfy {
                    $0.sample.failure == nil && $0.sample.milliseconds < FullTextSearchBenchmark.budgetMilliseconds
                }
        }
        // queryCases below is intentionally the single source for this count at run time.
        static var requiredMetricCount: Int { (queryNames.count + cursorQueryNames.count) * 3 }
    }

    struct QueryCase: Sendable {
        let name: String
        let request: ArticleSearchRequest
        let terms: [String]
        var expected: Set<String> = []
        var expectedOrder: [String] = []
        var expectedOffset = 0
    }

    static let queryNames = [
        "rare.original.body", "common.original.body", "nohit", "japanese.one",
        "japanese.two", "japanese.three", "rare.and.short", "short.and.rare",
        "rare.and.absent.short", "absent.short.and.rare", "and.across.original.japanese",
        "translation.only.body", "old.outside.latest.2000", "literal.punctuation",
        "width.case", "inverse.width.case", "kana.halfwidth", "kana.fullwidth",
        "ngram.false.positives", "two.character.noncontiguous.decoys",
        "and.decoys", "feed.filter.before.limit", "bookmark.filter.before.limit",
        "combined.filters.before.limit", "empty.feed.filter", "maximum.page.200",
        "kana.voiced.halfwidth", "kana.voiced.katakana", "kana.voiced.hiragana",
        "kana.model.halfwidth", "kana.model.katakana", "kana.model.hiragana",
        "summary.only", "title.only", "field.boundary.not.substring", "unicode.whitespace.and",
        "exact.page.50", "exact.page.200"
    ]

    static let cursorQueryNames = ["common.cursor.second", "common.cursor.middle", "common.cursor.final"]

    static func main() async {
        guard CommandLine.arguments.count <= 2 else {
            FileHandle.standardError.write(Data("usage: FullTextSearchBenchmark [result.json]\n".utf8))
            exit(2)
        }
        var report = Report()
        do { try await run(report: &report) }
        catch { report.failures.append(String(describing: error)) }
        report.passed = report.isPassing
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            if CommandLine.arguments.count == 2 {
                try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
            }
            let count = report.metrics.reduce(0) { $0 + $1.samples.count }
            let maximum = (report.metrics.map(\.maximumMilliseconds) + report.paginationSamples.map { $0.sample.milliseconds }).max() ?? 0
            print("Full-text search: \(report.passed ? "PASS" : "FAIL"), \(report.metrics.count)/\(Report.requiredMetricCount) groups, \(count) samples + \(report.paginationSamples.count) pagination calls, max \(String(format: "%.3f", maximum))ms, continuous commits \(report.continuousWrites.filter(\.succeeded).count).")
            if CommandLine.arguments.count == 1 { FileHandle.standardOutput.write(data + Data("\n".utf8)) }
            for failure in report.failures { FileHandle.standardError.write(Data("\(failure)\n".utf8)) }
        } catch {
            FileHandle.standardError.write(Data("Cannot write benchmark report: \(error)\n".utf8))
            exit(1)
        }
        if !report.passed { exit(1) }
    }

    static func run(report: inout Report) async throws {
        guard report.sqliteVersion == "3.54.1", sqlite3_compileoption_used("ENABLE_FTS5") == 1 else {
            throw Failure("Expected the vendored SQLite 3.54.1 with FTS5, got \(report.sqliteVersion)")
        }
        progress("setup: building 100000 original articles and 100000 Japanese translations")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tsumiki-fulltext-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let keepFixture = ProcessInfo.processInfo.environment["TSUMIKI_SEARCH_KEEP_FIXTURE"] == "1"
        if keepFixture { report.diagnosticDatabaseDirectory = directory.path }
        defer { if !keepFixture { try? FileManager.default.removeItem(at: directory) } }
        let fixture = try Fixture()
        var cases = queryCases(fixture)
        guard cases.map(\.name) == queryNames else { throw Failure("Query manifest changed without updating its contract") }
        let fixtureStart = now()
        report.corpus = try seedV1(directory: directory, fixture: fixture, cases: &cases)
        report.fixtureMilliseconds = milliseconds(fixtureStart, now())
        progress("setup complete: \(String(format: "%.1f", report.fixtureMilliseconds))ms; starting production v1 backfill")
        let gate = CommitGate()
        let backfillStart = now()
        let store = try FeedLibraryStore(directory: directory, beforeCommit: { gate.callback() })
        report.backfillMilliseconds = milliseconds(backfillStart, now())
        progress("backfill complete: \(String(format: "%.1f", report.backfillMilliseconds))ms")
        let inspected = try SQLiteDatabase(directory.appendingPathComponent("feed-library.sqlite"))
        report.journalMode = try inspected.text("PRAGMA journal_mode")
        guard report.journalMode.lowercased() == "wal" else { throw Failure("Search/write overlap requires WAL; got \(report.journalMode)") }
        try verifyCorpus(inspected, expected: report.corpus)
        report.checks.append(Check(name: "v1.backfill.preserved.corpus", passed: true, detail: "100000 original articles, 100000 matching ja rows, 100 feeds, 10000 old bookmarks; source and JP byte totals retained"))

        progress("condition baseline: start")
        var baselineIDs: [String: [String]] = [:]
        var baselineCursors: [String: [Int64]] = [:]
        for query in cases {
            let metric = await measure(condition: "baseline", query: query, store: store, fixture: fixture)
            report.metrics.append(metric)
            guard metric.passed else { throw Failure("Baseline failed: \(query.name): \(metric.samples.last?.failure ?? "missing samples")") }
            baselineIDs[query.name] = metric.samples[0].resultIDs
            baselineCursors[query.name] = metric.samples[0].cursors
        }

        // Cursor anchors come from independently verified one-document lookups, never from
        // a search implementation's ordering. Expected remaining IDs follow v1 insertion order.
        let common = cases.first { $0.name == "common.original.body" }!
        let cursorIndices = [99_949, 50_000, 50]
        for (name, index) in zip(cursorQueryNames, cursorIndices) {
            let text = fixture.identityMarker(index)
            let lookup = QueryCase(name: "anchor.\(name)", request: ArticleSearchRequest(text: text),
                                   terms: [normalize(text)], expected: [fixture.id(index)], expectedOrder: [fixture.id(index)])
            let anchor = try await timedPaginationPage(lookup, phase: "cursor-anchor", store: store,
                                                      fixture: fixture, report: &report)
            let request = ArticleSearchRequest(text: common.request.text, before: anchor.results[0].cursor)
            let expected = Set(common.expected.filter { fixture.index($0)! < index })
            let query = QueryCase(name: name, request: request, terms: common.terms, expected: expected,
                                  expectedOrder: common.expectedOrder.filter { fixture.index($0)! < index })
            let metric = await measure(condition: "baseline", query: query, store: store, fixture: fixture)
            report.metrics.append(metric)
            guard metric.passed else { throw Failure("Baseline cursor query failed: \(name)") }
            baselineIDs[name] = metric.samples[0].resultIDs
            baselineCursors[name] = metric.samples[0].cursors
            cases.append(query)
        }

        progress("condition baseline: complete (\(cases.count) queries x \(iterations) samples)")
        progress("condition held-dirty-writer: start")
        // Every group holds a transaction that has already performed a real article/index write.
        // The gate must still be held after every sample; it auto-releases after five seconds.
        var writerRevision = 0
        for query in cases {
            let oldRevision = writerRevision
            writerRevision += 1
            let revision = writerRevision
            let gateID = gate.arm()
            let writer = Task.detached(priority: .utility) {
                try await saveOriginal(fixture.article(writerIndex, revision: revision), fixture: fixture, store: store)
                return now()
            }
            do {
                try await Task.detached(priority: .utility) { try gate.waitUntilDirty(gateID) }.value
                let oldVisible = try await markerVisible(fixture.marker(oldRevision), store: store)
                let newInvisible = try await !markerVisible(fixture.marker(revision), store: store)
                let metric = await measure(
                    condition: "held-dirty-writer", query: query, store: store, fixture: fixture,
                    reference: baselineIDs[query.name], referenceCursors: baselineCursors[query.name], gate: gate, gateID: gateID
                )
                report.metrics.append(metric)
                gate.release()
                let committed = try await writer.value
                let newVisible = try await markerVisible(fixture.marker(revision), store: store)
                let oldInvisible = try await !markerVisible(fixture.marker(oldRevision), store: store)
                let state = gate.state()
                report.heldWrites.append(HeldEvent(
                    gate: gateID, query: query.name, revision: revision,
                    dirtyNanoseconds: state.dirty, releasedNanoseconds: state.released,
                    committedNanoseconds: committed, watchdogExpired: state.expired,
                    oldMarker: fixture.marker(oldRevision), newMarker: fixture.marker(revision),
                    oldVisibleWhileHeld: oldVisible, newInvisibleWhileHeld: newInvisible,
                    newVisibleAfterCommit: newVisible, oldInvisibleAfterCommit: oldInvisible
                ))
                guard metric.passed, !state.expired, oldVisible, newInvisible, newVisible, oldInvisible,
                      state.dirty < state.released, state.released <= committed else {
                    throw Failure("Dirty writer overlap/snapshot/latency failed: \(query.name)")
                }
            } catch {
                gate.release()
                _ = try? await writer.value
                throw error
            }
        }

        progress("condition held-dirty-writer: complete")
        progress("condition continuous-production-writer: start")
        let ledger = WriterLedger()
        let stop = StopFlag()
        let callbackStart = gate.callbackCount()
        report.continuousStartedNanoseconds = now()
        let initialRevision = writerRevision
        let writer = Task.detached(priority: .utility) {
            var revision = initialRevision
            do {
                while !stop.isSet() {
                    revision += 1
                    let article = fixture.article(writerIndex, revision: revision)
                    let started = now()
                    do {
                        try await saveOriginal(article, fixture: fixture, store: store)
                        ledger.record(WriteEvent(action: "saveFetchedFeed", revision: revision, startedNanoseconds: started,
                                                 finishedNanoseconds: now(), sourceFingerprint: article.sourceFingerprint, succeeded: true))
                    } catch {
                        ledger.record(WriteEvent(action: "saveFetchedFeed", revision: revision, startedNanoseconds: started,
                                                 finishedNanoseconds: now(), sourceFingerprint: article.sourceFingerprint, succeeded: false))
                        throw error
                    }
                    let translationStarted = now()
                    do {
                        try await store.saveTranslation(fixture.translation(article, index: writerIndex, revision: revision))
                        ledger.record(WriteEvent(action: "saveTranslation", revision: revision, startedNanoseconds: translationStarted,
                                                 finishedNanoseconds: now(), sourceFingerprint: article.sourceFingerprint, succeeded: true))
                    } catch {
                        ledger.record(WriteEvent(action: "saveTranslation", revision: revision, startedNanoseconds: translationStarted,
                                                 finishedNanoseconds: now(), sourceFingerprint: article.sourceFingerprint, succeeded: false))
                        throw error
                    }
                }
                ledger.finished()
                return revision
            } catch {
                ledger.finished(error: String(describing: error))
                throw error
            }
        }
        do {
            try await Task.detached(priority: .utility) { try ledger.waitForCommits(2) }.value
            for query in cases {
                let before = ledger.count()
                let metric = await measure(condition: "continuous-production-writer", query: query, store: store,
                                           fixture: fixture, reference: baselineIDs[query.name], referenceCursors: baselineCursors[query.name], ledger: ledger)
                report.metrics.append(metric)
                guard metric.passed, ledger.count() > before, ledger.failure() == nil else {
                    throw Failure("Continuous writer stopped, made no progress, or search failed: \(query.name)")
                }
                guard let first = metric.samples.first?.startedNanoseconds,
                      let last = metric.samples.last?.finishedNanoseconds,
                      ledger.events().contains(where: { $0.succeeded && first < $0.finishedNanoseconds && $0.finishedNanoseconds < last }) else {
                    throw Failure("No successful commit strictly inside the30-search interval: \(query.name)")
                }
                report.checks.append(Check(name: "continuous.writer.overlap.\(query.name)", passed: true,
                                          detail: "Successful real commit strictly inside the30-search interval; one midpoint synchronization excluded from search timing"))
            }
            stop.set()
            writerRevision = try await writer.value
        } catch {
            stop.set()
            _ = try? await writer.value
            report.continuousStoppedNanoseconds = now()
            report.continuousWrites = ledger.events()
            report.continuousDirtyCallbacks = gate.callbackCount() - callbackStart
            throw error
        }
        report.continuousStoppedNanoseconds = now()
        report.continuousWrites = ledger.events()
        report.continuousDirtyCallbacks = gate.callbackCount() - callbackStart
        let samples = report.metrics.filter { $0.condition == "continuous-production-writer" }.flatMap(\.samples)
        guard report.continuousWrites.count >= 30,
              report.continuousWrites.allSatisfy(\.succeeded),
              report.continuousDirtyCallbacks == report.continuousWrites.count,
              report.continuousWrites.contains(where: { $0.action == "saveTranslation" }),
              let firstSearch = samples.first?.startedNanoseconds,
              let lastSearch = samples.last?.finishedNanoseconds,
              report.continuousWrites.first!.startedNanoseconds <= firstSearch,
              report.continuousWrites.last!.finishedNanoseconds >= lastSearch,
              report.continuousWrites.contains(where: { firstSearch < $0.finishedNanoseconds && $0.finishedNanoseconds < lastSearch }) else {
            throw Failure("Missing successful real commits spanning and overlapping the continuous search interval")
        }
        guard try await markerVisible(fixture.marker(writerRevision), store: store) else {
            throw Failure("Continuous writer's final source mutation is not searchable")
        }
        let finalWriterArticle = fixture.article(writerIndex, revision: writerRevision)
        let finalWriterTranslation = fixture.translation(finalWriterArticle, index: writerIndex, revision: writerRevision)
        let storedWriterTranslation = try await store.translation(articleID: finalWriterArticle.id, targetLanguage: "ja")
        let finalJapanesePage = try await store.searchArticles(ArticleSearchRequest(text: fixture.japaneseMarker(writerRevision)))
        let previousJapanesePage = try await store.searchArticles(ArticleSearchRequest(text: fixture.japaneseMarker(writerRevision - 1)))
        guard storedWriterTranslation == finalWriterTranslation, finalJapanesePage.results.count == 1,
              finalJapanesePage.results[0].article == finalWriterArticle,
              finalJapanesePage.results[0].translation == finalWriterTranslation, previousJapanesePage.results.isEmpty else {
            throw Failure("Continuous writer's JP mutation was not persisted and reindexed, or a prior JP revision remained searchable")
        }
        report.checks.append(Check(name: "continuous.writer.real.commits", passed: true,
                                   detail: "\(report.continuousWrites.count) successful source/JP commits; callback count matches; final source/JP revision \(writerRevision) persisted and searchable, prior JP marker absent"))

        progress("condition continuous-production-writer: complete (\(report.continuousWrites.count) real commits)")
        progress("full keyset traversal: start; every page call remains subject to the 100ms budget")
        // Pagination is checked after timing, preserving the first baseline search as a first access.
        for name in ["common.original.body", "bookmark.filter.before.limit", "feed.filter.before.limit", "maximum.page.200", "exact.page.50", "exact.page.200"] {
            let query = cases.first { $0.name == name }!
            let count = try await verifyAllPages(query, store: store, fixture: fixture, report: &report)
            progress("keyset \(name): \(count) results verified")
            report.checks.append(Check(name: "pagination.\(name)", passed: true,
                                      detail: "\(count) distinct matching IDs across all keyset pages; no missing IDs, duplicate IDs or cursor regressions"))
        }
        progress("full keyset traversal: complete; checking source/translation/delete mutations")
        try await verifyMutations(store: store, fixture: fixture, report: &report)
        let reopened = try FeedLibraryStore(directory: directory)
        let retained = try await reopened.searchArticles(ArticleSearchRequest(text: "古層唯一印"))
        guard retained.results.map({ $0.article.id }) == [fixture.id(3)] else { throw Failure("Search backfill/index did not survive reopen") }
        report.checks.append(Check(name: "reopen.persisted.search", passed: true, detail: "Old body-only result remains searchable after reopening the production store"))
        progress("all correctness and timing checks complete")
    }

    fileprivate static func measure(condition: String, query: QueryCase, store: FeedLibraryStore, fixture: Fixture,
                        reference: [String]? = nil, referenceCursors: [Int64]? = nil, gate: CommitGate? = nil, gateID: Int? = nil,
                        ledger: WriterLedger? = nil) async -> Metric {
        var metric = Metric(condition: condition, query: query.name, text: query.request.text,
                            feedID: query.request.feedID, bookmarksOnly: query.request.bookmarksOnly,
                            limit: query.request.limit, expectedMatches: query.expected.count, before: query.request.before)
        var expectedOrder = reference
        var expectedCursors = referenceCursors
        for iteration in 0..<iterations {
            var synchronizationFailure: String?
            if iteration == iterations / 2, let ledger {
                // A fast30-search group can finish before one normal disk commit.
                // Establish progress in its middle without warming the first call,
                // timing the wait, or phase-locking every search to a commit.
                let target = ledger.count() + 1
                do {
                    try await Task.detached(priority: .utility) { try ledger.waitForCommits(target) }.value
                } catch {
                    synchronizationFailure = "Midpoint writer synchronization failed: \(error)"
                }
            }
            let commitsBefore = ledger?.count() ?? 0
            let heldBefore = gate?.isHolding(gateID) ?? true
            let writerRunning = ledger?.isRunning() ?? true
            let cpuStarted = processCPU()
            let started = now() // Before awaiting the production facade: actor queue time is included.
            do {
                if let synchronizationFailure { throw Failure(synchronizationFailure) }
                let page = try await store.searchArticles(query.request)
                let finished = now() // Returned values already contain full article and translation Strings.
                let cpuElapsed = processCPUDelta(cpuStarted)
                let elapsed = milliseconds(started, finished)
                let IDs = page.results.map { $0.article.id }
                var failure: String?
                do {
                    try verifyPage(page, query: query, fixture: fixture)
                    if let expectedOrder, expectedOrder != IDs { throw Failure("Result order/membership changed while only the disjoint writer document changed") }
                    if let expectedCursors, expectedCursors != page.results.map(\.cursor) { throw Failure("Unchanged documents changed keyset cursors") }
                    if !heldBefore || !(gate?.isHolding(gateID) ?? true) { throw Failure("Dirty transaction was released before search completed") }
                    if !writerRunning || !(ledger?.isRunning() ?? true) { throw Failure("Continuous production writer was not running for the whole sample") }
                    if elapsed >= budgetMilliseconds { throw Failure("\(elapsed)ms exceeds the strict 100ms budget") }
                } catch { failure = String(describing: error) }
                if expectedOrder == nil { expectedOrder = IDs }
                if expectedCursors == nil { expectedCursors = page.results.map(\.cursor) }
                metric.samples.append(Sample(startedNanoseconds: started, finishedNanoseconds: finished, milliseconds: elapsed,
                                             resultIDs: IDs, cursors: page.results.map(\.cursor),
                                             originalBytes: page.results.reduce(0) { $0 + $1.article.content.utf8.count },
                                             translationBytes: page.results.reduce(0) { $0 + ($1.translation?.body.utf8.count ?? 0) },
                                             writerCommitsBefore: commitsBefore, writerCommitsAfter: ledger?.count() ?? 0,
                                             heldGate: gateID, failure: failure, processCPUMilliseconds: cpuElapsed))
                if failure != nil { break }
            } catch {
                let finished = now()
                metric.samples.append(Sample(startedNanoseconds: started, finishedNanoseconds: finished,
                                             milliseconds: milliseconds(started, finished), resultIDs: [], cursors: [],
                                             originalBytes: 0, translationBytes: 0, writerCommitsBefore: commitsBefore,
                                             writerCommitsAfter: ledger?.count() ?? 0, heldGate: gateID, failure: String(describing: error),
                                             processCPUMilliseconds: processCPUDelta(cpuStarted)))
                break
            }
        }
        metric.maximumMilliseconds = metric.samples.map(\.milliseconds).max() ?? 0
        metric.firstMilliseconds = metric.samples.first?.milliseconds ?? 0
        metric.passed = metric.samples.count == iterations && metric.samples.allSatisfy {
            $0.failure == nil && $0.milliseconds < budgetMilliseconds
        }
        return metric
    }

    static func verifyPage(_ page: ArticleSearchPage, query: QueryCase, fixture: Fixture) throws {
        let remainingCount = query.expected.count - query.expectedOffset
        guard remainingCount >= 0 else { throw Failure("Pagination offset exceeded the oracle") }
        let expectedCount = min(query.request.limit, remainingCount)
        guard page.results.count == expectedCount else { throw Failure("\(query.name): expected \(expectedCount) results, got \(page.results.count)") }
        let IDs = page.results.map { $0.article.id }
        guard Set(IDs).count == IDs.count, Set(IDs).isSubset(of: query.expected) else { throw Failure("\(query.name): duplicate or unexpected IDs") }
        // The seed records each actual v1 INSERT in order, then reverses that independent
        // list. It never derives expected order from production cursors or backfill metadata.
        let expectedIDs = Array(query.expectedOrder.dropFirst(query.expectedOffset).prefix(query.request.limit))
        guard IDs == expectedIDs else { throw Failure("\(query.name): IDs do not follow independent v1 insertion order") }
        var previous = query.request.before ?? Int64.max
        for result in page.results {
            guard result.cursor > 0, result.cursor < previous else { throw Failure("Keyset cursors must strictly descend") }
            previous = result.cursor
            guard let index = fixture.index(result.article.id), index != writerIndex else { throw Failure("Unexpected fixture article") }
            let article = fixture.article(index)
            let translation = fixture.translation(article, index: index)
            guard result.isBookmarked == (index < 10_000) else {
                throw Failure("\(query.name): bookmark state differs from the same saved snapshot")
            }
            guard result.article == article, result.translation == translation,
                  translation.sourceFingerprint == article.sourceFingerprint else {
                throw Failure("\(query.name): full original/JP values or fingerprint differ from the saved corpus for \(article.id)")
            }
            guard matches(query, article: article, translation: translation, index: index) else { throw Failure("\(query.name): no literal witness in original/JP fields") }
        }
        if remainingCount > query.request.limit {
            guard page.nextCursor == page.results.last?.cursor else { throw Failure("Missing or incorrect nextCursor") }
        } else if page.nextCursor != nil {
            throw Failure("A final page, including exactly limit results, must have nextCursor=nil")
        }
    }

    static func verifyAllPages(_ query: QueryCase, store: FeedLibraryStore, fixture: Fixture,
                               report: inout Report) async throws -> Int {
        var seen: Set<String> = []
        var before: Int64?
        var previous = Int64.max
        repeat {
            let request = ArticleSearchRequest(text: query.request.text, feedID: query.request.feedID,
                                               bookmarksOnly: query.request.bookmarksOnly, limit: query.request.limit, before: before)
            let current = QueryCase(name: query.name, request: request, terms: query.terms,
                                    expected: query.expected, expectedOrder: query.expectedOrder, expectedOffset: seen.count)
            let page = try await timedPaginationPage(current, phase: "full-traversal", store: store,
                                                    fixture: fixture, report: &report)
            for result in page.results {
                guard result.cursor < previous, seen.insert(result.article.id).inserted else { throw Failure("Pagination duplicate/cursor regression") }
                previous = result.cursor
            }
            if let next = page.nextCursor {
                guard next == page.results.last?.cursor, next != before else { throw Failure("Pagination failed to advance") }
                before = next
            } else { break }
            guard seen.count <= query.expected.count else { throw Failure("Pagination exceeded oracle cardinality") }
        } while true
        guard seen == query.expected else { throw Failure("\(query.name): pagination missed \(query.expected.subtracting(seen).count) IDs") }
        return seen.count
    }

    /// Every page call is timed, including cursor lookups and pages used only for completeness.
    /// Validation is outside the timing window, but failures and slow calls remain in the JSON.
    static func timedPaginationPage(_ query: QueryCase, phase: String, store: FeedLibraryStore,
                                    fixture: Fixture, report: inout Report) async throws -> ArticleSearchPage {
        let cpuStarted = processCPU()
        let started = now()
        let page: ArticleSearchPage
        do {
            page = try await store.searchArticles(query.request)
        } catch {
            let finished = now()
            let sample = Sample(startedNanoseconds: started, finishedNanoseconds: finished,
                                milliseconds: milliseconds(started, finished), resultIDs: [], cursors: [],
                                originalBytes: 0, translationBytes: 0, writerCommitsBefore: 0,
                                writerCommitsAfter: 0, heldGate: nil, failure: String(describing: error),
                                processCPUMilliseconds: processCPUDelta(cpuStarted))
            report.paginationSamples.append(PaginationSample(phase: phase, query: query.name, text: query.request.text,
                feedID: query.request.feedID, bookmarksOnly: query.request.bookmarksOnly, limit: query.request.limit,
                before: query.request.before, nextCursor: nil, sample: sample))
            throw error
        }
        let finished = now()
        let cpuElapsed = processCPUDelta(cpuStarted)
        let elapsed = milliseconds(started, finished)
        var failure: String?
        do {
            try verifyPage(page, query: query, fixture: fixture)
            guard elapsed < budgetMilliseconds else { throw Failure("Pagination call exceeded 100ms: \(elapsed)ms") }
        } catch { failure = String(describing: error) }
        let sample = Sample(startedNanoseconds: started, finishedNanoseconds: finished, milliseconds: elapsed,
                            resultIDs: page.results.map { $0.article.id }, cursors: page.results.map(\.cursor),
                            originalBytes: page.results.reduce(0) { $0 + $1.article.content.utf8.count },
                            translationBytes: page.results.reduce(0) { $0 + ($1.translation?.body.utf8.count ?? 0) },
                            writerCommitsBefore: 0, writerCommitsAfter: 0, heldGate: nil, failure: failure,
                            processCPUMilliseconds: cpuElapsed)
        report.paginationSamples.append(PaginationSample(phase: phase, query: query.name, text: query.request.text,
            feedID: query.request.feedID, bookmarksOnly: query.request.bookmarksOnly, limit: query.request.limit,
            before: query.request.before, nextCursor: page.nextCursor, sample: sample))
        if let failure { throw Failure(failure) }
        return page
    }

    // Independent normalization deliberately does not import any search/index helper.
    static func normalize(_ value: String) -> String {
        var output = String.UnicodeScalarView()
        for scalar in value.precomposedStringWithCompatibilityMapping.precomposedStringWithCanonicalMapping.unicodeScalars {
            switch scalar.value {
            case 0x41...0x5A: output.append(UnicodeScalar(scalar.value + 0x20)!)
            case 0x30A1...0x30F6, 0x30FD...0x30FE: output.append(UnicodeScalar(scalar.value - 0x60)!)
            default: output.append(scalar)
            }
        }
        return String(output)
    }

    static func matches(_ query: QueryCase, article: FeedArticle, translation: ArticleTranslation, index: Int) -> Bool {
        guard query.request.feedID == nil || query.request.feedID == article.feedID,
              !query.request.bookmarksOnly || index < 10_000 else { return false }
        let fields = [article.title, article.summary, article.content, translation.title, translation.body].map(normalize)
        return query.terms.allSatisfy { term in fields.contains { $0.contains(term) } }
    }

    static func queryCases(_ fixture: Fixture) -> [QueryCase] {
        let texts = [
            "OnlySourceZephyr818", "commonneedle", "不存在異星印", "共", "共通", "共通軸",
            "OnlySourceZephyr818 共", "共 OnlySourceZephyr818", "OnlySourceZephyr818 鵺", "鵺 OnlySourceZephyr818",
            "跨層原文鍵 跨層訳文鍵", "訳専用薄明印", "古層唯一印", "literal_%_OR_*_\"quote\"",
            "agentwidth52", "ＰＬＡＩＮＡＳＣＩＩＷＩＤＴＨ６１", "かたかな識別印", "カタカナ識別印",
            "順序連結鍵", "離接", "左単語鍵 右単語鍵", "選別唯一印", "選別唯一印", "選別唯一印",
            "commonneedle", "commonneedle",
            "ｶﾞ識別", "ガ識別", "が識別", "ﾓﾃﾞﾙ識別", "モデル識別", "もでる識別",
            "要約識別印", "表題識別印", "分野境界", "跨層原文鍵　跨層訳文鍵",
            "ExactFiftyCorpusKey", "ExactTwoHundredCorpusKey"
        ]
        return zip(queryNames, texts).enumerated().map { offset, pair in
            let feed: String? = [21, 23].contains(offset) ? fixture.feeds[47].id : (offset == 24 ? "absent-feed" : nil)
            let request = offset == 1 ? ArticleSearchRequest(text: pair.1) : ArticleSearchRequest(text: pair.1, feedID: feed, bookmarksOnly: [22, 23].contains(offset), limit: (offset == 25 || pair.0 == "exact.page.200") ? 200 : 50)
            return QueryCase(name: pair.0, request: request,
                             terms: normalize(pair.1).split(whereSeparator: \.isWhitespace).map(String.init))
        }
    }

    struct Fixture: Sendable {
        let feeds: [FeedSubscription]
        init() throws {
            feeds = try (0..<100).map { try FeedSubscription(url: URL(string: "https://search-\($0).example/feed")!, title: "Search feed \($0)") }
        }
        func id(_ index: Int) -> String { String(format: "search-article-%06d", index) }
        func index(_ id: String) -> Int? {
            guard id.hasPrefix("search-article-"), let value = Int(id.dropFirst("search-article-".count)),
                  (0..<articleCount).contains(value), self.id(value) == id else { return nil }
            return value
        }
        func identityMarker(_ index: Int) -> String { String(format: "CorpusIdentityMarker%06dZ", index) }
        func marker(_ revision: Int) -> String { String(format: "WriterRevisionMarker%09dZ", revision) }
        func japaneseMarker(_ revision: Int) -> String { String(format: "WriterJapaneseRevisionMarker%09dZ", revision) }
        func article(_ index: Int, revision: Int = 0) -> FeedArticle {
            var body = index == writerIndex ? "\(marker(revision))\n" : "commonneedle 共通軸\n"
            body += identityMarker(index) + "\n"
            if (1_000..<1_050).contains(index) { body += "ExactFiftyCorpusKey\n" }
            if (2_000..<2_200).contains(index) { body += "ExactTwoHundredCorpusKey\n" }
            switch index {
            case 3: body += "古層唯一印\n"
            case 7: body += "OnlySourceZephyr818\n"
            case 17: body += "跨層原文鍵\n"
            case 19: body += "literal_%_OR_*_\"quote\"\n"
            case 23: body += "ＡｇＥｎＴＷｉＤｔＨ５２\n"
            case 29: body += "PlainAsciiWidth61\n"
            case 31: body += "ｶﾀｶﾅ識別印\n"
            case 59: body += "ｶﾞ識別\n"
            case 61: body += "ﾓﾃﾞﾙ識別\n"
            case 37: body += "順序連結鍵\n"
            case 41: body += "離接\n"
            case 43: body += "左単語鍵\n"
            case 47: body += "選別唯一印\n"
            case 20_053: body += "非保存削除識別印\n"
            default: break
            }
            if (100..<90_000).contains(index) {
                body += "順序連 / 序連結 / 連結鍵 / 離 は遠く 接\n"
                if index.isMultiple(of: 2) { body += "左単語鍵\n" }
            }
            if (20_000..<90_000).contains(index), index % 100 != 47 { body += "選別唯一印\n" }
            var paragraph = 0
            while body.utf8.count < 1_950 {
                body += "Record \(index) revision \(revision) section \(paragraph): local storage keeps complete source paragraphs, independent observations and deterministic fixtures.\n"
                paragraph += 1
            }
            return FeedArticle(id: id(index), feedID: feeds[index % 100].id, remoteID: "remote-\(index)",
                               title: index == 71 ? "表題識別印 \(index)" : (index == 79 ? "Original article \(index) 分野" : "Original article \(index)"), url: URL(string: "https://search.example/article/\(index)"),
                               summary: index == 67 ? "要約識別印" : (index == 79 ? "境界 Source summary \(index)." : "Source summary \(index)."), content: body,
                               publishedAt: Date(timeIntervalSinceReferenceDate: TimeInterval(index)))
        }
        func translation(_ article: FeedArticle, index: Int, revision: Int = 0) -> ArticleTranslation {
            var body = "保存した日本語訳です。記録番号\(index)、版\(revision)。\n"
            if index == writerIndex { body += japaneseMarker(revision) + "\n" }
            switch index {
            case 13: body += "訳専用薄明印\n"
            case 17: body += "跨層訳文鍵\n"
            case 43: body += "右単語鍵\n"
            case 53: body += "陳旧訳識別印\n"
            default: break
            }
            if (100..<90_000).contains(index), !index.isMultiple(of: 2) { body += "右単語鍵\n" }
            var paragraph = 0
            while body.utf8.count < 1_950 {
                body += "段落\(paragraph)：記事\(index)の情報を保存し、原文と翻訳の対応を確認します。内容を読み直すために必要な文章を省略せず記録します。\n"
                paragraph += 1
            }
            return ArticleTranslation(articleID: article.id, sourceFingerprint: article.sourceFingerprint,
                                      targetLanguage: "ja", title: "日本語訳 \(index)", body: body)
        }
    }

    static func seedV1(directory: URL, fixture: Fixture, cases: inout [QueryCase]) throws -> Corpus {
        let db = try SQLiteDatabase(directory.appendingPathComponent("feed-library.sqlite"))
        // This is the actual pre-search schema, without search tables, triggers or metadata.
        try db.execute("CREATE TABLE subscriptions(id TEXT PRIMARY KEY,url TEXT NOT NULL UNIQUE,title TEXT,etag TEXT,last_modified TEXT);CREATE TABLE articles(id TEXT PRIMARY KEY,feed_id TEXT NOT NULL,remote_id TEXT,title TEXT NOT NULL,url TEXT,summary TEXT NOT NULL,content TEXT NOT NULL,published REAL);CREATE INDEX articles_feed_published ON articles(feed_id,published);CREATE TABLE bookmarks(article_id TEXT PRIMARY KEY REFERENCES articles(id));CREATE TABLE translations(article_id TEXT NOT NULL REFERENCES articles(id),source_fingerprint TEXT NOT NULL,target_language TEXT NOT NULL,title TEXT NOT NULL,body TEXT NOT NULL,PRIMARY KEY(article_id,target_language));PRAGMA user_version=1;")
        try db.execute("BEGIN IMMEDIATE")
        let subscription = try db.prepare("INSERT INTO subscriptions(id,url,title) VALUES(?,?,?)")
        let articleInsert = try db.prepare("INSERT INTO articles(id,feed_id,remote_id,title,url,summary,content,published) VALUES(?,?,?,?,?,?,?,?)")
        let translationInsert = try db.prepare("INSERT INTO translations(article_id,source_fingerprint,target_language,title,body) VALUES(?,?,?,?,?)")
        defer { sqlite3_finalize(subscription); sqlite3_finalize(articleInsert); sqlite3_finalize(translationInsert) }
        var corpus = Corpus()
        var digest = SHA256()
        do {
            for feed in fixture.feeds {
                try db.insert(subscription, strings: [feed.id, feed.url.absoluteString, feed.title])
                corpus.subscriptions += 1
            }
            for index in 0..<articleCount {
                let article = fixture.article(index)
                let translation = fixture.translation(article, index: index)
                let originalBytes = article.content.utf8.count
                let translationBytes = translation.body.utf8.count
                guard (1_900...2_400).contains(originalBytes), (1_900...2_400).contains(translationBytes) else { throw Failure("Fixture body size outside approximately 2KB") }
                try db.insert(articleInsert, strings: [article.id, article.feedID, article.remoteID, article.title,
                                                      article.url?.absoluteString, article.summary, article.content], lastDouble: article.publishedAt!.timeIntervalSinceReferenceDate)
                try db.insert(translationInsert, strings: [translation.articleID, translation.sourceFingerprint, "ja", translation.title, translation.body])
                let normalized = [article.title, article.summary, article.content, translation.title, translation.body].map(normalize)
                for offset in cases.indices {
                    // Do not copy QueryCase: its growing Set/Array oracle would trigger COW
                    // on every insertion. Only the small request/term values are borrowed here.
                    let request = cases[offset].request
                    let terms = cases[offset].terms
                    if (request.feedID == nil || request.feedID == article.feedID),
                       !request.bookmarksOnly || index < 10_000,
                       terms.allSatisfy({ term in normalized.contains { $0.contains(term) } }) {
                        cases[offset].expected.insert(article.id)
                        cases[offset].expectedOrder.append(article.id)
                    }
                }
                digest.update(data: Data((article.id + "\u{0}" + article.title + "\u{0}" + article.content + "\u{0}" + translation.title + "\u{0}" + translation.body).utf8))
                corpus.articles += 1; corpus.japaneseTranslations += 1
                corpus.minimumOriginalBytes = min(corpus.minimumOriginalBytes, originalBytes)
                corpus.maximumOriginalBytes = max(corpus.maximumOriginalBytes, originalBytes)
                corpus.minimumTranslationBytes = min(corpus.minimumTranslationBytes, translationBytes)
                corpus.maximumTranslationBytes = max(corpus.maximumTranslationBytes, translationBytes)
                corpus.totalOriginalBytes += Int64(originalBytes); corpus.totalTranslationBytes += Int64(translationBytes)
                if (index + 1).isMultiple(of: 25_000) { progress("seed: \(index + 1)/\(articleCount) original + Japanese rows prepared") }
            }
            try db.execute("INSERT INTO bookmarks SELECT id FROM articles WHERE id < 'search-article-010000'; COMMIT")
        } catch { try? db.execute("ROLLBACK"); throw error }
        for offset in cases.indices { cases[offset].expectedOrder.reverse() }
        corpus.bookmarks = 10_000
        corpus.sha256 = digest.finalize().map { String(format: "%02x", $0) }.joined()
        guard cases.first(where: { $0.name == "common.original.body" })?.expected.count == articleCount - 1,
              cases.first(where: { $0.name == "translation.only.body" })?.expected == [fixture.id(13)],
              cases.first(where: { $0.name == "ngram.false.positives" })?.expected == [fixture.id(37)],
              cases.first(where: { $0.name == "and.decoys" })?.expected == [fixture.id(43)],
              cases.first(where: { $0.name == "exact.page.50" })?.expected.count == 50,
              cases.first(where: { $0.name == "exact.page.200" })?.expected.count == 200,
              cases.allSatisfy({ !$0.expected.contains(fixture.id(writerIndex)) }) else {
            throw Failure("Independent corpus/query oracle cardinality or disjoint-writer invariant failed")
        }
        return corpus
    }

    fileprivate static func verifyCorpus(_ db: SQLiteDatabase, expected: Corpus) throws {
        let values: [(String, Int64)] = [
            ("SELECT count(*) FROM articles", Int64(expected.articles)),
            ("SELECT count(*) FROM translations WHERE target_language='ja'", Int64(expected.japaneseTranslations)),
            ("SELECT count(*) FROM subscriptions", Int64(expected.subscriptions)),
            ("SELECT count(*) FROM bookmarks", Int64(expected.bookmarks)),
            ("SELECT sum(length(CAST(content AS BLOB))) FROM articles", expected.totalOriginalBytes),
            ("SELECT sum(length(CAST(body AS BLOB))) FROM translations WHERE target_language='ja'", expected.totalTranslationBytes),
            ("SELECT count(*) FROM translations t JOIN articles a ON a.id=t.article_id WHERE t.target_language='ja'", Int64(expected.articles)),
        ]
        for (sql, expected) in values where try db.integer(sql) != expected { throw Failure("Backfill changed corpus data: \(sql)") }
    }

    static func saveOriginal(_ article: FeedArticle, fixture: Fixture, store: FeedLibraryStore) async throws {
        let feed = fixture.feeds.first { $0.id == article.feedID }!
        let saved = try await store.saveFetchedFeedIfSubscribed(ParsedFeed(id: feed.id, sourceURL: feed.url, title: feed.title ?? "Feed", articles: [article]), eTag: nil, lastModified: nil)
        guard saved else { throw Failure("Production writer rejected its subscribed feed") }
    }

    static func markerVisible(_ marker: String, store: FeedLibraryStore) async throws -> Bool {
        let page = try await store.searchArticles(ArticleSearchRequest(text: marker))
        return page.results.count == 1 && page.results[0].article.id == String(format: "search-article-%06d", writerIndex) && page.results[0].article.content.contains(marker)
    }

    static func verifyMutations(store: FeedLibraryStore, fixture: Fixture, report: inout Report) async throws {
        let original = fixture.article(53)
        let oldTranslation = fixture.translation(original, index: 53)
        let before = try await store.searchArticles(ArticleSearchRequest(text: "陳旧訳識別印"))
        guard before.results.map({ $0.article.id }) == [original.id] else { throw Failure("Initial JP-only mutation witness missing") }
        let updated = FeedArticle(id: original.id, feedID: original.feedID, remoteID: original.remoteID, title: original.title,
                                  url: original.url, summary: original.summary, content: original.content + "\n原文更新専用印", publishedAt: original.publishedAt)
        try await saveOriginal(updated, fixture: fixture, store: store)
        let stale = try await store.searchArticles(ArticleSearchRequest(text: "陳旧訳識別印"))
        let promoted = try await store.searchArticles(ArticleSearchRequest(text: "commonneedle"))
        guard stale.results.isEmpty, promoted.results.first?.article == updated,
              promoted.results.first?.translation == nil,
              promoted.results.first!.cursor > before.results[0].cursor else { throw Failure("Updated source retained stale JP or failed saved/updated order") }
        do { try await store.saveTranslation(oldTranslation); throw Failure("Stale JP save unexpectedly succeeded") }
        catch FeedError.staleTranslation {}
        let fresh = ArticleTranslation(articleID: updated.id, sourceFingerprint: updated.sourceFingerprint, targetLanguage: "ja", title: "新しい訳", body: "刷新訳識別印：更新した日本語訳です。")
        try await store.saveTranslation(fresh)
        let freshPage = try await store.searchArticles(ArticleSearchRequest(text: "刷新訳識別印"))
        guard freshPage.results.count == 1, freshPage.results[0].article == updated, freshPage.results[0].translation == fresh else { throw Failure("Fresh JP replacement not indexed atomically") }
        try await store.saveTranslation(ArticleTranslation(articleID: updated.id, sourceFingerprint: updated.sourceFingerprint, targetLanguage: "en", title: "Other", body: "他言語除外印"))
        let otherLanguage = try await store.searchArticles(ArticleSearchRequest(text: "他言語除外印"))
        guard otherLanguage.results.isEmpty else { throw Failure("Non-Japanese translation leaked into JP search") }
        let notBookmarkedBeforeRemoval = try await store.searchArticles(ArticleSearchRequest(text: "非保存削除識別印"))
        guard notBookmarkedBeforeRemoval.results.map({ $0.article.id }) == [fixture.id(20_053)] else { throw Failure("Non-bookmarked deletion witness missing before removal") }
        try await store.removeSubscription(id: updated.feedID)
        let bookmarked = try await store.searchArticles(ArticleSearchRequest(text: "刷新訳識別印", bookmarksOnly: true))
        let removed = try await store.searchArticles(ArticleSearchRequest(text: "非保存削除識別印"))
        guard bookmarked.results.map({ $0.article.id }) == [updated.id], bookmarked.results[0].translation == fresh,
              removed.results.isEmpty else { throw Failure("Unsubscribe did not preserve bookmarked JP or remove non-bookmarked search rows") }
        _ = try await store.setBookmarked(articleID: updated.id, bookmarked: false)
        let deletedSource = try await store.searchArticles(ArticleSearchRequest(text: "原文更新専用印"))
        let deletedJP = try await store.searchArticles(ArticleSearchRequest(text: "刷新訳識別印"))
        guard deletedSource.results.isEmpty, deletedJP.results.isEmpty else { throw Failure("Orphaned bookmark deletion left searchable source/JP") }
        report.checks.append(Check(name: "mutation.freshness.language.unsubscription.deletion", passed: true,
                                   detail: "Original change hides stale JP, stale save rejected, fresh JP searchable, en ignored, updated document promoted, unsubscribe retains bookmark/JP and removes other article, unbookmark removes source/JP index"))
    }

    static func progress(_ message: String) {
        FileHandle.standardError.write(Data("[fulltext] \(message)\n".utf8))
    }

    // Whole-process counters remain comparable across an actor/thread hop.
    // Concurrent writer CPU is included; a low CPU/wall ratio does not distinguish I/O from scheduling.
    static func processCPU() -> Double? {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1_000
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000
    }
    static func processCPUDelta(_ start: Double?) -> Double? {
        guard let start, let end = processCPU() else { return nil }
        return max(0, end - start)
    }
    static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    static func milliseconds(_ start: UInt64, _ end: UInt64) -> Double { Double(end - start) / 1_000_000 }
}

private final class SQLiteDatabase {
    private let db: OpaquePointer
    init(_ url: URL) throws {
        var opened: OpaquePointer?
        guard sqlite3_open_v2(url.path, &opened, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let opened else {
            if let opened { sqlite3_close_v2(opened) }
            throw FullTextSearchBenchmark.Failure("Fixture database open failed")
        }
        db = opened
        sqlite3_busy_timeout(db, 5_000)
    }
    deinit { sqlite3_close_v2(db) }
    func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure("execute") }
    }
    func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure("prepare") }
        return statement
    }
    func insert(_ statement: OpaquePointer, strings: [String?], lastDouble: Double? = nil) throws {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        for (offset, value) in strings.enumerated() {
            let status: Int32
            if let value {
                status = value.withCString { sqlite3_bind_text(statement, Int32(offset + 1), $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            } else { status = sqlite3_bind_null(statement, Int32(offset + 1)) }
            guard status == SQLITE_OK else { throw failure("bind text") }
        }
        if let lastDouble {
            guard sqlite3_bind_double(statement, Int32(strings.count + 1), lastDouble) == SQLITE_OK else { throw failure("bind real") }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure("insert") }
    }
    func text(_ sql: String) throws -> String {
        let statement = try prepare(sql); defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else { throw failure("scalar text") }
        return String(cString: value)
    }
    func integer(_ sql: String) throws -> Int64 {
        let statement = try prepare(sql); defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_type(statement, 0) == SQLITE_INTEGER else { throw failure("scalar integer") }
        return sqlite3_column_int64(statement, 0)
    }
    private func failure(_ operation: String) -> FullTextSearchBenchmark.Failure {
        FullTextSearchBenchmark.Failure("Fixture SQLite \(operation): \(String(cString: sqlite3_errmsg(db)))")
    }
}

/// Only this callback blocks a writer actor. A forwarding bug in search must fail, not hang.
private final class CommitGate: @unchecked Sendable {
    struct State { let dirty: UInt64; let released: UInt64; let expired: Bool }
    private let condition = NSCondition()
    private var serial = 0
    private var armed = false
    private var dirty: UInt64 = 0
    private var released: UInt64 = 0
    private var expired = false
    private var callbacks = 0
    func arm() -> Int {
        condition.lock(); defer { condition.unlock() }
        precondition(!armed)
        serial += 1; armed = true; dirty = 0; released = 0; expired = false
        return serial
    }
    func callback() {
        condition.lock(); defer { condition.unlock() }
        callbacks += 1
        guard armed else { return }
        dirty = FullTextSearchBenchmark.now()
        condition.broadcast()
        let deadline = Date(timeIntervalSinceNow: 5)
        while armed {
            if !condition.wait(until: deadline) {
                expired = true; armed = false; released = FullTextSearchBenchmark.now()
                condition.broadcast(); break
            }
        }
    }
    func waitUntilDirty(_ gate: Int) throws {
        condition.lock(); defer { condition.unlock() }
        let deadline = Date(timeIntervalSinceNow: 5)
        while dirty == 0 && armed && serial == gate {
            if !condition.wait(until: deadline) { throw FullTextSearchBenchmark.Failure("Writer never reached its dirty pre-COMMIT hook") }
        }
        guard serial == gate, dirty != 0, armed, !expired else { throw FullTextSearchBenchmark.Failure("Dirty writer gate expired before measurement") }
    }
    func release() {
        condition.lock(); defer { condition.unlock() }
        if armed { armed = false; released = FullTextSearchBenchmark.now() }
        condition.broadcast()
    }
    func isHolding(_ gate: Int?) -> Bool {
        condition.lock(); defer { condition.unlock() }
        return gate == serial && armed && dirty != 0 && !expired
    }
    func state() -> State {
        condition.lock(); defer { condition.unlock() }
        return State(dirty: dirty, released: released, expired: expired)
    }
    func callbackCount() -> Int {
        condition.lock(); defer { condition.unlock() }; return callbacks
    }
}

private final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    func set() { lock.withLock { stopped = true } }
    func isSet() -> Bool { lock.withLock { stopped } }
}

private final class WriterLedger: @unchecked Sendable {
    private let condition = NSCondition()
    private var writes: [FullTextSearchBenchmark.WriteEvent] = []
    private var running = true
    private var error: String?
    func record(_ event: FullTextSearchBenchmark.WriteEvent) {
        condition.lock(); defer { condition.unlock() }
        writes.append(event); condition.broadcast()
    }
    func finished(error: String? = nil) {
        condition.lock(); defer { condition.unlock() }
        running = false; self.error = error; condition.broadcast()
    }
    func count() -> Int { condition.lock(); defer { condition.unlock() }; return writes.count }
    func events() -> [FullTextSearchBenchmark.WriteEvent] { condition.lock(); defer { condition.unlock() }; return writes }
    func isRunning() -> Bool { condition.lock(); defer { condition.unlock() }; return running }
    func failure() -> String? { condition.lock(); defer { condition.unlock() }; return error }
    func waitForCommits(_ count: Int) throws {
        condition.lock(); defer { condition.unlock() }
        let deadline = Date(timeIntervalSinceNow: 5)
        while writes.count < count && running {
            if !condition.wait(until: deadline) { throw FullTextSearchBenchmark.Failure("Continuous writer did not commit within five seconds") }
        }
        guard running, error == nil, writes.count >= count else { throw FullTextSearchBenchmark.Failure("Continuous writer failed before measurement: \(error ?? "stopped")") }
    }
}
