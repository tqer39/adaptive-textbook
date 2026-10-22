import Foundation
import XCTest
import TextbookCore
@testable import TextbookUI

@MainActor
final class SubscriptionRemovalIndependentRegressionTests: XCTestCase {
    func testCommittedRemovalReconcilesArticlesAndSelectionWhenEveryReloadFails() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let failingStore = SubscriptionRemovalFailureStore(store: fixture.store)
        let model = FeedReaderModel(store: failingStore, fetcher: SubscriptionRemovalUnchangedFetcher())
        await model.initialize()
        model.selectedArticleID = fixture.unsavedArticle.id
        let otherFeedFailure = "Other feed failure must remain visible"
        model.failureByFeed[fixture.otherSubscription.id] = otherFeedFailure

        XCTAssertEqual(model.selectedArticle, fixture.unsavedArticle)
        XCTAssertEqual(Set(model.articles.map(\.id)), fixture.allArticleIDs)

        await model.remove(fixture.removedSubscription)

        // The real Core transaction has committed before the wrapper starts
        // rejecting reads. These checks distinguish a stale UI from a failed delete.
        let persistedSubscriptions = try await fixture.store.subscriptions()
        let persistedArticles = try await fixture.store.articles()
        let persistedBookmarks = try await fixture.store.bookmarkedArticles()
        let savedTranslation = try await fixture.store.translation(
            articleID: fixture.savedArticle.id, targetLanguage: "ja"
        )
        XCTAssertEqual(persistedSubscriptions, [fixture.otherSubscription])
        XCTAssertEqual(Set(persistedArticles.map(\.id)), fixture.retainedArticleIDs)
        XCTAssertEqual(Set(persistedBookmarks.map(\.id)), fixture.retainedArticleIDs)
        XCTAssertEqual(savedTranslation, fixture.savedTranslation)
        let failedReadCount = await failingStore.failedReadCount
        XCTAssertGreaterThan(failedReadCount, 0, "The post-COMMIT cache read must actually fail")

        XCTAssertEqual(model.subscriptions, [fixture.otherSubscription])
        XCTAssertEqual(Set(model.articles.map(\.id)), fixture.retainedArticleIDs)
        XCTAssertEqual(Set(model.visibleArticles.map(\.id)), fixture.retainedArticleIDs)
        XCTAssertNil(model.selectedArticleID)
        XCTAssertNil(model.selectedArticle)
        XCTAssertEqual(model.bookmarkState(for: fixture.savedArticle), true)
        XCTAssertEqual(model.bookmarkState(for: fixture.otherArticle), true)
        XCTAssertEqual(model.failureByFeed[fixture.otherSubscription.id], otherFeedFailure)
        assertCommittedRemovalWithReloadFailure(model)

        model.showsBookmarksOnly = true
        XCTAssertEqual(Set(model.visibleArticles.map(\.id)), fixture.retainedArticleIDs)
        model.showsBookmarksOnly = false
        model.selectedFeedID = fixture.otherSubscription.id
        model.selectedArticleID = fixture.otherArticle.id
        XCTAssertEqual(model.visibleArticles, [fixture.otherArticle])
        XCTAssertEqual(model.selectedArticle, fixture.otherArticle)
    }

    func testBookmarkAddedByAnotherConnectionBeforeRemovalSurvivesFailedReload() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let failingStore = SubscriptionRemovalFailureStore(store: fixture.store)
        let model = FeedReaderModel(store: failingStore, fetcher: SubscriptionRemovalUnchangedFetcher())
        await model.initialize()
        model.selectedArticleID = fixture.unsavedArticle.id
        XCTAssertEqual(model.bookmarkState(for: fixture.unsavedArticle), false)

        // Core removes only articles that are unbookmarked in its transaction.
        // A cached false value cannot prove that this article will be deleted.
        let otherConnection = try FeedLibraryStore(directory: fixture.directory)
        try await otherConnection.setBookmarked(articleID: fixture.unsavedArticle.id, bookmarked: true)
        await model.remove(fixture.removedSubscription)

        let persistedArticles = try await fixture.store.articles()
        let persistedBookmark = try await fixture.store.isBookmarked(articleID: fixture.unsavedArticle.id)
        XCTAssertEqual(Set(persistedArticles.map(\.id)), fixture.allArticleIDs)
        XCTAssertTrue(persistedBookmark)
        XCTAssertEqual(Set(model.articles.map(\.id)), fixture.allArticleIDs)
        XCTAssertEqual(model.selectedArticleID, fixture.unsavedArticle.id)
        XCTAssertEqual(model.selectedArticle, fixture.unsavedArticle)
        XCTAssertEqual(model.bookmarkState(for: fixture.unsavedArticle), true)
        XCTAssertEqual(model.subscriptions, [fixture.otherSubscription])
        assertCommittedRemovalWithReloadFailure(model)

        model.showsBookmarksOnly = true
        XCTAssertEqual(Set(model.visibleArticles.map(\.id)), fixture.allArticleIDs)
    }

    func testBookmarkRemovedByAnotherConnectionBeforeRemovalCannotRetainDeletedArticle() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let failingStore = SubscriptionRemovalFailureStore(store: fixture.store)
        let model = FeedReaderModel(store: failingStore, fetcher: SubscriptionRemovalUnchangedFetcher())
        await model.initialize()
        model.selectedArticleID = fixture.savedArticle.id
        XCTAssertEqual(model.bookmarkState(for: fixture.savedArticle), true)

        // This is the opposite stale-cache boundary: keeping every locally
        // bookmarked article would retain a snapshot that Core actually deletes.
        let otherConnection = try FeedLibraryStore(directory: fixture.directory)
        try await otherConnection.setBookmarked(articleID: fixture.savedArticle.id, bookmarked: false)
        await model.remove(fixture.removedSubscription)

        let persistedArticles = try await fixture.store.articles()
        let persistedBookmarks = try await fixture.store.bookmarkedArticles()
        XCTAssertEqual(persistedArticles, [fixture.otherArticle])
        XCTAssertEqual(persistedBookmarks, [fixture.otherArticle])
        XCTAssertEqual(model.articles, [fixture.otherArticle])
        XCTAssertEqual(model.visibleArticles, [fixture.otherArticle])
        XCTAssertNil(model.selectedArticleID)
        XCTAssertNil(model.selectedArticle)
        XCTAssertFalse(model.bookmarkedIDs.contains(fixture.savedArticle.id))
        XCTAssertEqual(model.bookmarkState(for: fixture.otherArticle), true)
        XCTAssertEqual(model.subscriptions, [fixture.otherSubscription])
        assertCommittedRemovalWithReloadFailure(model)
    }

    func testRefusedRemovalPreservesDataAndIsNeverReportedAsCommitted() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let refusingStore = SubscriptionRemovalFailureStore(store: fixture.store, refusesRemoval: true)
        let model = FeedReaderModel(store: refusingStore, fetcher: SubscriptionRemovalUnchangedFetcher())
        await model.initialize()
        model.selectedArticleID = fixture.unsavedArticle.id
        let subscriptionsBefore = model.subscriptions

        await model.remove(fixture.removedSubscription)

        let persistedSubscriptions = try await fixture.store.subscriptions()
        let persistedArticles = try await fixture.store.articles()
        let persistedBookmarks = try await fixture.store.bookmarkedArticles()
        XCTAssertEqual(persistedSubscriptions, subscriptionsBefore)
        XCTAssertEqual(Set(persistedArticles.map(\.id)), fixture.allArticleIDs)
        XCTAssertEqual(Set(persistedBookmarks.map(\.id)), fixture.retainedArticleIDs)
        XCTAssertEqual(model.subscriptions, subscriptionsBefore)
        XCTAssertEqual(Set(model.articles.map(\.id)), fixture.allArticleIDs)
        XCTAssertEqual(model.selectedArticleID, fixture.unsavedArticle.id)
        XCTAssertEqual(model.selectedArticle, fixture.unsavedArticle)
        XCTAssertTrue(model.message.contains("購読を削除できませんでした"))
        XCTAssertTrue(model.message.contains(SubscriptionRemovalInjectedError.removalRefused.localizedDescription))
        XCTAssertFalse(model.message.contains("購読を削除しました"))
        let failedReadCount = await refusingStore.failedReadCount
        XCTAssertEqual(failedReadCount, 0, "The failure control must refuse the mutation, not the reload")
    }

    func testAlreadyRemovedSubscriptionWithEmptyReceiptClearsStaleArticleAndSelectionAfterReloadFailure() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let alreadyRemovedSubscription = try FeedSubscription(
            url: URL(string: "https://already-removed.independent.example/feed")!, title: "Already removed feed"
        )
        let staleArticle = FeedArticle(
            id: "removal-already-absent", feedID: alreadyRemovedSubscription.id,
            title: "Stale unbookmarked article", url: nil, content: "Another scene deletes this snapshot."
        )
        try await fixture.store.saveFetchedFeed(ParsedFeed(
            id: alreadyRemovedSubscription.id, sourceURL: alreadyRemovedSubscription.url,
            title: alreadyRemovedSubscription.title!, articles: [staleArticle]
        ))
        let failingStore = SubscriptionRemovalFailureStore(store: fixture.store)
        let model = FeedReaderModel(store: failingStore, fetcher: SubscriptionRemovalUnchangedFetcher())
        await model.initialize()
        model.selectedArticleID = staleArticle.id
        XCTAssertEqual(model.selectedArticle, staleArticle)

        let otherConnection = try FeedLibraryStore(directory: fixture.directory)
        let firstRemoval = try await otherConnection.removeSubscription(id: alreadyRemovedSubscription.id)
        XCTAssertEqual(firstRemoval.deletedArticleIDs, [staleArticle.id])
        XCTAssertTrue(firstRemoval.retainedArticleIDs.isEmpty)
        // A repeated deletion has no affected rows. The model's subsequent
        // deletion sees this same empty Core state, while its cache remains stale.
        let emptyReceipt = try await otherConnection.removeSubscription(id: alreadyRemovedSubscription.id)
        XCTAssertTrue(emptyReceipt.deletedArticleIDs.isEmpty)
        XCTAssertTrue(emptyReceipt.retainedArticleIDs.isEmpty)
        XCTAssertEqual(model.selectedArticle, staleArticle)

        await model.remove(alreadyRemovedSubscription)

        let persistedSubscriptions = try await fixture.store.subscriptions()
        let persistedArticles = try await fixture.store.articles()
        let persistedBookmarks = try await fixture.store.bookmarkedArticles()
        let savedTranslation = try await fixture.store.translation(
            articleID: fixture.savedArticle.id, targetLanguage: "ja"
        )
        let expectedSubscriptionIDs: Set<String> = [fixture.removedSubscription.id, fixture.otherSubscription.id]
        XCTAssertEqual(Set(persistedSubscriptions.map(\.id)), expectedSubscriptionIDs)
        XCTAssertEqual(Set(persistedArticles.map(\.id)), fixture.allArticleIDs)
        XCTAssertEqual(Set(persistedBookmarks.map(\.id)), fixture.retainedArticleIDs)
        XCTAssertEqual(savedTranslation, fixture.savedTranslation)
        let failedReadCount = await failingStore.failedReadCount
        XCTAssertGreaterThan(failedReadCount, 0)

        XCTAssertEqual(Set(model.subscriptions.map(\.id)), expectedSubscriptionIDs)
        XCTAssertEqual(Set(model.articles.map(\.id)), fixture.allArticleIDs)
        XCTAssertEqual(Set(model.visibleArticles.map(\.id)), fixture.allArticleIDs)
        XCTAssertNil(model.selectedArticleID)
        XCTAssertNil(model.selectedArticle)
        XCTAssertEqual(model.bookmarkState(for: fixture.savedArticle), true)
        XCTAssertEqual(model.bookmarkState(for: fixture.otherArticle), true)
        assertCommittedRemovalWithReloadFailure(model)
    }

    func testAlreadyRemovedSubscriptionWithRetainedBookmarksClearsStaleArticleAndSelectionAfterReloadFailure() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let failingStore = SubscriptionRemovalFailureStore(store: fixture.store)
        let model = FeedReaderModel(store: failingStore, fetcher: SubscriptionRemovalUnchangedFetcher())
        await model.initialize()
        model.selectedArticleID = fixture.unsavedArticle.id
        XCTAssertEqual(model.selectedArticle, fixture.unsavedArticle)

        let otherConnection = try FeedLibraryStore(directory: fixture.directory)
        let firstRemoval = try await otherConnection.removeSubscription(id: fixture.removedSubscription.id)
        XCTAssertEqual(firstRemoval.deletedArticleIDs, [fixture.unsavedArticle.id])
        XCTAssertEqual(firstRemoval.retainedArticleIDs, [fixture.savedArticle.id])
        let retainedOnlyReceipt = try await otherConnection.removeSubscription(id: fixture.removedSubscription.id)
        XCTAssertTrue(retainedOnlyReceipt.deletedArticleIDs.isEmpty)
        XCTAssertEqual(retainedOnlyReceipt.retainedArticleIDs, [fixture.savedArticle.id])
        XCTAssertEqual(model.selectedArticle, fixture.unsavedArticle)

        await model.remove(fixture.removedSubscription)

        let persistedSubscriptions = try await fixture.store.subscriptions()
        let persistedArticles = try await fixture.store.articles()
        let persistedBookmarks = try await fixture.store.bookmarkedArticles()
        let savedTranslation = try await fixture.store.translation(
            articleID: fixture.savedArticle.id, targetLanguage: "ja"
        )
        XCTAssertEqual(persistedSubscriptions, [fixture.otherSubscription])
        XCTAssertEqual(Set(persistedArticles.map(\.id)), fixture.retainedArticleIDs)
        XCTAssertEqual(Set(persistedBookmarks.map(\.id)), fixture.retainedArticleIDs)
        XCTAssertEqual(savedTranslation, fixture.savedTranslation)
        let failedReadCount = await failingStore.failedReadCount
        XCTAssertGreaterThan(failedReadCount, 0)

        XCTAssertEqual(model.subscriptions, [fixture.otherSubscription])
        XCTAssertEqual(Set(model.articles.map(\.id)), fixture.retainedArticleIDs)
        XCTAssertEqual(Set(model.visibleArticles.map(\.id)), fixture.retainedArticleIDs)
        XCTAssertNil(model.selectedArticleID)
        XCTAssertNil(model.selectedArticle)
        XCTAssertEqual(model.bookmarkState(for: fixture.savedArticle), true)
        XCTAssertEqual(model.bookmarkState(for: fixture.otherArticle), true)
        assertCommittedRemovalWithReloadFailure(model)
    }

    private func assertCommittedRemovalWithReloadFailure(
        _ model: FeedReaderModel, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertTrue(model.message.contains("購読を削除しました"), file: file, line: line)
        XCTAssertTrue(model.message.contains("再読み込み"), file: file, line: line)
        XCTAssertTrue(
            model.message.contains(SubscriptionRemovalInjectedError.reloadUnavailable.localizedDescription),
            file: file, line: line
        )
        XCTAssertFalse(model.message.contains("購読を削除できませんでした"), file: file, line: line)
    }

    private func makeFixture() async throws -> SubscriptionRemovalFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("subscription-removal-independent-" + UUID().uuidString, isDirectory: true)
        do {
            let store = try FeedLibraryStore(directory: directory)
            let removedSubscription = try FeedSubscription(
                url: URL(string: "https://remove.independent.example/feed")!, title: "Removed feed"
            )
            let otherSubscription = try FeedSubscription(
                url: URL(string: "https://other.independent.example/feed")!, title: "Other feed"
            )
            let unsavedArticle = FeedArticle(
                id: "removal-unsaved", feedID: removedSubscription.id, title: "Unsaved article",
                url: nil, content: "This snapshot must disappear after removal."
            )
            let savedArticle = FeedArticle(
                id: "removal-saved", feedID: removedSubscription.id, title: "Saved article",
                url: nil, content: "This bookmarked snapshot must remain."
            )
            let otherArticle = FeedArticle(
                id: "removal-other", feedID: otherSubscription.id, title: "Other article",
                url: nil, content: "Another feed must remain unchanged."
            )
            try await store.saveFetchedFeed(ParsedFeed(
                id: removedSubscription.id, sourceURL: removedSubscription.url,
                title: removedSubscription.title!, articles: [unsavedArticle, savedArticle]
            ))
            try await store.saveFetchedFeed(ParsedFeed(
                id: otherSubscription.id, sourceURL: otherSubscription.url,
                title: otherSubscription.title!, articles: [otherArticle]
            ))
            try await store.setBookmarked(articleID: savedArticle.id, bookmarked: true)
            try await store.setBookmarked(articleID: otherArticle.id, bookmarked: true)
            let savedTranslation = ArticleTranslation(
                articleID: savedArticle.id, sourceFingerprint: savedArticle.sourceFingerprint,
                targetLanguage: "ja", title: "保存済み記事", body: "購読削除後も保持する日本語訳。"
            )
            try await store.saveTranslation(savedTranslation)
            return SubscriptionRemovalFixture(
                directory: directory, store: store, removedSubscription: removedSubscription,
                otherSubscription: otherSubscription, unsavedArticle: unsavedArticle,
                savedArticle: savedArticle, otherArticle: otherArticle, savedTranslation: savedTranslation
            )
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}

private struct SubscriptionRemovalFixture {
    let directory: URL
    let store: FeedLibraryStore
    let removedSubscription: FeedSubscription
    let otherSubscription: FeedSubscription
    let unsavedArticle: FeedArticle
    let savedArticle: FeedArticle
    let otherArticle: FeedArticle
    let savedTranslation: ArticleTranslation

    var allArticleIDs: Set<String> { [unsavedArticle.id, savedArticle.id, otherArticle.id] }
    var retainedArticleIDs: Set<String> { [savedArticle.id, otherArticle.id] }
}

private struct SubscriptionRemovalUnchangedFetcher: FeedFetching {
    func fetch(_ subscription: FeedSubscription) async throws -> FeedFetchResult { .notModified }
}

private enum SubscriptionRemovalInjectedError: Error, LocalizedError {
    case reloadUnavailable
    case removalRefused

    var errorDescription: String? {
        switch self {
        case .reloadUnavailable: "independent-reload-failure-after-removal"
        case .removalRefused: "independent-removal-refused-before-mutation"
        }
    }
}

private actor SubscriptionRemovalFailureStore: FeedLibraryStoring {
    private let store: FeedLibraryStore
    private let refusesRemoval: Bool
    private var rejectsReloads = false
    private(set) var failedReadCount = 0

    init(store: FeedLibraryStore, refusesRemoval: Bool = false) {
        self.store = store
        self.refusesRemoval = refusesRemoval
    }

    func subscriptions() async throws -> [FeedSubscription] {
        try failReloadIfArmed()
        return try await store.subscriptions()
    }

    func articles(feedID: String?, limit: Int) async throws -> [FeedArticle] {
        try failReloadIfArmed()
        return try await store.articles(feedID: feedID, limit: limit)
    }

    func bookmarkedArticles(limit: Int) async throws -> [FeedArticle] {
        try failReloadIfArmed()
        return try await store.bookmarkedArticles(limit: limit)
    }

    func addSubscription(url: URL, title: String?) async throws -> FeedSubscription {
        try await store.addSubscription(url: url, title: title)
    }

    func removeSubscription(id: String) async throws -> SubscriptionRemovalResult {
        if refusesRemoval { throw SubscriptionRemovalInjectedError.removalRefused }
        let result = try await store.removeSubscription(id: id)
        // Arming only after the real operation returns proves that every
        // injected read failure follows a successful Core COMMIT.
        rejectsReloads = true
        return result
    }

    func saveFetchedFeedIfSubscribed(
        _ feed: ParsedFeed, eTag: String?, lastModified: String?
    ) async throws -> Bool {
        try await store.saveFetchedFeedIfSubscribed(feed, eTag: eTag, lastModified: lastModified)
    }

    func isBookmarked(articleID: String) async throws -> Bool {
        try failReloadIfArmed()
        return try await store.isBookmarked(articleID: articleID)
    }

    func setBookmarked(articleID: String, bookmarked: Bool) async throws -> BookmarkMutationResult {
        try await store.setBookmarked(articleID: articleID, bookmarked: bookmarked)
    }

    func translation(articleID: String, targetLanguage: String) async throws -> ArticleTranslation? {
        try failReloadIfArmed()
        return try await store.translation(articleID: articleID, targetLanguage: targetLanguage)
    }

    func saveTranslation(_ translation: ArticleTranslation) async throws {
        try await store.saveTranslation(translation)
    }

    private func failReloadIfArmed() throws {
        guard rejectsReloads else { return }
        failedReadCount += 1
        throw SubscriptionRemovalInjectedError.reloadUnavailable
    }
}
