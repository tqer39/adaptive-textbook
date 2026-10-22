import Combine
import Foundation
import XCTest
@_spi(Testing) import TextbookCore
@testable import TextbookUI

// Independent regression gates: real held writer and controlled late responses.
@MainActor
final class NativeSearchIndependentRegressionTests: XCTestCase {
    func testNormalModelSearchPublishesCommittedSnapshotWhileRealWriterIsDirty() async throws {
        let fixture = try NativeSearchIndependentFixture()
        let directory = nativeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = NativeSearchIndependentCommitGate()
        defer { gate.release() }
        let store = try FeedLibraryStore(directory: directory, beforeCommit: { gate.callback() })
        try await store.saveFetchedFeed(fixture.feed(articles: [fixture.article]))
        try await store.saveTranslation(fixture.translation)
        let model = FeedReaderModel(store: store, fetcher: NativeSearchIndependentUnchangedFetcher(), searchDebounce: .zero)
        await model.initialize()

        gate.arm()
        let changed = fixture.updatedArticle
        let changedFeed = fixture.feed(articles: [changed])
        let writer = Task.detached(priority: .utility) { try await store.saveFetchedFeed(changedFeed) }
        let reachedDirtyTransaction = await gate.entered.wait(timeout: 2)
        guard reachedDirtyTransaction else {
            gate.release()
            _ = try? await writer.value
            XCTFail("Production writer did not reach the actual post-write/pre-COMMIT hook")
            return
        }

        model.searchText = "旧文書固定検索印"
        let completedBeforeRelease = await nativeWaitForSearchCompletion(model)
        let holdingAtCompletion = gate.isHolding()
        let watchdogExpired = gate.watchdogExpired()
        model.selectedArticleID = fixture.article.id

        // These assertions intentionally precede release(). A model that awaits
        // the writer actor's isBookmarked before publishing its page must fail.
        XCTAssertTrue(completedBeforeRelease, "The normal UI search must finish while the dirty writer remains held")
        XCTAssertTrue(holdingAtCompletion, "Search only returning after writer release is not overlap")
        XCTAssertFalse(watchdogExpired, "Auto-release must never turn a blocked UI search into a passing test")
        XCTAssertFalse(model.isSearching)
        XCTAssertEqual(model.searchResults.map(\.article.id), [fixture.article.id])
        XCTAssertEqual(model.visibleArticles, [fixture.article])
        XCTAssertEqual(model.selectedArticle, fixture.article)
        XCTAssertEqual(model.searchResults.first?.translation, fixture.translation)

        // Cancel this UI query before cleanup so a late ancillary bookmark read
        // cannot leak a task into another test. Then commit the real mutation.
        model.searchText = ""
        gate.release()
        try await writer.value
        let committed = try await store.searchArticles(ArticleSearchRequest(text: "新文書更新検索印"))
        let obsolete = try await store.searchArticles(ArticleSearchRequest(text: "旧文書固定検索印"))
        XCTAssertEqual(committed.results.map(\.article), [changed])
        XCTAssertTrue(obsolete.results.isEmpty)
    }

    func testRefreshAfterOtherStoreDeletesLastSubscriptionClearsSearchAndDetail() async throws {
        let fixture = try NativeSearchIndependentFixture()
        let directory = nativeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FeedLibraryStore(directory: directory)
        try await store.saveFetchedFeed(fixture.feed(articles: [fixture.article]))
        let otherStore = try FeedLibraryStore(directory: directory)
        let model = FeedReaderModel(store: store, fetcher: NativeSearchIndependentUnchangedFetcher(), searchDebounce: .zero)
        await model.initialize()
        model.searchText = "旧文書固定検索印"
        let initialSearchFinished = await nativeWaitForSearchCompletion(model)
        XCTAssertTrue(initialSearchFinished)
        XCTAssertEqual(model.searchResults.map(\.article.id), [fixture.article.id])
        model.selectedArticleID = fixture.article.id
        XCTAssertEqual(model.selectedArticle, fixture.article)

        // A second real connection deletes the only feed and its unbookmarked article.
        // refresh() must reconcile active search even when its fetch target list is empty.
        try await otherStore.removeSubscription(id: fixture.subscription.id)
        let persistedSubscriptions = try await store.subscriptions()
        let persistedArticles = try await store.articles()
        XCTAssertTrue(persistedSubscriptions.isEmpty)
        XCTAssertTrue(persistedArticles.isEmpty)
        await model.refresh()
        let refreshedSearchFinished = await nativeWaitForSearchCompletion(model)

        XCTAssertTrue(refreshedSearchFinished)
        XCTAssertTrue(model.subscriptions.isEmpty)
        XCTAssertTrue(model.searchResults.isEmpty)
        XCTAssertTrue(model.visibleArticles.isEmpty)
        XCTAssertNil(model.selectedArticleID)
        XCTAssertNil(model.selectedArticle)
        model.searchText = ""
    }

    func testBookmarkLookupFailureCannotDiscardSuccessfulCoreSearchHit() async throws {
        let fixture = try NativeSearchIndependentFixture()
        let store = NativeSearchIndependentMemoryStore(fixture: fixture, orphanBookmark: false, bookmarkReadFails: true)
        let page = ArticleSearchPage(results: [ArticleSearchResult(article: fixture.article, translation: fixture.translation, cursor: 10)], nextCursor: nil)
        let searcher = NativeSearchIndependentStaticSearcher(page: page)
        let model = FeedReaderModel(store: store, fetcher: NativeSearchIndependentUnchangedFetcher(),
                                    searcher: searcher, searchDebounce: .zero)
        await model.initialize()
        model.searchText = "旧文書固定検索印"
        let completed = await nativeWaitForSearchCompletion(model)

        XCTAssertTrue(completed)
        XCTAssertFalse(model.isSearching)
        XCTAssertEqual(model.searchResults.map(\.article.id), [fixture.article.id])
        XCTAssertEqual(model.visibleArticles, [fixture.article])
        XCTAssertFalse(model.searchMessage?.contains("検索できませんでした") == true)
        XCTAssertFalse(model.searchMessage?.contains("一致する保存済み記事はありません") == true)
        // No successful bookmark read established a saved state. The fallback must
        // not advertise this unknown article as saved or remove anything automatically.
        XCTAssertFalse(model.bookmarkedIDs.contains(fixture.article.id))
        let automaticMutations = await store.bookmarkMutations()
        XCTAssertTrue(automaticMutations.isEmpty)
        await model.setBookmark(false, article: fixture.article)
        let unsafeUnknownMutations = await store.bookmarkMutations()
        XCTAssertTrue(unsafeUnknownMutations.isEmpty, "Unknown bookmark state must disable a blind UI mutation")
        model.selectedArticleID = fixture.article.id
        XCTAssertEqual(model.selectedArticle, fixture.article)
        model.searchText = ""
    }

    func testLateOldCacheSuccessCannotResurrectDeletedOrphanAfterNewReloadFails() async throws {
        let fixture = try NativeSearchIndependentFixture()
        let store = NativeSearchIndependentMemoryStore(fixture: fixture, orphanBookmark: true)
        let model = FeedReaderModel(store: store, fetcher: NativeSearchIndependentUnchangedFetcher(), searchDebounce: .zero)
        await model.initialize()
        XCTAssertEqual(model.articles, [fixture.article])
        XCTAssertTrue(model.bookmarkedIDs.contains(fixture.article.id))
        model.selectedArticleID = fixture.article.id
        model.showsBookmarksOnly = true

        // Hold all three real reload API responses after taking the old snapshot.
        // This prevents scheduler order from deciding which response is stale.
        let ticket = await store.armOldReloadSnapshot()
        defer { ticket.release.signal() }
        let olderRefresh = Task { await model.refresh() }
        let allOldReadsStarted = await ticket.started.wait(timeout: 2)
        guard allOldReadsStarted else {
            ticket.release.signal()
            await olderRefresh.value
            XCTFail("The controlled old reload never captured subscriptions/articles/bookmarks")
            return
        }

        await store.failReloadAfterNextBookmark()
        await model.setBookmark(false, article: fixture.article)
        let committedSnapshot = await store.snapshot()
        XCTAssertTrue(committedSnapshot.articles.isEmpty)
        XCTAssertTrue(committedSnapshot.bookmarkedIDs.isEmpty)
        XCTAssertTrue(model.articles.isEmpty)
        XCTAssertTrue(model.visibleArticles.isEmpty)
        XCTAssertNil(model.selectedArticle)
        XCTAssertNil(model.selectedArticleID)
        XCTAssertFalse(model.bookmarkedIDs.contains(fixture.article.id))
        XCTAssertTrue(model.message.hasPrefix("ブックマークは保存しましたが、保存済み記事の再読み込みに失敗しました:"))

        // The old read succeeds only after the newer mutation and failed reload.
        // Awaiting the refresh's completion gives a causal barrier without sleeps/yields.
        ticket.release.signal()
        await olderRefresh.value
        let fakeWatchdogExpired = await store.cacheReadWatchdogExpired()
        XCTAssertFalse(fakeWatchdogExpired)
        XCTAssertTrue(model.articles.isEmpty, "A late old cache read must not resurrect a committed deletion")
        XCTAssertTrue(model.visibleArticles.isEmpty)
        XCTAssertFalse(model.bookmarkedIDs.contains(fixture.article.id))
        XCTAssertNil(model.selectedArticleID)
        XCTAssertNil(model.selectedArticle)
        model.showsBookmarksOnly = false
        XCTAssertTrue(model.visibleArticles.isEmpty, "Changing the filter must not uncover a resurrected cached snapshot")
    }

    private func nativeTemporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("native-search-independent-\(UUID().uuidString)", isDirectory: true)
    }

    private func nativeWaitForSearchCompletion(_ model: FeedReaderModel) async -> Bool {
        let completed = NativeSearchIndependentLatch()
        let observer = model.$isSearching.sink { searching in
            if !searching { completed.signal() }
        }
        defer { observer.cancel() }
        return await completed.wait(timeout: 2)
    }
}

private struct NativeSearchIndependentFixture: Sendable {
    let subscription: FeedSubscription
    let article: FeedArticle
    let updatedArticle: FeedArticle
    let translation: ArticleTranslation

    init() throws {
        subscription = try FeedSubscription(url: URL(string: "https://native-independent.example/feed")!, title: "独立回帰フィード")
        article = FeedArticle(id: "native-independent-article", feedID: subscription.id, title: "元の記事", url: nil,
                              content: "旧文書固定検索印：保存してある原文です。", publishedAt: Date(timeIntervalSinceReferenceDate: 123))
        updatedArticle = FeedArticle(id: article.id, feedID: article.feedID, title: article.title, url: nil,
                                     content: "新文書更新検索印：更新した原文です。", publishedAt: article.publishedAt)
        translation = ArticleTranslation(articleID: article.id, sourceFingerprint: article.sourceFingerprint,
                                         targetLanguage: "ja", title: "保存された日本語訳", body: "旧版に対応した日本語訳です。")
    }

    func feed(articles: [FeedArticle]) -> ParsedFeed {
        ParsedFeed(id: subscription.id, sourceURL: subscription.url, title: subscription.title ?? "Feed", articles: articles)
    }
}

private struct NativeSearchIndependentUnchangedFetcher: FeedFetching {
    func fetch(_ subscription: FeedSubscription) async throws -> FeedFetchResult { .notModified }
}

private actor NativeSearchIndependentStaticSearcher: ArticleSearching {
    private let page: ArticleSearchPage
    init(page: ArticleSearchPage) { self.page = page }
    func searchArticles(_ request: ArticleSearchRequest) async throws -> ArticleSearchPage { page }
}

/// Checked continuations have finite watchdogs. Dispatch deadlines only bound failures;
/// signal() and captured API events establish all interleavings used by these tests.
private final class NativeSearchIndependentLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var signaled = false
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    func signal() {
        let ready = lock.withLock { () -> [CheckedContinuation<Bool, Never>] in
            signaled = true
            let ready = Array(waiters.values)
            waiters.removeAll()
            return ready
        }
        for continuation in ready { continuation.resume(returning: true) }
    }

    func wait(timeout: Double) async -> Bool {
        await withCheckedContinuation { continuation in
            let id = UUID()
            let alreadySignaled = lock.withLock { () -> Bool in
                if signaled { return true }
                waiters[id] = continuation
                return false
            }
            if alreadySignaled { continuation.resume(returning: true); return }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [self] in
                let pending = lock.withLock { waiters.removeValue(forKey: id) }
                pending?.resume(returning: false)
            }
        }
    }
}

private final class NativeSearchIndependentCommitGate: @unchecked Sendable {
    let entered = NativeSearchIndependentLatch()
    private let condition = NSCondition()
    private var armed = false
    private var dirty = false
    private var expired = false

    func arm() {
        condition.lock(); defer { condition.unlock() }
        armed = true; dirty = false; expired = false
    }

    func callback() {
        condition.lock()
        guard armed else { condition.unlock(); return }
        dirty = true
        condition.unlock()
        entered.signal()
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date(timeIntervalSinceNow: 5)
        while armed {
            if !condition.wait(until: deadline) { expired = true; armed = false; break }
        }
    }

    func release() {
        condition.lock(); defer { condition.unlock() }
        armed = false
        condition.broadcast()
    }

    func isHolding() -> Bool {
        condition.lock(); defer { condition.unlock() }
        return armed && dirty && !expired
    }

    func watchdogExpired() -> Bool {
        condition.lock(); defer { condition.unlock() }; return expired
    }
}

private struct NativeSearchIndependentCacheTicket: Sendable {
    let started = NativeSearchIndependentLatch()
    let release = NativeSearchIndependentLatch()
}

private actor NativeSearchIndependentMemoryStore: FeedLibraryStoring {
    struct Snapshot: Sendable {
        let subscriptions: [FeedSubscription]
        let articles: [FeedArticle]
        let bookmarkedIDs: Set<String>
    }
    private enum ReadPart: CaseIterable, Hashable { case subscriptions, articles, bookmarks }
    private struct HeldSnapshot: Sendable {
        let value: Snapshot
        let ticket: NativeSearchIndependentCacheTicket
    }

    private var savedSubscriptions: [FeedSubscription]
    private var savedArticles: [FeedArticle]
    private var savedBookmarks: Set<String>
    private var translations: [String: ArticleTranslation]
    private let bookmarkReadFails: Bool
    private var mutationValues: [Bool] = []
    private var failAfterBookmark = false
    private var nextReloadFails = false
    private var held: HeldSnapshot?
    private var pendingOldReadParts: Set<ReadPart> = []
    private var oldReadTimedOut = false

    init(fixture: NativeSearchIndependentFixture, orphanBookmark: Bool, bookmarkReadFails: Bool = false) {
        savedSubscriptions = orphanBookmark ? [] : [fixture.subscription]
        savedArticles = [fixture.article]
        savedBookmarks = orphanBookmark ? [fixture.article.id] : []
        translations = [fixture.article.id: fixture.translation]
        self.bookmarkReadFails = bookmarkReadFails
    }

    func armOldReloadSnapshot() -> NativeSearchIndependentCacheTicket {
        let ticket = NativeSearchIndependentCacheTicket()
        held = HeldSnapshot(value: snapshot(), ticket: ticket)
        pendingOldReadParts = Set(ReadPart.allCases)
        return ticket
    }

    func failReloadAfterNextBookmark() { failAfterBookmark = true }
    func bookmarkMutations() -> [Bool] { mutationValues }
    func cacheReadWatchdogExpired() -> Bool { oldReadTimedOut }
    func snapshot() -> Snapshot {
        Snapshot(subscriptions: savedSubscriptions, articles: savedArticles, bookmarkedIDs: savedBookmarks)
    }

    private func takeOldRead(_ part: ReadPart) -> HeldSnapshot? {
        guard let held, pendingOldReadParts.remove(part) != nil else { return nil }
        if pendingOldReadParts.isEmpty { held.ticket.started.signal() }
        return held
    }

    private func waitForOldRead(_ old: HeldSnapshot) async throws {
        let released = await old.ticket.release.wait(timeout: 5)
        if !released { oldReadTimedOut = true; throw FeedError.unavailable }
    }

    func subscriptions() async throws -> [FeedSubscription] {
        if let old = takeOldRead(.subscriptions) {
            try await waitForOldRead(old)
            return old.value.subscriptions
        }
        if nextReloadFails { nextReloadFails = false; throw FeedError.unavailable }
        return savedSubscriptions
    }

    func articles(feedID: String?, limit: Int) async throws -> [FeedArticle] {
        if let old = takeOldRead(.articles) {
            try await waitForOldRead(old)
            return Array(old.value.articles.filter { feedID == nil || $0.feedID == feedID }.prefix(limit))
        }
        return Array(savedArticles.filter { feedID == nil || $0.feedID == feedID }.prefix(limit))
    }

    func bookmarkedArticles(limit: Int) async throws -> [FeedArticle] {
        if let old = takeOldRead(.bookmarks) {
            try await waitForOldRead(old)
            return Array(old.value.articles.filter { old.value.bookmarkedIDs.contains($0.id) }.prefix(limit))
        }
        return Array(savedArticles.filter { savedBookmarks.contains($0.id) }.prefix(limit))
    }

    func isBookmarked(articleID: String) throws -> Bool {
        if bookmarkReadFails { throw FeedError.unavailable }
        return savedBookmarks.contains(articleID)
    }

    func setBookmarked(articleID: String, bookmarked: Bool) throws -> BookmarkMutationResult {
        mutationValues.append(bookmarked)
        guard let article = savedArticles.first(where: { $0.id == articleID }) else {
            if bookmarked { throw FeedError.articleNotFound }
            return .articleDeleted
        }
        if bookmarked { savedBookmarks.insert(articleID) }
        else {
            savedBookmarks.remove(articleID)
            if !savedSubscriptions.contains(where: { $0.id == article.feedID }) {
                savedArticles.removeAll { $0.id == articleID }
                translations[articleID] = nil
            }
        }
        if failAfterBookmark { failAfterBookmark = false; nextReloadFails = true }
        return savedArticles.contains(where: { $0.id == articleID }) ? .articleRetained : .articleDeleted
    }

    func addSubscription(url: URL, title: String?) throws -> FeedSubscription {
        let value = try FeedSubscription(url: url, title: title)
        if !savedSubscriptions.contains(where: { $0.id == value.id }) { savedSubscriptions.append(value) }
        return value
    }

    func removeSubscription(id: String) -> SubscriptionRemovalResult {
        let affected = Set(savedArticles.filter { $0.feedID == id }.map(\.id))
        let retained = affected.intersection(savedBookmarks)
        savedSubscriptions.removeAll { $0.id == id }
        let deleted = affected.subtracting(retained)
        savedArticles.removeAll { deleted.contains($0.id) }
        for id in deleted { translations[id] = nil }
        return SubscriptionRemovalResult(retainedArticleIDs: retained, deletedArticleIDs: deleted)
    }

    func saveFetchedFeedIfSubscribed(_ feed: ParsedFeed, eTag: String?, lastModified: String?) -> Bool {
        guard savedSubscriptions.contains(where: { $0.id == feed.id }) else { return false }
        let IDs = Set(feed.articles.map(\.id))
        savedArticles.removeAll { IDs.contains($0.id) }
        savedArticles.append(contentsOf: feed.articles)
        return true
    }

    func translation(articleID: String, targetLanguage: String) throws -> ArticleTranslation? {
        guard let article = savedArticles.first(where: { $0.id == articleID }) else { throw FeedError.articleNotFound }
        guard let value = translations[articleID], value.targetLanguage == targetLanguage,
              value.sourceFingerprint == article.sourceFingerprint else { return nil }
        return value
    }

    func saveTranslation(_ translation: ArticleTranslation) throws {
        guard let article = savedArticles.first(where: { $0.id == translation.articleID }) else { throw FeedError.articleNotFound }
        guard translation.sourceFingerprint == article.sourceFingerprint else { throw FeedError.staleTranslation }
        translations[article.id] = translation
    }
}

// Additional authoritative cache refresh error regressions
// Append only this marker and the following declarations to the repository test file.
// The four original tests/helpers above may have host-side improvements; do not replace them.
// Current API assumption: searchFailed distinguishes a genuine search error from zero matches.
// These tests require old search snapshots to be invalidated by authoritative cache changes,
// even if the replacement search cannot finish successfully. No build/tests run here.

extension NativeSearchIndependentRegressionTests {
    func testAuthoritativeEmptyCacheClearsDeletedSearchHitEvenWhenReplacementSearchFails() async throws {
        let fixture = try NativeSearchIndependentFixture()
        let directory = nativeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FeedLibraryStore(directory: directory)
        try await store.saveFetchedFeed(fixture.feed(articles: [fixture.article]))
        try await store.saveTranslation(fixture.translation)
        let otherStore = try FeedLibraryStore(directory: directory)
        let searcher = NativeSearchIndependentForwardingSearcher(store: store)
        let model = FeedReaderModel(store: store, fetcher: NativeSearchIndependentUnchangedFetcher(),
                                    searcher: searcher, searchDebounce: .zero)
        await model.initialize()
        model.searchText = "旧文書固定検索印"
        let initialCompleted = await nativeWaitForSearchCompletion(model)
        XCTAssertTrue(initialCompleted)
        XCTAssertFalse(model.searchFailed)
        XCTAssertEqual(model.searchResults.map(\.article.id), [fixture.article.id])
        XCTAssertEqual(model.searchResults.first?.translation, fixture.translation)
        model.selectedArticleID = fixture.article.id
        XCTAssertEqual(model.selectedArticle, fixture.article)

        // The cache read remains healthy and authoritative. Only the search relay
        // fails, after another real store has committed the last feed/article deletion.
        try await otherStore.removeSubscription(id: fixture.subscription.id)
        let persistedSubscriptions = try await store.subscriptions()
        let persistedArticles = try await store.articles()
        XCTAssertTrue(persistedSubscriptions.isEmpty)
        XCTAssertTrue(persistedArticles.isEmpty)
        let failedRequestStarted = await searcher.setFailure(true)
        await model.refresh()
        let replacementAttempted = await failedRequestStarted.wait(timeout: 2)
        let replacementCompleted = await nativeWaitForSearchCompletion(model)

        XCTAssertTrue(replacementAttempted, "The refresh must attempt a new search even with an empty fetch target list")
        XCTAssertTrue(replacementCompleted)
        XCTAssertTrue(model.searchFailed, "A relay error must remain distinguishable from a successful zero-hit result")
        XCTAssertTrue(model.subscriptions.isEmpty)
        XCTAssertTrue(model.articles.isEmpty, "The authoritative cache reload must have completed successfully")
        XCTAssertTrue(model.searchResults.isEmpty, "A search error must not resurrect a definitively deleted cached article")
        XCTAssertTrue(model.visibleArticles.isEmpty)
        XCTAssertNil(model.selectedArticleID)
        XCTAssertNil(model.selectedArticle)
        model.searchText = ""
    }

    func testAuthoritativeNewSourceInvalidatesOldHitAndJapaneseCacheWhenReplacementSearchFails() async throws {
        let fixture = try NativeSearchIndependentFixture()
        let directory = nativeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FeedLibraryStore(directory: directory)
        try await store.saveFetchedFeed(fixture.feed(articles: [fixture.article]))
        try await store.saveTranslation(fixture.translation)
        let otherStore = try FeedLibraryStore(directory: directory)
        let searcher = NativeSearchIndependentForwardingSearcher(store: store)
        let model = FeedReaderModel(store: store, fetcher: NativeSearchIndependentUnchangedFetcher(),
                                    searcher: searcher, searchDebounce: .zero)
        await model.initialize()
        model.searchText = "旧文書固定検索印"
        let initialCompleted = await nativeWaitForSearchCompletion(model)
        XCTAssertTrue(initialCompleted)
        XCTAssertFalse(model.searchFailed)
        XCTAssertEqual(model.searchResults.map(\.article), [fixture.article])
        XCTAssertEqual(model.searchResults.first?.translation, fixture.translation)
        model.selectedArticleID = fixture.article.id
        XCTAssertEqual(model.selectedArticle, fixture.article)

        // Preserve article identity, change the actual source, and leave the old ja
        // row stale. The healthy cache reader can prove the source fingerprint changed.
        try await otherStore.saveFetchedFeed(fixture.feed(articles: [fixture.updatedArticle]))
        let authoritativeArticles = try await store.articles()
        let authoritativeArticle = authoritativeArticles.first { $0.id == fixture.article.id }
        let authoritativeTranslation = try await store.translation(articleID: fixture.article.id, targetLanguage: "ja")
        XCTAssertEqual(authoritativeArticle, fixture.updatedArticle)
        XCTAssertNotEqual(authoritativeArticle?.sourceFingerprint, fixture.article.sourceFingerprint)
        XCTAssertNil(authoritativeTranslation)
        let failedRequestStarted = await searcher.setFailure(true)
        await model.refresh()
        let replacementAttempted = await failedRequestStarted.wait(timeout: 2)
        let replacementCompleted = await nativeWaitForSearchCompletion(model)
        let displayedOldTranslation = try await model.cachedTranslation(for: TranslationSnapshot(article: fixture.article))

        XCTAssertTrue(replacementAttempted)
        XCTAssertTrue(replacementCompleted)
        XCTAssertTrue(model.searchFailed)
        XCTAssertEqual(model.articles.first { $0.id == fixture.article.id }, fixture.updatedArticle)
        XCTAssertTrue(model.searchResults.isEmpty, "The old query no longer matches the authoritative source; a relay failure cannot keep the old snapshot valid")
        XCTAssertTrue(model.visibleArticles.isEmpty)
        XCTAssertNil(model.selectedArticleID)
        XCTAssertNil(model.selectedArticle)
        XCTAssertNil(displayedOldTranslation, "An old search result must not bypass source-fingerprint invalidation and return stale Japanese text")
        model.searchText = ""
    }
}

private actor NativeSearchIndependentForwardingSearcher: ArticleSearching {
    private let store: FeedLibraryStore
    private var failing = false
    private var failureStarted: NativeSearchIndependentLatch?

    init(store: FeedLibraryStore) { self.store = store }

    @discardableResult
    func setFailure(_ value: Bool) -> NativeSearchIndependentLatch {
        failing = value
        let signal = NativeSearchIndependentLatch()
        failureStarted = signal
        return signal
    }

    func searchArticles(_ request: ArticleSearchRequest) async throws -> ArticleSearchPage {
        if failing {
            failureStarted?.signal()
            throw ArticleSearchError.unavailable
        }
        return try await store.searchArticles(request)
    }
}
