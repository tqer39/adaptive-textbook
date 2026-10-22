import Foundation

/// The durable operations used by the information-collection UI.
public protocol FeedLibraryStoring: Sendable {
    func subscriptions() async throws -> [FeedSubscription]
    func addSubscription(url: URL, title: String?) async throws -> FeedSubscription
    @discardableResult func removeSubscription(id: String) async throws -> SubscriptionRemovalResult
    func saveFetchedFeedIfSubscribed(_ feed: ParsedFeed, eTag: String?, lastModified: String?) async throws -> Bool
    func articles(feedID: String?, limit: Int) async throws -> [FeedArticle]
    func bookmarkedArticles(limit: Int) async throws -> [FeedArticle]
    func isBookmarked(articleID: String) async throws -> Bool
    func setBookmarked(articleID: String, bookmarked: Bool) async throws -> BookmarkMutationResult
    func translation(articleID: String, targetLanguage: String) async throws -> ArticleTranslation?
    func saveTranslation(_ translation: ArticleTranslation) async throws
}

extension FeedLibraryStore: FeedLibraryStoring {}

public protocol FeedFetching: Sendable {
    func fetch(_ subscription: FeedSubscription) async throws -> FeedFetchResult
}

extension FeedHTTPClient: FeedFetching {}
