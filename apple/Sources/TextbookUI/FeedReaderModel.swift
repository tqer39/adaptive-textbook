import SwiftUI
import TextbookCore

enum FeedRefreshPhase: String, Sendable {
    case queued = "待機中"
    case fetching = "取得中"
    case updated = "保存完了"
    case unchanged = "変更なし"
    case failed = "更新失敗"
    case cancelled = "中止"

    var isPending: Bool { self == .queued || self == .fetching }
}

private struct FeedRefreshCompletion: Sendable {
    let subscription: FeedSubscription
    let epoch: Int
    let result: Result<FeedFetchResult, Error>
}

@MainActor
final class FeedReaderModel: ObservableObject {
    static let starterURL = URL(string: "https://developer.apple.com/news/rss/news.rss")!

    @Published var subscriptions: [FeedSubscription] = []
    @Published var articles: [FeedArticle] = []
    @Published var bookmarkedIDs: Set<String> = []
    @Published var selectedArticleID: String?
    @Published var selectedFeedID: String? { didSet { searchContextChanged(from: oldValue, oldBookmarks: showsBookmarksOnly) } }
    @Published var showsBookmarksOnly = false { didSet { searchContextChanged(from: selectedFeedID, oldBookmarks: oldValue) } }
    @Published var searchText = "" { didSet { searchTextChanged(from: oldValue) } }
    @Published private(set) var searchResults: [ArticleSearchResult] = []
    @Published private(set) var isSearching = false
    @Published private(set) var isLoadingMoreSearchResults = false
    @Published private(set) var searchMessage: String?
    @Published private(set) var searchFailed = false
    @Published private(set) var searchPreparing = false
    @Published private(set) var searchPreparation: ArticleSearchPreparation?
    @Published private(set) var preparationFailure: String?
    @Published var feedURL = ""
    @Published var isLoading = true
    @Published var isRefreshing = false
    @Published private(set) var isStoppingRefresh = false
    @Published private(set) var refreshPhases: [String: FeedRefreshPhase] = [:]
    @Published private(set) var lastSuccessfulRefreshes: [String: Date] = [:]
    @Published private(set) var refreshHistoryFailure: String?
    @Published var bookmarkBusy: Set<String> = []
    @Published var failureByFeed: [String: String] = [:]
    @Published var message = "保存済みの記事を読み込んでいます。"

    private var store: (any FeedLibraryStoring)?
    private var searcher: (any ArticleSearching)?
    private let searchDebounce: Duration
    private let fetcher: any FeedFetching
    private let dataDirectory: URL?
    private var initialized = false
    private var epochs: [String: Int] = [:]
    private var pendingRefreshAll = false
    private var pendingRefreshIDs: Set<String> = []
    private var activeRefreshAll = false
    private var activeRequestEpochs: [String: Int] = [:]
    private var refreshTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var preparationTask: Task<Void, Never>?
    private var isStartingPreparation = false
    private var searchGeneration: UInt64 = 0
    private var cacheGeneration: UInt64 = 0
    private var nextSearchCursor: Int64?
    private var searchBookmarkStates: [String: Bool] = [:]
    private var unknownSearchBookmarkIDs: Set<String> = []
    private var suppressSearchContextInvalidation = false

    init(
        dataDirectory: URL? = nil,
        store: (any FeedLibraryStoring)? = nil,
        fetcher: any FeedFetching = FeedHTTPClient(),
        searcher: (any ArticleSearching)? = nil,
        searchDebounce: Duration = .milliseconds(250)
    ) {
        self.dataDirectory = dataDirectory
        self.store = store
        self.fetcher = fetcher
        self.searcher = searcher ?? (store as? any ArticleSearching)
        self.searchDebounce = searchDebounce
    }

    var isPreparingSearch: Bool { searchPreparation?.isReady == false }
    var showsSearchResults: Bool { hasSearchQuery && !isPreparingSearch }

    var preparationMessage: String? {
        guard case .preparing(let processed) = searchPreparation else { return nil }
        if let preparationFailure { return "検索の準備を中断しました: " + preparationFailure }
        return "検索を準備中（\(processed)件確認済み）。記事の閲覧・保存はできます。"
    }

    deinit { preparationTask?.cancel(); refreshTask?.cancel() }

    var visibleArticles: [FeedArticle] {
        if showsSearchResults { return searchResults.map(\.article) }
        return articles.filter { article in
            (!showsBookmarksOnly || bookmarkedIDs.contains(article.id)) &&
            (selectedFeedID == nil || article.feedID == selectedFeedID)
        }
    }

    var selectedArticle: FeedArticle? {
        if showsSearchResults { return searchResults.first { $0.article.id == selectedArticleID }?.article }
        return articles.first { $0.id == selectedArticleID }
    }

    var hasSearchQuery: Bool {
        searchText.unicodeScalars.contains { !$0.properties.isWhitespace }
    }

    var canLoadMoreSearchResults: Bool {
        hasSearchQuery && nextSearchCursor != nil && !isSearching && !isLoadingMoreSearchResults
    }

    func searchResult(for articleID: String) -> ArticleSearchResult? {
        searchResults.first { $0.article.id == articleID }
    }

    func bookmarkState(for article: FeedArticle) -> Bool? {
        if hasSearchQuery, searchResult(for: article.id) != nil {
            if unknownSearchBookmarkIDs.contains(article.id) { return nil }
            if let value = searchBookmarkStates[article.id] { return value }
        }
        return bookmarkedIDs.contains(article.id)
    }

    func initialize() async {
        guard !initialized else { return }
        initialized = true
        do {
            if store == nil {
                let directory = try dataDirectory ?? Self.defaultDirectory()
                store = try await Task.detached(priority: .utility) {
                    try FeedLibraryStore(directory: directory, deferSearchPreparation: true)
                }.value
            }
            if searcher == nil { searcher = store as? any ArticleSearching }
            try await reloadCache()
            isLoading = false
            await startSearchPreparation()
            let generationBeforeRefresh = searchGeneration
            await refresh()
            if hasSearchQuery, searchGeneration == generationBeforeRefresh {
                scheduleSearch(debounced: false)
            }
        } catch {
            isLoading = false
            message = "保存領域を利用できません: \(error.localizedDescription)"
        }
    }

    func startSearchPreparation() async {
        guard preparationTask == nil, !isStartingPreparation,
              let preparer = store as? any ArticleSearchPreparing else { return }
        isStartingPreparation = true
        defer { isStartingPreparation = false }
        let wasPreparing = isPreparingSearch
        preparationFailure = nil
        do {
            searchPreparation = try await preparer.searchPreparationStatus()
            guard isPreparingSearch else {
                // Another scene may have finished while this scene showed a
                // retry. Run the pending query even without starting a worker.
                if wasPreparing { invalidateSearch(debounced: false) }
                return
            }
            invalidateSearch(debounced: false)
        } catch {
            searchPreparation = .preparing(processedArticles: 0)
            preparationFailure = error.localizedDescription
            return
        }
        preparationTask = Task(priority: .utility) { [weak self] in
            do {
                let clock = ContinuousClock()
                var lastPublished = clock.now
                while !Task.isCancelled {
                    let state = try await preparer.prepareSearchBatch()
                    if state.isReady || lastPublished.duration(to: clock.now) >= .milliseconds(100) {
                        self?.searchPreparation = state
                        lastPublished = clock.now
                    }
                    if state.isReady {
                        self?.preparationTask = nil
                        self?.invalidateSearch(debounced: false)
                        return
                    }
                    // Suspend outside the store actor and outside a transaction.
                    // User reads and saves have an opportunity between batches.
                    try await Task.sleep(for: .milliseconds(1))
                }
            } catch is CancellationError {
                // The committed cursor is retained for the next open.
            } catch {
                self?.preparationFailure = error.localizedDescription
            }
            self?.preparationTask = nil
        }
    }

    func addEnteredFeed() async {
        guard let url = URL(string: feedURL.trimmingCharacters(in: .whitespacesAndNewlines)), let store else {
            message = "有効な HTTPS フィード URL を入力してください。"
            return
        }
        do {
            invalidateCache()
            let subscription = try await store.addSubscription(url: url, title: nil)
            invalidateCache()
            epochs[subscription.id, default: 0] += 1
            feedURL = ""
            try await reloadCache()
            await refresh(ids: [subscription.id])
        } catch {
            message = error.localizedDescription
        }
    }

    func addStarterFeed() async {
        feedURL = Self.starterURL.absoluteString
        await addEnteredFeed()
    }

    func remove(_ subscription: FeedSubscription) async {
        guard let store else { return }
        epochs[subscription.id, default: 0] += 1
        invalidateCache()
        do {
            let result = try await store.removeSubscription(id: subscription.id)
            invalidateCache()
            subscriptions.removeAll { $0.id == subscription.id }
            if selectedFeedID == subscription.id {
                suppressSearchContextInvalidation = true
                selectedFeedID = nil
                suppressSearchContextInvalidation = false
            }
            failureByFeed[subscription.id] = nil
            refreshPhases[subscription.id] = nil
            lastSuccessfulRefreshes[subscription.id] = nil
            // Another scene may already have removed the subscription, leaving
            // no newly deleted IDs. The retained IDs still describe every
            // target-feed snapshot that survived the transaction.
            var removedArticleIDs = result.deletedArticleIDs
            removedArticleIDs.formUnion(articles.lazy.filter {
                $0.feedID == subscription.id && !result.retainedArticleIDs.contains($0.id)
            }.map(\.id))
            removedArticleIDs.formUnion(searchResults.lazy.filter {
                $0.article.feedID == subscription.id && !result.retainedArticleIDs.contains($0.article.id)
            }.map(\.article.id))
            removedArticleIDs.subtract(result.retainedArticleIDs)
            articles.removeAll {
                $0.feedID == subscription.id && removedArticleIDs.contains($0.id)
            }
            bookmarkedIDs.subtract(removedArticleIDs)
            bookmarkedIDs.formUnion(result.retainedArticleIDs)
            searchResults.removeAll {
                $0.article.feedID == subscription.id && removedArticleIDs.contains($0.article.id)
            }
            for id in removedArticleIDs {
                searchBookmarkStates[id] = nil
                unknownSearchBookmarkIDs.remove(id)
            }
            for id in result.retainedArticleIDs {
                searchBookmarkStates[id] = true
                unknownSearchBookmarkIDs.remove(id)
            }
            if let selectedArticleID, removedArticleIDs.contains(selectedArticleID) {
                self.selectedArticleID = nil
            }
            refreshSearchPreservingResults()
            do {
                try await reloadCache()
                message = "購読を削除しました。保存済みのブックマークは保持されます。"
            } catch {
                message = "購読を削除しましたが、保存済み記事の再読み込みに失敗しました: \(error.localizedDescription)"
            }
        } catch {
            message = "購読を削除できませんでした: \(error.localizedDescription)"
        }
    }

    var refreshProgress: String {
        let phases = activeRequestEpochs.keys.compactMap { refreshPhases[$0] }
        let completed = phases.filter { !$0.isPending }.count
        return isStoppingRefresh ? "通信の中止を待っています。" : "更新 \(completed)/\(phases.count)件完了"
    }

    func cancelRefresh() {
        guard isRefreshing else { return }
        isStoppingRefresh = true
        pendingRefreshAll = false
        pendingRefreshIDs.removeAll()
        refreshTask?.cancel()
        for id in refreshPhases.keys where refreshPhases[id]?.isPending == true {
            refreshPhases[id] = .cancelled
        }
    }

    func refresh(ids: Set<String>? = nil) async {
        guard let store, !Task.isCancelled else { return }
        if isRefreshing {
            guard !isStoppingRefresh else { return }
            if let ids, !pendingRefreshAll {
                let changedOrMissing = ids.filter {
                    activeRequestEpochs[$0] != epochs[$0, default: 0]
                }
                pendingRefreshIDs.formUnion(changedOrMissing)
            } else if ids == nil, !activeRefreshAll {
                pendingRefreshAll = true
                pendingRefreshIDs.removeAll()
            }
            return
        }
        isRefreshing = true
        isStoppingRefresh = false
        let worker = Task { await self.runRefresh(ids: ids, store: store) }
        refreshTask = worker
        await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private func runRefresh(ids: Set<String>?, store: any FeedLibraryStoring) async {
        defer {
            // Finish ownership in the worker itself. Its awaiting caller may
            // resume after a new refresh has already started, so that caller
            // must not clear the new worker's state.
            refreshTask = nil
            activeRefreshAll = false
            activeRequestEpochs.removeAll()
            pendingRefreshAll = false
            pendingRefreshIDs.removeAll()
            isStoppingRefresh = false
            isRefreshing = false
        }
        var requestedIDs = ids
        while !Task.isCancelled {
            activeRefreshAll = requestedIDs == nil
            activeRequestEpochs.removeAll()
            await performRefresh(ids: requestedIDs, store: store)
            guard !Task.isCancelled else { break }
            if pendingRefreshAll {
                pendingRefreshAll = false
                pendingRefreshIDs.removeAll()
                requestedIDs = nil
            } else if !pendingRefreshIDs.isEmpty {
                requestedIDs = pendingRefreshIDs
                pendingRefreshIDs.removeAll()
            } else {
                break
            }
        }
        if Task.isCancelled {
            for id in refreshPhases.keys where refreshPhases[id]?.isPending == true {
                refreshPhases[id] = .cancelled
            }
            message = "更新を中止しました。保存済みの記事は保持しています。"
        }
    }

    private func acceptsRefresh(_ id: String, epoch: Int) -> Bool {
        !Task.isCancelled && !isStoppingRefresh && epochs[id, default: 0] == epoch
            && subscriptions.contains(where: { $0.id == id })
    }

    private func performRefresh(ids: Set<String>?, store: any FeedLibraryStoring) async {
        do {
            // Observe other scenes before starting requests.
            try await reloadCache()
        } catch {
            message = "保存済み記事の再読み込みに失敗しました: \(error.localizedDescription)"
            return
        }
        guard !Task.isCancelled else { return }
        defer { refreshSearchPreservingResults() }
        let targets = subscriptions.filter { ids == nil || ids!.contains($0.id) }
        activeRequestEpochs = Dictionary(uniqueKeysWithValues: targets.map {
            ($0.id, epochs[$0.id, default: 0])
        })
        guard !targets.isEmpty else {
            message = "購読中のフィードはありません。"
            return
        }
        for subscription in targets { refreshPhases[subscription.id] = .queued }
        message = "フィードを更新しています。完了した内容から表示します。"
        let fetcher = self.fetcher
        await withTaskGroup(of: FeedRefreshCompletion.self) { group in
            var waiting = targets
            var activeHosts: Set<String> = []
            // At most three requests per refresh, one per configured URL host.
            // Queued subscriptions have no tasks until a slot becomes available.
            while true {
                while !Task.isCancelled, activeHosts.count < 3,
                      let index = waiting.firstIndex(where: { !activeHosts.contains($0.url.host!.lowercased()) }) {
                    let subscription = waiting.remove(at: index)
                    let epoch = activeRequestEpochs[subscription.id]!
                    guard acceptsRefresh(subscription.id, epoch: epoch) else { continue }
                    activeHosts.insert(subscription.url.host!.lowercased())
                    refreshPhases[subscription.id] = .fetching
                    group.addTask {
                        let result: Result<FeedFetchResult, Error>
                        do {
                            try Task.checkCancellation()
                            result = .success(try await fetcher.fetch(subscription))
                        } catch { result = .failure(error) }
                        return FeedRefreshCompletion(subscription: subscription, epoch: epoch, result: result)
                    }
                }
                guard let completion = await group.next() else { break }
                activeHosts.remove(completion.subscription.url.host!.lowercased())
                if Task.isCancelled { group.cancelAll(); continue }
                await acceptRefreshCompletion(completion, store: store)
            }
        }
        guard !Task.isCancelled else { return }
        do { try await reloadCache() }
        catch { message = "保存済み記事の再読み込みに失敗しました: \(error.localizedDescription)"; return }
        let phases = targets.compactMap { refreshPhases[$0.id] }
        if phases.contains(.failed) {
            message = "一部のフィードを更新できませんでした。フィードの状況から再試行できます。"
        } else if phases.contains(.updated) {
            message = "\(phases.filter { $0 == .updated }.count)件のフィードから内容を保存しました。"
        } else if phases.contains(.unchanged) {
            message = "フィードに変更はありませんでした。"
        }
    }

    private func acceptRefreshCompletion(_ completion: FeedRefreshCompletion, store: any FeedLibraryStoring) async {
        let id = completion.subscription.id
        guard acceptsRefresh(id, epoch: completion.epoch) else { return }
        var contentSaved = false
        do {
            let phase: FeedRefreshPhase
            switch try completion.result.get() {
            case .notModified:
                phase = .unchanged
            case .updated(let feed, let eTag, let lastModified):
                invalidateCache()
                guard try await store.saveFetchedFeedIfSubscribed(feed, eTag: eTag, lastModified: lastModified) else {
                    try await reloadCache()
                    return
                }
                invalidateCache()
                contentSaved = true
                phase = .updated
            }
            guard acceptsRefresh(id, epoch: completion.epoch) else { return }
            if let recorder = store as? any FeedRefreshRecording {
                guard try await recorder.recordSuccessfulRefreshIfSubscribed(id: id, at: Date()) else {
                    try await reloadCache()
                    return
                }
            }
            guard acceptsRefresh(id, epoch: completion.epoch) else { return }
            refreshPhases[id] = phase
            failureByFeed[id] = nil
            try await reloadCache()
            refreshSearchPreservingResults()
        } catch {
            guard acceptsRefresh(id, epoch: completion.epoch) else { return }
            if error is CancellationError {
                refreshPhases[id] = .cancelled
                return
            }
            refreshPhases[id] = .failed
            failureByFeed[id] = (contentSaved ? "記事は保存しましたが、更新情報の保存・再読み込みに失敗しました: " : "更新できませんでした: ") + error.localizedDescription
            if contentSaved { try? await reloadCache() }
        }
    }

    func setBookmark(_ desired: Bool, article: FeedArticle) async {
        guard !bookmarkBusy.contains(article.id), let store else { return }
        guard let current = bookmarkState(for: article) else {
            message = "ブックマーク状態を確認できません。検索を再試行してから操作してください。"
            return
        }
        guard current != desired else { return }
        bookmarkBusy.insert(article.id)
        defer { bookmarkBusy.remove(article.id) }
        do {
            invalidateCache()
            let result = try await store.setBookmarked(articleID: article.id, bookmarked: desired)
            invalidateCache()
            // Reflect the committed transaction before reloading. In
            // particular, the store deletes an unbookmarked article when its
            // subscription no longer exists; this also keeps the UI correct
            // if the subsequent cache read fails.
            if desired {
                bookmarkedIDs.insert(article.id)
            } else {
                bookmarkedIDs.remove(article.id)
            }
            searchBookmarkStates[article.id] = desired
            unknownSearchBookmarkIDs.remove(article.id)
            if result == .articleDeleted {
                articles.removeAll { $0.id == article.id }
                searchResults.removeAll { $0.article.id == article.id }
            }
            clearHiddenSelection()
            invalidateSearchAndRefresh()
            do {
                // Removing the final bookmark also deletes an article whose
                // subscription no longer exists, so reconcile the full cache.
                try await reloadCache()
            } catch {
                message = "ブックマークは保存しましたが、保存済み記事の再読み込みに失敗しました: \(error.localizedDescription)"
            }
        } catch {
            message = "ブックマークを保存できませんでした: \(error.localizedDescription)"
        }
    }

    func cachedTranslation(for snapshot: TranslationSnapshot) async throws -> ArticleTranslation? {
        if let value = searchResult(for: snapshot.articleID)?.translation,
           value.articleID == snapshot.articleID,
           value.sourceFingerprint == snapshot.sourceFingerprint,
           value.targetLanguage == "ja" {
            return value
        }
        guard let value = try await store?.translation(articleID: snapshot.articleID, targetLanguage: "ja") else {
            return nil
        }
        guard value.articleID == snapshot.articleID,
              value.sourceFingerprint == snapshot.sourceFingerprint,
              value.targetLanguage == "ja" else { return nil }
        return value
    }

    func saveTranslation(_ translation: ArticleTranslation) async throws {
        guard let store else { throw FeedError.unavailable }
        invalidateCache()
        try await store.saveTranslation(translation)
        invalidateCache()
        refreshSearchPreservingResults()
    }

    func loadMoreSearchResults() {
        guard canLoadMoreSearchResults, let cursor = nextSearchCursor else { return }
        let generation = searchGeneration
        let query = searchText
        let feedID = selectedFeedID
        let bookmarksOnly = showsBookmarksOnly
        isLoadingMoreSearchResults = true
        Task { [weak self] in
            await self?.performSearch(
                query: query, feedID: feedID, bookmarksOnly: bookmarksOnly,
                before: cursor, generation: generation, appending: true
            )
        }
    }

    private func searchTextChanged(from oldValue: String) {
        guard searchText != oldValue else { return }
        invalidateSearch(debounced: true)
    }

    private func searchContextChanged(from oldFeedID: String?, oldBookmarks: Bool) {
        guard !suppressSearchContextInvalidation else { return }
        guard selectedFeedID != oldFeedID || showsBookmarksOnly != oldBookmarks else { return }
        invalidateSearch(debounced: false)
    }

    private func invalidateSearchAndRefresh() {
        invalidateSearch(debounced: false)
    }

    private func refreshSearchPreservingResults() {
        searchGeneration &+= 1
        searchTask?.cancel()
        searchTask = nil
        nextSearchCursor = nil
        isLoadingMoreSearchResults = false
        guard hasSearchQuery else { return }
        scheduleSearch(debounced: false)
    }

    private func invalidateSearch(debounced: Bool) {
        searchGeneration &+= 1
        searchTask?.cancel()
        searchTask = nil
        searchResults = []
        nextSearchCursor = nil
        isSearching = false
        isLoadingMoreSearchResults = false
        searchMessage = nil
        searchFailed = false
        searchPreparing = false
        searchBookmarkStates.removeAll()
        unknownSearchBookmarkIDs.removeAll()
        clearHiddenSelection()
        guard hasSearchQuery else { return }
        scheduleSearch(debounced: debounced)
    }

    private func scheduleSearch(debounced: Bool) {
        guard hasSearchQuery else { return }
        if isPreparingSearch {
            isSearching = false
            searchPreparing = true
            searchMessage = "準備が完了すると入力した条件で検索します。現在は保存済み記事を表示しています。"
            return
        }
        searchGeneration &+= 1
        searchTask?.cancel()
        let generation = searchGeneration
        let query = searchText
        let feedID = selectedFeedID
        let bookmarksOnly = showsBookmarksOnly
        isSearching = true
        searchFailed = false
        searchPreparing = false
        searchMessage = "すべての保存済み記事を検索しています。"
        searchTask = Task { [weak self] in
            if debounced {
                do { try await Task.sleep(for: self?.searchDebounce ?? .milliseconds(250)) }
                catch { return }
            }
            await self?.performSearch(
                query: query, feedID: feedID, bookmarksOnly: bookmarksOnly,
                before: nil, generation: generation, appending: false
            )
        }
    }

    private func performSearch(query: String, feedID: String?, bookmarksOnly: Bool,
                               before: Int64?, generation: UInt64, appending: Bool) async {
        guard let searcher else {
            acceptSearchFailure("検索用の保存領域を利用できません。", query: query, feedID: feedID,
                                bookmarksOnly: bookmarksOnly, generation: generation, appending: appending)
            return
        }
        do {
            let page = try await searcher.searchArticles(ArticleSearchRequest(
                text: query, feedID: feedID, bookmarksOnly: bookmarksOnly, limit: 50, before: before
            ))
            guard searchIdentityMatches(query, feedID: feedID, bookmarksOnly: bookmarksOnly, generation: generation) else { return }
            var bookmarkStates: [String: Bool] = [:]
            var unknownBookmarkIDs: Set<String> = []
            for result in page.results {
                if let value = result.isBookmarked {
                    bookmarkStates[result.article.id] = value
                } else if bookmarksOnly {
                    bookmarkStates[result.article.id] = true
                } else {
                    unknownBookmarkIDs.insert(result.article.id)
                }
            }
            for (id, value) in bookmarkStates {
                if value { bookmarkedIDs.insert(id) } else { bookmarkedIDs.remove(id) }
            }
            if appending {
                var existingIDs = Set(searchResults.map { $0.article.id })
                var existingCursors = Set(searchResults.map(\.cursor))
                let additions = page.results.filter {
                    existingIDs.insert($0.article.id).inserted && existingCursors.insert($0.cursor).inserted
                }
                searchResults.append(contentsOf: additions)
                for result in additions {
                    if let value = bookmarkStates[result.article.id] {
                        searchBookmarkStates[result.article.id] = value
                        unknownSearchBookmarkIDs.remove(result.article.id)
                    } else {
                        unknownSearchBookmarkIDs.insert(result.article.id)
                    }
                }
                if let next = page.nextCursor, let before, next < before, !additions.isEmpty {
                    nextSearchCursor = next
                } else {
                    nextSearchCursor = nil
                }
            } else {
                var ids: Set<String> = []
                var cursors: Set<Int64> = []
                searchResults = page.results.filter {
                    ids.insert($0.article.id).inserted && cursors.insert($0.cursor).inserted
                }
                searchBookmarkStates = bookmarkStates
                unknownSearchBookmarkIDs = unknownBookmarkIDs
                nextSearchCursor = page.nextCursor
            }
            isSearching = false
            isLoadingMoreSearchResults = false
            searchFailed = false
            searchPreparing = false
            let baseMessage = searchResults.isEmpty
                ? "一致する保存済み記事はありません。"
                : "保存・更新された順に\(searchResults.count)件を表示しています。"
            searchMessage = unknownSearchBookmarkIDs.isEmpty
                ? baseMessage
                : baseMessage + " 一部の記事はブックマーク状態が不明です。検索を再試行してください。"
            clearHiddenSelection()
        } catch is CancellationError {
            // Identity checks, not cooperative cancellation, decide whether a response is current.
        } catch {
            let text: String
            if let searchError = error as? ArticleSearchError, searchError == .notReady {
                text = "検索索引を準備しています。完了後にもう一度お試しください。"
            } else {
                text = "検索できませんでした: \(error.localizedDescription)"
            }
            acceptSearchFailure(text, query: query, feedID: feedID, bookmarksOnly: bookmarksOnly,
                                generation: generation, appending: appending)
        }
    }

    private func acceptSearchFailure(_ text: String, query: String, feedID: String?,
                                     bookmarksOnly: Bool, generation: UInt64, appending: Bool) {
        guard searchIdentityMatches(query, feedID: feedID, bookmarksOnly: bookmarksOnly, generation: generation) else { return }
        isSearching = false
        isLoadingMoreSearchResults = false
        if !appending && searchResults.isEmpty { nextSearchCursor = nil }
        searchPreparing = (text.hasPrefix("検索索引を準備しています"))
        searchFailed = !searchPreparing
        searchMessage = text
        clearHiddenSelection()
    }

    private func searchIdentityMatches(_ query: String, feedID: String?, bookmarksOnly: Bool,
                                       generation: UInt64) -> Bool {
        generation == searchGeneration && query == searchText && feedID == selectedFeedID
            && bookmarksOnly == showsBookmarksOnly && hasSearchQuery
    }

    private func reloadCache() async throws {
        guard let store else { throw FeedError.unavailable }
        cacheGeneration &+= 1
        let generation = cacheGeneration
        let values: ([FeedSubscription], [FeedArticle], [FeedArticle])
        do {
            async let loadedSubscriptions = store.subscriptions()
            async let loadedArticles = store.articles(feedID: nil, limit: 2_000)
            async let loadedBookmarks = store.bookmarkedArticles(limit: 2_000)
            values = try await (loadedSubscriptions, loadedArticles, loadedBookmarks)
        } catch {
            guard generation == cacheGeneration else { return }
            throw error
        }
        var history: [String: Date] = [:]
        var historyFailure: String?
        if let recorder = store as? any FeedRefreshRecording {
            do { history = try await recorder.lastSuccessfulRefreshes() }
            catch { historyFailure = "最終成功日時を読み込めません: " + error.localizedDescription }
        }
        guard generation == cacheGeneration else { return }
        lastSuccessfulRefreshes = history
        refreshHistoryFailure = historyFailure
        let (newSubscriptions, newArticles, bookmarks) = values
        subscriptions = newSubscriptions
        let currentIDs = Set(newSubscriptions.map(\.id))
        refreshPhases = refreshPhases.filter { currentIDs.contains($0.key) }
        failureByFeed = failureByFeed.filter { currentIDs.contains($0.key) }
        // The recent-article limit must not hide older saved bookmarks. Keep
        // the recent query's snapshot when both queries contain the same id.
        var snapshots = Dictionary(uniqueKeysWithValues: newArticles.map { ($0.id, $0) })
        for article in bookmarks where snapshots[article.id] == nil { snapshots[article.id] = article }
        // A bounded list cannot prove an older hit was deleted. It can prove
        // the whole library is empty, a known article changed, or an orphan
        // cannot be retained because there are no bookmarks at all.
        let libraryIsEmpty = newArticles.isEmpty && bookmarks.isEmpty
        let subscriptionIDs = Set(newSubscriptions.map(\.id))
        let invalidHitIDs = Set(searchResults.compactMap { result -> String? in
            let article = result.article
            if libraryIsEmpty { return article.id }
            if let current = snapshots[article.id], current != article { return article.id }
            if bookmarks.isEmpty && !subscriptionIDs.contains(article.feedID) { return article.id }
            return nil
        })
        if !invalidHitIDs.isEmpty {
            searchResults.removeAll { invalidHitIDs.contains($0.article.id) }
            for id in invalidHitIDs {
                searchBookmarkStates[id] = nil
                unknownSearchBookmarkIDs.remove(id)
            }
        }
        articles = snapshots.values.sorted { first, second in
            if first.publishedAt != second.publishedAt {
                guard let firstDate = first.publishedAt else { return false }
                guard let secondDate = second.publishedAt else { return true }
                return firstDate > secondDate
            }
            return first.id < second.id
        }
        var reloadedBookmarkIDs = Set(bookmarks.map(\.id))
        for result in searchResults {
            if let value = searchBookmarkStates[result.article.id] {
                if value { reloadedBookmarkIDs.insert(result.article.id) }
                else { reloadedBookmarkIDs.remove(result.article.id) }
            }
        }
        bookmarkedIDs = reloadedBookmarkIDs
        clearHiddenSelection()
        if !invalidHitIDs.isEmpty { refreshSearchPreservingResults() }
    }

    private func invalidateCache() {
        cacheGeneration &+= 1
    }

    func retrySearch() {
        guard hasSearchQuery else { return }
        scheduleSearch(debounced: false)
    }

    private func clearHiddenSelection() {
        if let selectedArticleID,
           !visibleArticles.contains(where: { $0.id == selectedArticleID }) {
            self.selectedArticleID = nil
        }
    }

    nonisolated private static func defaultDirectory() throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("TsumikiText", isDirectory: true)
    }
}

struct TranslationSnapshot: Equatable, Sendable {
    let articleID: String
    let sourceFingerprint: String
    let title: String
    let body: String

    init(article: FeedArticle) {
        articleID = article.id
        sourceFingerprint = article.sourceFingerprint
        title = article.title
        body = article.translationSourceBody
    }
}

struct TranslationRequest: Equatable, Sendable {
    let token: UUID
    let snapshot: TranslationSnapshot
}

struct TranslationCacheRequest: Equatable, Sendable {
    let token: UUID
    let snapshot: TranslationSnapshot
}

@MainActor
final class SavedTranslationResultModel: ObservableObject {
    @Published private(set) var translation: ArticleTranslation?
    @Published private(set) var message: String?
    private var request: TranslationCacheRequest?
    private var currentSnapshot: TranslationSnapshot?

    func load(
        snapshot: TranslationSnapshot,
        loader: @MainActor (TranslationSnapshot) async throws -> ArticleTranslation?
    ) async {
        // SwiftUI may start an already-cancelled task after a newer task has
        // taken ownership. Such a task must not replace that newer attempt.
        guard !Task.isCancelled else { return }
        let candidate = TranslationCacheRequest(token: UUID(), snapshot: snapshot)
        request = candidate
        currentSnapshot = snapshot
        translation = nil
        message = nil

        do {
            let value = try await loader(snapshot)
            guard accepts(candidate), !Task.isCancelled else {
                invalidate(candidate)
                return
            }
            request = nil
            guard let value else { return }
            guard value.articleID == snapshot.articleID,
                  value.sourceFingerprint == snapshot.sourceFingerprint,
                  value.targetLanguage == "ja" else { return }
            translation = value
        } catch {
            guard accepts(candidate), !Task.isCancelled else {
                invalidate(candidate)
                return
            }
            request = nil
            guard !(error is CancellationError) else { return }
            message = "保存済みの日本語訳を読み込めませんでした: \(error.localizedDescription)"
        }
    }

    func cancelLoad() {
        request = nil
        currentSnapshot = nil
    }

    func displayedTranslation(for snapshot: TranslationSnapshot) -> ArticleTranslation? {
        guard currentSnapshot == snapshot,
              translation?.articleID == snapshot.articleID,
              translation?.sourceFingerprint == snapshot.sourceFingerprint,
              translation?.targetLanguage == "ja" else { return nil }
        return translation
    }

    func displayedMessage(for snapshot: TranslationSnapshot) -> String? {
        currentSnapshot == snapshot ? message : nil
    }

    private func accepts(_ candidate: TranslationCacheRequest) -> Bool {
        request == candidate && currentSnapshot == candidate.snapshot
    }

    private func invalidate(_ candidate: TranslationCacheRequest) {
        guard request == candidate else { return }
        request = nil
    }
}

@MainActor
final class TranslationResultModel: ObservableObject {
    @Published private(set) var request: TranslationRequest?
    @Published private(set) var translation: ArticleTranslation?
    @Published private(set) var isSaved = false
    @Published var message: String?
    private var cacheRequest: TranslationCacheRequest?

    func beginCacheLoad(snapshot: TranslationSnapshot) -> TranslationCacheRequest {
        let candidate = TranslationCacheRequest(token: UUID(), snapshot: snapshot)
        cacheRequest = candidate
        if let translation,
           translation.articleID != snapshot.articleID || translation.sourceFingerprint != snapshot.sourceFingerprint {
            self.translation = nil
            isSaved = false
        }
        return candidate
    }

    func loaded(_ value: ArticleTranslation?, for candidate: TranslationCacheRequest, current: TranslationSnapshot) {
        guard cacheRequest == candidate, candidate.snapshot == current else { return }
        cacheRequest = nil
        guard request == nil, translation == nil else { return }
        guard let value else {
            translation = nil
            isSaved = false
            return
        }
        guard value.articleID == candidate.snapshot.articleID,
              value.sourceFingerprint == candidate.snapshot.sourceFingerprint,
              value.targetLanguage == "ja" else { return }
        translation = value
        isSaved = true
    }

    func cacheLoadFailed(_ error: Error, for candidate: TranslationCacheRequest, current: TranslationSnapshot) {
        guard cacheRequest == candidate, candidate.snapshot == current else { return }
        cacheRequest = nil
        guard request == nil, translation == nil else { return }
        message = "保存済みの日本語訳を読み込めませんでした: \(error.localizedDescription)"
    }

    func invalidateCacheLoad(_ candidate: TranslationCacheRequest? = nil) {
        guard candidate == nil || cacheRequest == candidate else { return }
        cacheRequest = nil
    }

    func begin(snapshot: TranslationSnapshot) -> TranslationRequest {
        cacheRequest = nil
        let request = TranslationRequest(token: UUID(), snapshot: snapshot)
        self.request = request
        message = nil
        return request
    }

    func cancel() {
        cacheRequest = nil
        request = nil
        message = "翻訳をキャンセルしました。原文と保存済みの翻訳は保持しています。"
    }

    func accepts(_ candidate: TranslationRequest, current: TranslationSnapshot) -> Bool {
        request == candidate && candidate.snapshot == current
    }

    func stage(_ value: ArticleTranslation, for candidate: TranslationRequest, current: TranslationSnapshot) -> Bool {
        guard accepts(candidate, current: current) else { return false }
        translation = value
        isSaved = false
        return true
    }

    func saved(_ value: ArticleTranslation, for candidate: TranslationRequest, current: TranslationSnapshot) {
        guard accepts(candidate, current: current), translation == value else { return }
        isSaved = true
        request = nil
        message = "日本語訳をこの端末に保存しました。"
    }

    func saveFailed(_ error: Error, for candidate: TranslationRequest, current: TranslationSnapshot) {
        guard accepts(candidate, current: current) else { return }
        request = nil
        isSaved = false
        message = "日本語訳は未保存です: \(error.localizedDescription)"
    }

    func fail(_ text: String, for candidate: TranslationRequest, current: TranslationSnapshot) {
        guard accepts(candidate, current: current) else { return }
        request = nil
        message = text
    }
}
