import XCTest
import Combine
import TextbookCore
@testable import TextbookUI

@MainActor
final class FeedReaderSearchTests: XCTestCase {
    func testInitializationRestartUsesANewIdentityForTheSameQuery() async throws {
        let searcher = ControlledArticleSearcher()
        let store = InitializationGatedStore()
        let model = FeedReaderModel(
            store: store, fetcher: InitializationUnchangedFetcher(),
            searcher: searcher, searchDebounce: .zero
        )

        model.searchText = "同じ検索語"
        let beforeInitialization = await searcher.nextRequest()
        let initialization = Task { await model.initialize() }
        await store.waitUntilInitialCacheReadStarts()
        await store.releaseInitialCacheRead()
        await initialization.value
        let afterEmptyRefresh = await searcher.nextRequest()

        await searcher.succeed(afterEmptyRefresh.id, page: page("current", cursor: 30))
        await waitForResults(model, ids: ["current"])
        await searcher.succeed(beforeInitialization.id, page: page("stale-before-init", cursor: 10))
        await settleMainActor()

        XCTAssertEqual(model.searchResults.map(\.article.id), ["current"])
        XCTAssertFalse(model.isSearching)
    }

    func testInvalidQueryFailureIsNotPresentedAsSuccessfulEmptyResults() async throws {
        let searcher = ControlledArticleSearcher()
        let model = FeedReaderModel(searcher: searcher, searchDebounce: .zero)
        model.searchText = String(repeating: "a", count: 129)
        let request = await searcher.nextRequest()
        await searcher.fail(request.id, error: ArticleSearchError.queryTooLong)
        await settleMainActor()

        XCTAssertTrue(model.searchResults.isEmpty)
        XCTAssertTrue(model.searchFailed)
        XCTAssertFalse(model.searchPreparing)
        XCTAssertTrue(model.searchMessage?.contains("検索できませんでした") == true)
        XCTAssertFalse(model.searchMessage?.contains("一致する保存済み記事はありません") == true)
    }

    func testSlowRefreshCannotDowngradeSearchBookmarkOutsideCacheLimit() async throws {
        let subscription = try FeedSubscription(url: URL(string: "https://large-bookmarks.example/feed")!)
        let recent = (0 ..< 2_000).map { index in
            FeedArticle(
                id: "recent-\(index)", feedID: subscription.id, title: "recent \(index)", url: nil,
                publishedAt: Date(timeIntervalSinceReferenceDate: Double(10_000 - index))
            )
        }
        let old = FeedArticle(
            id: "old-authoritative", feedID: subscription.id, title: "old authoritative needle", url: nil,
            publishedAt: Date(timeIntervalSinceReferenceDate: 1)
        )
        let store = LargeBookmarkStore(subscription: subscription, articles: recent + [old])
        let fetcher = GatedUnchangedFetcher()
        let searcher = ControlledArticleSearcher()
        let model = FeedReaderModel(store: store, fetcher: fetcher, searcher: searcher, searchDebounce: .zero)

        let initialization = Task { await model.initialize() }
        await fetcher.waitUntilFetchStarts()
        model.searchText = "authoritative needle"
        let initialSearch = await searcher.nextRequest()
        let page = ArticleSearchPage(results: [ArticleSearchResult(
            article: old, translation: nil, cursor: 1, isBookmarked: true
        )], nextCursor: nil)
        await searcher.succeed(initialSearch.id, page: page)
        await waitForResults(model, ids: [old.id])
        XCTAssertEqual(model.bookmarkState(for: old), true)

        await fetcher.release()
        await initialization.value
        let refreshSearch = await searcher.nextRequest()
        XCTAssertEqual(model.bookmarkState(for: old), true)
        await searcher.succeed(refreshSearch.id, page: page)
        await waitForResults(model, ids: [old.id])
        XCTAssertEqual(model.bookmarkState(for: old), true)
    }

    func testIgnoredCancellationOldSuccessCannotReplaceNewQueryOrClear() async throws {
        let searcher = ControlledArticleSearcher()
        let model = FeedReaderModel(searcher: searcher, searchDebounce: .zero)

        model.searchText = "古い"
        let old = await searcher.nextRequest()
        model.searchText = "新しい"
        let new = await searcher.nextRequest()
        await searcher.succeed(new.id, page: page("new", cursor: 20))
        await waitForResults(model, ids: ["new"])

        await searcher.succeed(old.id, page: page("old", cursor: 10))
        await settleMainActor()
        let idsAfterOld = model.searchResults.map(\.article.id)
        XCTAssertEqual(idsAfterOld, ["new"])

        model.searchText = "clear-me"
        let cleared = await searcher.nextRequest()
        model.searchText = ""
        await searcher.succeed(cleared.id, page: page("ghost", cursor: 30))
        await settleMainActor()
        let clearedIDs = model.searchResults.map(\.article.id)
        XCTAssertTrue(clearedIDs.isEmpty)
        XCTAssertFalse(model.hasSearchQuery)
    }

    func testLateErrorAndOldFilterResponseCannotReplaceCurrentFilter() async throws {
        let searcher = ControlledArticleSearcher()
        let model = FeedReaderModel(searcher: searcher, searchDebounce: .zero)
        model.searchText = "needle"
        let unfiltered = await searcher.nextRequest()
        model.selectedFeedID = "feed-b"
        let filtered = await searcher.nextRequest()
        let capturedFeed = filtered.request.feedID
        XCTAssertEqual(capturedFeed, "feed-b")

        await searcher.succeed(filtered.id, page: page("filtered", feedID: "feed-b", cursor: 40))
        await waitForResults(model, ids: ["filtered"])
        await searcher.fail(unfiltered.id, error: ArticleSearchError.unavailable)
        await settleMainActor()

        let finalIDs = model.searchResults.map(\.article.id)
        let finalMessage = model.searchMessage
        XCTAssertEqual(finalIDs, ["filtered"])
        XCTAssertFalse(finalMessage?.contains("検索できませんでした") == true)
    }

    func testKeysetAppendDeduplicatesAndStopsOnRepeatedCursor() async throws {
        let searcher = ControlledArticleSearcher()
        let model = FeedReaderModel(searcher: searcher, searchDebounce: .zero)
        model.searchText = "page"
        let first = await searcher.nextRequest()
        await searcher.succeed(first.id, page: ArticleSearchPage(
            results: [result("one", cursor: 50), result("two", cursor: 40)], nextCursor: 40
        ))
        await waitForResults(model, ids: ["one", "two"])

        model.loadMoreSearchResults()
        model.loadMoreSearchResults()
        let second = await searcher.nextRequest()
        let capturedBefore = second.request.before
        XCTAssertEqual(capturedBefore, 40)
        await searcher.succeed(second.id, page: ArticleSearchPage(
            results: [result("two", cursor: 40), result("three", cursor: 30)], nextCursor: 40
        ))
        await waitForResults(model, ids: ["one", "two", "three"])

        let finalIDs = model.searchResults.map(\.article.id)
        XCTAssertEqual(finalIDs, ["one", "two", "three"])
        XCTAssertFalse(model.canLoadMoreSearchResults)
        let requestCount = await searcher.requestCount
        XCTAssertEqual(requestCount, 2)
    }

    private func waitForResults(_ model: FeedReaderModel, ids: [String]) async {
        if model.searchResults.map(\.article.id) == ids { return }
        let changed = expectation(description: "search results became \(ids)")
        var cancellable: AnyCancellable?
        cancellable = model.$searchResults.sink { results in
            if results.map(\.article.id) == ids { changed.fulfill() }
        }
        await fulfillment(of: [changed], timeout: 2)
        cancellable?.cancel()
    }

    private func settleMainActor() async {
        for _ in 0 ..< 20 { await Task.yield() }
    }

    private func page(_ id: String, feedID: String = "feed", cursor: Int64) -> ArticleSearchPage {
        ArticleSearchPage(results: [result(id, feedID: feedID, cursor: cursor)], nextCursor: nil)
    }

    private func result(_ id: String, feedID: String = "feed", cursor: Int64) -> ArticleSearchResult {
        ArticleSearchResult(
            article: FeedArticle(id: id, feedID: feedID, title: id, url: nil, content: "body"),
            translation: nil,
            cursor: cursor
        )
    }
}

private struct InitializationUnchangedFetcher: FeedFetching {
    func fetch(_ subscription: FeedSubscription) async throws -> FeedFetchResult { .notModified }
}

private actor InitializationGatedStore: FeedLibraryStoring {
    private var initialReadStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var initialRead: CheckedContinuation<[FeedSubscription], Error>?

    func waitUntilInitialCacheReadStarts() async {
        if initialReadStarted { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func releaseInitialCacheRead() {
        initialRead?.resume(returning: [])
        initialRead = nil
    }

    func subscriptions() async throws -> [FeedSubscription] {
        if initialReadStarted { return [] }
        initialReadStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        return try await withCheckedThrowingContinuation { initialRead = $0 }
    }

    func articles(feedID: String?, limit: Int) async throws -> [FeedArticle] { [] }
    func bookmarkedArticles(limit: Int) async throws -> [FeedArticle] { [] }
    func isBookmarked(articleID: String) async throws -> Bool { false }
    func translation(articleID: String, targetLanguage: String) async throws -> ArticleTranslation? { nil }
    func addSubscription(url: URL, title: String?) async throws -> FeedSubscription { throw FeedError.unavailable }
    func removeSubscription(id: String) async throws -> SubscriptionRemovalResult { throw FeedError.unavailable }
    func saveFetchedFeedIfSubscribed(_ feed: ParsedFeed, eTag: String?, lastModified: String?) async throws -> Bool { false }
    func setBookmarked(articleID: String, bookmarked: Bool) async throws -> BookmarkMutationResult { throw FeedError.unavailable }
    func saveTranslation(_ translation: ArticleTranslation) async throws { throw FeedError.unavailable }
}

private actor GatedUnchangedFetcher: FeedFetching {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func waitUntilFetchStarts() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func fetch(_ subscription: FeedSubscription) async throws -> FeedFetchResult {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { releaseContinuation = $0 }
        return .notModified
    }
}

private actor LargeBookmarkStore: FeedLibraryStoring {
    private let subscription: FeedSubscription
    private let savedArticles: [FeedArticle]

    init(subscription: FeedSubscription, articles: [FeedArticle]) {
        self.subscription = subscription
        savedArticles = articles
    }

    func subscriptions() async throws -> [FeedSubscription] { [subscription] }
    func articles(feedID: String?, limit: Int) async throws -> [FeedArticle] {
        Array(savedArticles.filter { feedID == nil || $0.feedID == feedID }.prefix(limit))
    }
    func bookmarkedArticles(limit: Int) async throws -> [FeedArticle] { Array(savedArticles.prefix(limit)) }
    func isBookmarked(articleID: String) async throws -> Bool { true }
    func translation(articleID: String, targetLanguage: String) async throws -> ArticleTranslation? { nil }
    func addSubscription(url: URL, title: String?) async throws -> FeedSubscription { throw FeedError.unavailable }
    func removeSubscription(id: String) async throws -> SubscriptionRemovalResult { throw FeedError.unavailable }
    func saveFetchedFeedIfSubscribed(_ feed: ParsedFeed, eTag: String?, lastModified: String?) async throws -> Bool { false }
    func setBookmarked(articleID: String, bookmarked: Bool) async throws -> BookmarkMutationResult { .articleRetained }
    func saveTranslation(_ translation: ArticleTranslation) async throws { throw FeedError.unavailable }
}

private actor ControlledArticleSearcher: ArticleSearching {
    struct Ticket: Sendable {
        let id: UUID
        let request: ArticleSearchRequest
    }

    private struct Pending {
        let continuation: CheckedContinuation<ArticleSearchPage, Error>
    }

    private var pending: [UUID: Pending] = [:]
    private var queued: [Ticket] = []
    private var waiters: [CheckedContinuation<Ticket, Never>] = []
    private(set) var requestCount = 0

    func searchArticles(_ request: ArticleSearchRequest) async throws -> ArticleSearchPage {
        let id = UUID()
        requestCount += 1
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = Pending(continuation: continuation)
            let ticket = Ticket(id: id, request: request)
            if waiters.isEmpty {
                queued.append(ticket)
            } else {
                waiters.removeFirst().resume(returning: ticket)
            }
        }
    }

    func nextRequest() async -> Ticket {
        if !queued.isEmpty { return queued.removeFirst() }
        return await withCheckedContinuation { waiters.append($0) }
    }

    func succeed(_ id: UUID, page: ArticleSearchPage) {
        pending.removeValue(forKey: id)?.continuation.resume(returning: page)
    }

    func fail(_ id: UUID, error: Error) {
        pending.removeValue(forKey: id)?.continuation.resume(throwing: error)
    }
}

@MainActor
final class SavedTranslationCacheWorkflowTests: XCTestCase {
    func testOldArticleErrorAfterNewArticleSuccessCannotReplaceNewResult() async throws {
        let loader = CancellationIgnoringTranslationLoader()
        let result = SavedTranslationResultModel()
        let old = snapshot(id: "old", title: "Old")
        let new = snapshot(id: "new", title: "New")
        let oldTask = load(old, into: result, with: loader)
        let oldTicket = try await requireTicket(loader)
        let newTask = load(new, into: result, with: loader)
        let newTicket = try await requireTicket(loader)
        oldTask.cancel()

        await loader.succeed(newTicket, with: translation(for: new, title: "new result"))
        await newTask.value
        await loader.fail(oldTicket, with: .delayedFailure)
        await oldTask.value

        XCTAssertEqual(result.translation?.title, "new result")
        XCTAssertNil(result.message)
        await loader.cleanup()
    }

    func testSameArticleSourceChangeRejectsOldSuccess() async throws {
        let loader = CancellationIgnoringTranslationLoader()
        let result = SavedTranslationResultModel()
        let old = snapshot(id: "same", title: "Original source")
        let updated = snapshot(id: "same", title: "Updated source")
        let oldTask = load(old, into: result, with: loader)
        let oldTicket = try await requireTicket(loader)
        let updatedTask = load(updated, into: result, with: loader)
        let updatedTicket = try await requireTicket(loader)
        oldTask.cancel()

        await loader.succeed(updatedTicket, with: translation(for: updated, title: "updated result"))
        await updatedTask.value
        await loader.succeed(oldTicket, with: translation(for: old, title: "stale result"))
        await oldTask.value

        XCTAssertEqual(result.translation?.sourceFingerprint, updated.sourceFingerprint)
        XCTAssertEqual(result.translation?.title, "updated result")
        await loader.cleanup()
    }

    func testSameSnapshotRetryAndABAIgnoreEarlierSuccessAndError() async throws {
        let loader = CancellationIgnoringTranslationLoader()
        let result = SavedTranslationResultModel()
        let a = snapshot(id: "a", title: "A")
        let b = snapshot(id: "b", title: "B")
        let firstA = load(a, into: result, with: loader)
        let firstATicket = try await requireTicket(loader)
        let middleB = load(b, into: result, with: loader)
        let middleBTicket = try await requireTicket(loader)
        let secondA = load(a, into: result, with: loader)
        let secondATicket = try await requireTicket(loader)
        middleB.cancel()
        let retryA = load(a, into: result, with: loader)
        let retryATicket = try await requireTicket(loader)
        secondA.cancel()

        await loader.succeed(retryATicket, with: translation(for: a, title: "latest A"))
        await retryA.value
        await loader.succeed(secondATicket, with: translation(for: a, title: "stale retry"))
        await secondA.value
        await loader.fail(firstATicket, with: .delayedFailure)
        await firstA.value
        await loader.succeed(middleBTicket, with: translation(for: b, title: "stale B"))
        await middleB.value

        XCTAssertEqual(result.translation?.title, "latest A")
        XCTAssertEqual(result.translation?.articleID, a.articleID)
        XCTAssertNil(result.message)
        await loader.cleanup()
    }

    func testCancelledBeforeStartDoesNotSupersedeActiveLoad() async throws {
        let loader = CancellationIgnoringTranslationLoader()
        let gate = TranslationLoadStartGate()
        let result = SavedTranslationResultModel()
        let active = snapshot(id: "active", title: "Active")
        let cancelled = snapshot(id: "cancelled", title: "Cancelled")
        let activeTask = load(active, into: result, with: loader)
        let activeTicket = try await requireTicket(loader)
        let cancelledTask = Task { @MainActor in
            await gate.wait()
            await result.load(snapshot: cancelled) { try await loader.load($0) }
        }
        await gate.waitUntilSuspended()
        cancelledTask.cancel()
        await gate.release()
        await cancelledTask.value

        let requestCount = await loader.requestCount
        XCTAssertEqual(requestCount, 1)
        await loader.succeed(activeTicket, with: translation(for: active, title: "active result"))
        await activeTask.value
        XCTAssertEqual(result.translation?.title, "active result")
        await loader.cleanup()
    }

    private func load(
        _ snapshot: TranslationSnapshot,
        into result: SavedTranslationResultModel,
        with loader: CancellationIgnoringTranslationLoader
    ) -> Task<Void, Never> {
        Task { @MainActor in
            await result.load(snapshot: snapshot) { try await loader.load($0) }
        }
    }

    private func requireTicket(
        _ loader: CancellationIgnoringTranslationLoader,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> CancellationIgnoringTranslationLoader.Ticket {
        guard let ticket = await loader.nextRequest(timeout: .seconds(2)) else {
            XCTFail("Timed out waiting for cache load", file: file, line: line)
            await loader.cleanup()
            throw CancellationIgnoringTranslationLoader.Failure.watchdog
        }
        return ticket
    }

    private func snapshot(id: String, title: String) -> TranslationSnapshot {
        TranslationSnapshot(article: FeedArticle(
            id: id, feedID: "feed", title: title, url: nil, content: "\(title) body"
        ))
    }

    private func translation(for snapshot: TranslationSnapshot, title: String) -> ArticleTranslation {
        ArticleTranslation(
            articleID: snapshot.articleID, sourceFingerprint: snapshot.sourceFingerprint,
            targetLanguage: "ja", title: title, body: "body"
        )
    }
}

private actor CancellationIgnoringTranslationLoader {
    enum Failure: Error, LocalizedError, Sendable {
        case delayedFailure
        case watchdog

        var errorDescription: String? {
            switch self {
            case .delayedFailure: "delayed cache failure"
            case .watchdog: "cache test watchdog expired"
            }
        }
    }

    struct Ticket: Sendable {
        let id: UUID
        let snapshot: TranslationSnapshot
    }

    private struct Waiter {
        let continuation: CheckedContinuation<Ticket?, Never>
        let watchdog: Task<Void, Never>
    }

    private var pending: [UUID: CheckedContinuation<ArticleTranslation?, Error>] = [:]
    private var queued: [Ticket] = []
    private var waiters: [UUID: Waiter] = [:]
    private(set) var requestCount = 0

    func load(_ snapshot: TranslationSnapshot) async throws -> ArticleTranslation? {
        let id = UUID()
        requestCount += 1
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            let ticket = Ticket(id: id, snapshot: snapshot)
            if let waiter = waiters.first {
                let removed = waiters.removeValue(forKey: waiter.key)
                removed?.watchdog.cancel()
                removed?.continuation.resume(returning: ticket)
            } else {
                queued.append(ticket)
            }
        }
    }

    func nextRequest(timeout: Duration) async -> Ticket? {
        if !queued.isEmpty { return queued.removeFirst() }
        let id = UUID()
        return await withCheckedContinuation { continuation in
            let watchdog = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                await self?.expireWaiter(id)
            }
            waiters[id] = Waiter(continuation: continuation, watchdog: watchdog)
        }
    }

    func succeed(_ ticket: Ticket, with value: ArticleTranslation?) {
        pending.removeValue(forKey: ticket.id)?.resume(returning: value)
    }

    func fail(_ ticket: Ticket, with error: Failure) {
        pending.removeValue(forKey: ticket.id)?.resume(throwing: error)
    }

    func cleanup() {
        for continuation in pending.values { continuation.resume(throwing: CancellationError()) }
        pending.removeAll()
        for waiter in waiters.values {
            waiter.watchdog.cancel()
            waiter.continuation.resume(returning: nil)
        }
        waiters.removeAll()
        queued.removeAll()
    }

    private func expireWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.continuation.resume(returning: nil)
    }
}

private actor TranslationLoadStartGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var suspendedWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            let waiters = suspendedWaiters
            suspendedWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }

    func waitUntilSuspended() async {
        if continuation != nil { return }
        await withCheckedContinuation { suspendedWaiters.append($0) }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
