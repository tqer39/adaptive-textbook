import SwiftUI
import TextbookCore

public struct ReaderAppView: View {
    private let dataDirectory: URL?

    public init(dataDirectory: URL? = nil) {
        self.dataDirectory = dataDirectory
    }

    public var body: some View {
        TabView {
            FeedReaderView(dataDirectory: dataDirectory)
                .tabItem { Label("情報収集", systemImage: "newspaper") }
                .accessibilityIdentifier("information-tab")
            TextbookReaderView(dataDirectory: dataDirectory)
                .tabItem { Label("教科書", systemImage: "book.closed") }
                .accessibilityIdentifier("textbook-tab")
        }
    }
}

struct FeedReaderView: View {
    private enum Filter: Hashable {
        case all
        case bookmarks
        case feed(String)
    }

    private struct ArticleListContext: Hashable {
        let filter: Filter?
        let search: String?
    }

    @State private var showsFeedManagement = false
    @StateObject private var model: FeedReaderModel
    @Environment(\.scenePhase) private var scenePhase

    init(dataDirectory: URL?) {
        _model = StateObject(wrappedValue: FeedReaderModel(dataDirectory: dataDirectory))
    }

    var body: some View {
        NavigationSplitView {
            List(selection: filterSelection) {
                Section("表示") {
                    NavigationLink(value: Filter.all) {
                        Label("すべての記事", systemImage: "tray.full")
                    }
                    .accessibilityIdentifier("all-articles")
                    NavigationLink(value: Filter.bookmarks) {
                        Label("ブックマーク", systemImage: "bookmark")
                    }
                    .accessibilityIdentifier("bookmarked-articles")
                }
                Section("購読フィード") {
                    ForEach(model.subscriptions) { subscription in
                        NavigationLink(value: Filter.feed(subscription.id)) {
                            Label(subscription.title ?? subscription.url.host ?? subscription.url.absoluteString, systemImage: "dot.radiowaves.left.and.right")
                                .lineLimit(2)
                        }
                        .contextMenu {
                            Button("フィードを管理") { showsFeedManagement = true }
                        }
                        .accessibilityIdentifier("feed-" + subscription.id)
                    }
                }
            }
            .navigationTitle("情報収集")
            .toolbar { managementButton }
        } content: {
            Group {
                if model.isLoading {
                    ProgressView("保存済み記事を読み込み中")
                } else if let failure = model.libraryFailure {
                    VStack {
                        ContentUnavailableView("保存領域を読み込めません", systemImage: "externaldrive.badge.exclamationmark",
                                               description: Text(failure))
                        Button("保存領域を再読み込み") { Task { await model.initialize() } }
                            .accessibilityIdentifier("retry-library")
                    }
                } else if model.showsSearchResults && model.isSearching && model.searchResults.isEmpty {
                    ProgressView("すべての保存済み記事を検索中")
                        .accessibilityIdentifier("article-search-loading")
                } else if model.visibleArticles.isEmpty {
                    VStack {
                        ContentUnavailableView(
                            searchEmptyTitle,
                            systemImage: model.showsSearchResults ? "magnifyingglass" : (model.showsBookmarksOnly ? "bookmark" : "newspaper"),
                            description: Text(model.showsSearchResults ? (model.searchMessage ?? "検索条件を変えてお試しください。") : (model.showsBookmarksOnly ? "記事を開いてブックマークすると、ここに表示されます。" : "管理画面からフィードを追加するか、更新状況を確認してください。"))
                        )
                        if !model.showsSearchResults { managementButton }
                        if model.showsSearchResults && (model.searchFailed || model.searchPreparing) {
                            Button("検索を再試行") { model.retrySearch() }
                                .accessibilityIdentifier("article-search-retry")
                        }
                    }
                    .accessibilityIdentifier("article-search-empty")
                } else {
                    List(selection: $model.selectedArticleID) {
                        ForEach(model.visibleArticles) { article in
                            NavigationLink(value: article.id) {
                                VStack(alignment: .leading, spacing: 4) {
                                if let translation = model.searchResult(for: article.id)?.translation,
                                   !translation.title.isEmpty || !translation.body.isEmpty {
                                    if !translation.title.isEmpty {
                                        Text(translation.title).font(.headline).lineLimit(3)
                                    }
                                    Text("原文: " + (article.title.isEmpty ? "無題の記事" : article.title))
                                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                                    if !translation.body.isEmpty {
                                        Text(translation.body).font(.callout).lineLimit(2)
                                    }
                                } else {
                                    Text(article.title.isEmpty ? "無題の記事" : article.title)
                                    .font(.headline).lineLimit(3)
                                    let preview = article.translationSourceBody.trimmingCharacters(in: .whitespacesAndNewlines)
                                    if model.showsSearchResults && !preview.isEmpty {
                                        Text(preview).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                }
                                HStack {
                                    Text(sourceName(for: article))
                                    if let date = article.publishedAt {
                                        Text(date, format: .dateTime.year().month().day())
                                    }
                                }
                                .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .accessibilityIdentifier("article-" + article.id)
                        }
                        if model.showsSearchResults && model.canLoadMoreSearchResults {
                            Button("さらに50件を読み込む") { model.loadMoreSearchResults() }
                                .accessibilityIdentifier("article-search-load-more")
                        } else if model.isLoadingMoreSearchResults {
                            ProgressView("検索結果を読み込み中")
                                .accessibilityIdentifier("article-search-page-loading")
                        }
                    }
                }
            }
            #if os(macOS)
            // A filter or query starts a different list. Reusing AppKit's
            // row-height state across those replacements can reenter its
            // height calculation (see #23). Keep model/search-field state
            // outside this identity; refresh and paging retain the list.
            .id(ArticleListContext(filter: filterSelection.wrappedValue,
                                   search: model.showsSearchResults ? model.searchText : nil))
            #endif
            .navigationTitle(filterTitle)
            .searchable(text: $model.searchText, placement: searchFieldPlacement, prompt: model.isPreparingSearch ? "検索を準備中" : "原文・保存済み日本語訳を検索")
            .accessibilityIdentifier("article-search-field")
            .safeAreaInset(edge: .top) { controls }
        } detail: {
            if let article = model.selectedArticle {
                ArticleDetailView(article: article, model: model)
                    .id(article.id + "-" + article.sourceFingerprint)
            } else {
                ContentUnavailableView("記事を選択", systemImage: "doc.text")
            }
        }
        .sheet(isPresented: $showsFeedManagement) { FeedManagementView(model: model) }
        .task { await model.initialize() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.refresh() } }
        }
    }

    private var filterSelection: Binding<Filter?> {
        Binding {
            if model.showsBookmarksOnly { return .bookmarks }
            if let feedID = model.selectedFeedID { return .feed(feedID) }
            return .all
        } set: { selection in
            guard let selection else { return }
            switch selection {
            case .all:
                model.showsBookmarksOnly = false
                model.selectedFeedID = nil
            case .bookmarks:
                model.showsBookmarksOnly = true
                model.selectedFeedID = nil
            case .feed(let feedID):
                model.showsBookmarksOnly = false
                model.selectedFeedID = feedID
            }
            // A filter choice is also an explicit request to return to the
            // article list on collapsed navigation.
            model.selectedArticleID = nil
        }
    }

    private var searchFieldPlacement: SearchFieldPlacement {
        #if os(iOS)
        .navigationBarDrawer(displayMode: .always)
        #else
        .automatic
        #endif
    }

    private var managementButton: some View {
        Button { showsFeedManagement = true } label: {
            Label("フィードを管理", systemImage: "list.bullet.rectangle")
        }
        .accessibilityIdentifier("manage-feeds")
        .keyboardShortcut("m", modifiers: [.command, .shift])
    }

    private var filterTitle: String {
        if model.showsBookmarksOnly { return "ブックマーク" }
        if let id = model.selectedFeedID, let feed = model.subscriptions.first(where: { $0.id == id }) {
            return feed.title ?? feed.url.host ?? "フィード"
        }
        return "すべての記事"
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(filterTitle).font(.headline)
                .accessibilityIdentifier("article-filter")
            ViewThatFits(in: .horizontal) {
                HStack { managementButton; Spacer(); refreshButton }
                VStack(alignment: .leading) { managementButton; refreshButton }
            }
            if model.isRefreshing {
                RefreshProgressView(model: model)
            }
            Text(model.message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            if !model.isRefreshing, let summary = model.feedFailureSummary {
                Text(summary).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("feed-failure-summary")
            }
            if let preparationMessage = model.preparationMessage {
                VStack(alignment: .leading) {
                    Text(preparationMessage).font(.caption).foregroundStyle(.secondary)
                    if model.preparationFailure != nil {
                        Button("検索の準備を再試行") { Task { await model.startSearchPreparation() } }
                            .accessibilityIdentifier("article-index-retry")
                    }
                }
                .accessibilityIdentifier("article-index-progress")
            }
            if model.hasSearchQuery, let searchMessage = model.searchMessage {
                Text(searchMessage)
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    .accessibilityIdentifier("article-search-status")
            }
        }
        .padding(10)
        .background(.bar)
    }

    private var refreshButton: some View {
        Button { Task { await model.refresh() } } label: {
            Label("再読み込み", systemImage: "arrow.clockwise")
        }
        .disabled(model.isRefreshing || model.isLoading || model.libraryFailure != nil)
        .accessibilityIdentifier("refresh-feeds")
    }

    private func sourceName(for article: FeedArticle) -> String {
        model.subscriptions.first { $0.id == article.feedID }?.title
            ?? model.subscriptions.first { $0.id == article.feedID }?.url.host
            ?? "保存済みフィード"
    }

    private var searchEmptyTitle: String {
        if model.showsSearchResults {
            if model.searchPreparing { return "検索索引を準備しています" }
            if model.searchFailed { return "検索できませんでした" }
            return "一致する記事はありません"
        }
        return model.showsBookmarksOnly ? "ブックマークはありません" : "記事はありません"
    }
}

private struct RefreshProgressView: View {
    @ObservedObject var model: FeedReaderModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack { progress; Spacer(); cancel }
            VStack(alignment: .leading) { progress; cancel }
        }
    }

    private var progress: some View {
        HStack { ProgressView().controlSize(.small); Text(model.refreshProgress).font(.caption) }
    }

    private var cancel: some View {
        Button("更新を中止") { model.cancelRefresh() }
            .disabled(model.isStoppingRefresh)
            .accessibilityIdentifier("cancel-feed-refresh")
    }
}

private struct FeedManagementView: View {
    @ObservedObject var model: FeedReaderModel
    @Environment(\.dismiss) private var dismiss
    @State private var removal: FeedSubscription?
    @State private var confirmsRemoval = false
    @State private var isAdding = false
    @State private var removingIDs: Set<String> = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("フィードを追加").font(.headline)
                    TextField("HTTPS フィード URL", text: $model.feedURL)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("HTTPS フィード URL")
                        .accessibilityIdentifier("feed-url")
                        .onSubmit { addFeed() }
                        #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                    Button("追加") { addFeed() }
                        .disabled(cannotAdd || model.feedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("add-feed")
                    Button("Apple Developer ニュースを追加") { addFeed(starter: true) }
                        .disabled(cannotAdd)
                        .accessibilityIdentifier("add-apple-feed")
                    Text(model.message).font(.callout).textSelection(.enabled)
                        .accessibilityIdentifier("feed-management-message")
                    if model.isRefreshing { RefreshProgressView(model: model) }
                    if let failure = model.refreshHistoryFailure {
                        Text(failure).foregroundStyle(.red).textSelection(.enabled)
                    }
                    Divider()
                    Text("購読フィード（\(model.subscriptions.count)件）").font(.headline)
                    if model.subscriptions.isEmpty {
                        Text("購読中のフィードはありません。URLを入力して追加できます。")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.subscriptions) { subscription in
                        feedRow(subscription)
                        Divider()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle("フィードを管理")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("close-feed-management")
                }
            }
            .confirmationDialog("購読を解除しますか？", isPresented: $confirmsRemoval,
                                titleVisibility: .visible, presenting: removal) { subscription in
                Button("購読を解除", role: .destructive) {
                    removingIDs.insert(subscription.id)
                    Task {
                        await model.remove(subscription)
                        removingIDs.remove(subscription.id)
                    }
                }
                Button("キャンセル", role: .cancel) { removal = nil }
            } message: { subscription in
                Text("\(name(subscription))の更新を停止します。ブックマークした記事とその保存済み日本語訳は残ります。それ以外の記事と日本語訳は削除されます。")
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, idealWidth: 560, minHeight: 420, idealHeight: 620)
        #endif
    }

    private var cannotAdd: Bool { isAdding || model.isLoading || model.libraryFailure != nil }

    private func addFeed(starter: Bool = false) {
        guard !cannotAdd, starter || !model.feedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isAdding = true
        Task {
            if starter { await model.addStarterFeed() } else { await model.addEnteredFeed() }
            isAdding = false
        }
    }

    private func name(_ subscription: FeedSubscription) -> String {
        subscription.title ?? subscription.url.host ?? subscription.url.absoluteString
    }

    private func feedRow(_ subscription: FeedSubscription) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(name(subscription)).font(.headline)
            Text(subscription.url.absoluteString).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Text(model.refreshPhases[subscription.id]?.rawValue ?? "未更新").font(.subheadline)
            if let date = model.lastSuccessfulRefreshes[subscription.id] {
                Text("最終成功: " + date.formatted(date: .abbreviated, time: .standard)).font(.caption)
            } else {
                Text(model.refreshHistoryFailure == nil ? "最終成功: 記録なし" : "最終成功: 不明").font(.caption)
            }
            if let failure = model.failureByFeed[subscription.id] {
                Text((model.refreshPhases[subscription.id] == .failed ? "" : "前回の失敗: ") + failure)
                    .font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            Button("このフィードを再試行") { Task { await model.refresh(ids: [subscription.id]) } }
                .disabled(model.isRefreshing || removingIDs.contains(subscription.id))
                .accessibilityLabel(name(subscription) + "を再試行")
                .accessibilityIdentifier("retry-feed-" + subscription.id)
            Button("購読を解除", role: .destructive) {
                removal = subscription
                confirmsRemoval = true
            }
            .disabled(removingIDs.contains(subscription.id))
            .accessibilityLabel(name(subscription) + "の購読を解除")
            .accessibilityIdentifier("remove-feed-" + subscription.id)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ArticleDetailView: View {
    let article: FeedArticle
    @ObservedObject var model: FeedReaderModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(article.title.isEmpty ? "無題の記事" : article.title)
                    .font(.title.bold()).textSelection(.enabled)
                if let date = article.publishedAt {
                    Text(date, format: .dateTime.year().month().day().hour().minute())
                        .font(.caption).foregroundStyle(.secondary)
                }
                Label("フィードが提供した記事・要約です。元サイトの全文を取得したものではありません。", systemImage: "info.circle")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("原文").font(.title2.bold())
                Text(article.translationSourceBody)
                    .lineSpacing(5).textSelection(.enabled)
                    .accessibilityIdentifier("article-original")
                HStack {
                    let bookmarkState = model.bookmarkState(for: article)
                    Button {
                        guard let bookmarkState else { return }
                        Task { await model.setBookmark(!bookmarkState, article: article) }
                    } label: {
                        if let bookmarkState {
                            Label(bookmarkState ? "ブックマークを外す" : "ブックマーク", systemImage: bookmarkState ? "bookmark.fill" : "bookmark")
                        } else {
                            Label("ブックマーク状態を確認できません", systemImage: "bookmark.slash")
                        }
                    }
                    .disabled(bookmarkState == nil || model.bookmarkBusy.contains(article.id))
                    .accessibilityIdentifier("bookmark-article")
                    if let url = article.url {
                        Link("元の記事を開く", destination: url)
                            .accessibilityIdentifier("open-original")
                    }
                }
                Divider()
                TranslationPanel(article: article, model: model)
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .navigationTitle("記事")
    }
}
