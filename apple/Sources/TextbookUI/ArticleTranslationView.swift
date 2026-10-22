import SwiftUI
import TextbookCore
import Translation

struct TranslationPanel: View {
    let article: FeedArticle
    @ObservedObject var model: FeedReaderModel

    var body: some View {
        #if targetEnvironment(simulator)
        VStack(alignment: .leading, spacing: 8) {
            SavedTranslationPanel(article: article, model: model)
            Text("iOS SimulatorではAppleの翻訳処理を利用できません。翻訳は対応するMacまたはiPhoneで利用してください。RSSとブックマークは利用できます。")
                .font(.footnote)
                .accessibilityIdentifier("translation-unavailable")
        }
        #else
        if #available(macOS 15.0, iOS 18.0, *) {
            AvailableTranslationPanel(article: article, model: model)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                SavedTranslationPanel(article: article, model: model)
                Label("日本語訳には macOS 15 または iOS 18 以降の Apple Translation が必要です。原文、RSS、ブックマーク、教科書は引き続き利用できます。", systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .accessibilityIdentifier("translation-unavailable")
            }
        }
        #endif
    }
}

private struct SavedTranslationPanel: View {
    let article: FeedArticle
    @ObservedObject var model: FeedReaderModel
    @StateObject private var result = SavedTranslationResultModel()

    private var snapshot: TranslationSnapshot { TranslationSnapshot(article: article) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("日本語訳").font(.title2.bold())
            if let translation = result.displayedTranslation(for: snapshot) {
                Text(translation.title).font(.headline).textSelection(.enabled)
                Text(translation.body).lineSpacing(5).textSelection(.enabled)
                Text("この端末に保存済み").font(.caption).bold()
                    .accessibilityIdentifier("translation-save-state")
            } else if let message = result.displayedMessage(for: snapshot) {
                Text(message).font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("translation-status")
            }
        }
        .accessibilityIdentifier("saved-article-translation")
        .task(id: snapshot) {
            await result.load(snapshot: snapshot) { requestedSnapshot in
                try await model.cachedTranslation(for: requestedSnapshot)
            }
        }
        .onDisappear { result.cancelLoad() }
    }
}

@available(macOS 15.0, iOS 18.0, *)
@MainActor
private struct AvailableTranslationPanel: View {
    let article: FeedArticle
    @ObservedObject var model: FeedReaderModel
    @StateObject private var result = TranslationResultModel()
    @State private var configuration: TranslationSession.Configuration?

    private var snapshot: TranslationSnapshot { TranslationSnapshot(article: article) }
    private var isBusy: Bool { result.request != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("日本語訳").font(.title2.bold())
            if let translation = result.translation {
                VStack(alignment: .leading, spacing: 8) {
                    Text(translation.title).font(.headline).textSelection(.enabled)
                    Text(translation.body).lineSpacing(5).textSelection(.enabled)
                    Text(result.isSaved ? "この端末に保存済み" : "未保存")
                        .font(.caption).bold()
                        .accessibilityIdentifier("translation-save-state")
                }
                .accessibilityIdentifier("article-translation")
            }
            if let message = result.message {
                Text(message).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                    .accessibilityIdentifier("translation-status")
            }
            HStack {
                Button(result.translation == nil ? "日本語に翻訳" : "日本語訳を更新") {
                    startTranslation()
                }
                .disabled(isBusy || (snapshot.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && snapshot.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                .accessibilityIdentifier("translate-article")
                if isBusy {
                    ProgressView().controlSize(.small)
                    Button("キャンセル") { cancelTranslation() }
                        .accessibilityIdentifier("cancel-translation")
                }
                if result.translation != nil && !result.isSaved && !isBusy {
                    Button("保存を再試行") { retrySave() }
                        .accessibilityIdentifier("retry-translation-save")
                }
            }
            Text("翻訳はAppleのオンデバイス翻訳を使用します。初回はOSの案内に従って言語を準備してください。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task(id: snapshot) {
            let cacheRequest = result.beginCacheLoad(snapshot: snapshot)
            do {
                let cached = try await model.cachedTranslation(for: snapshot)
                try Task.checkCancellation()
                result.loaded(cached, for: cacheRequest, current: snapshot)
            } catch is CancellationError {
                result.invalidateCacheLoad(cacheRequest)
            } catch {
                result.cacheLoadFailed(error, for: cacheRequest, current: snapshot)
            }
        }
        .translationTask(configuration) { @Sendable session in
            // Keep the non-Sendable session in this nonisolated action. Only
            // immutable values cross to the main actor that owns the UI state.
            let candidate = await MainActor.run { () -> TranslationRequest? in
                guard let request = result.request,
                      result.accepts(request, current: snapshot) else { return nil }
                return request
            }
            guard let request = candidate else { return }
            do {
                try Task.checkCancellation()
                var requests: [TranslationSession.Request] = []
                if !request.snapshot.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    requests.append(.init(sourceText: request.snapshot.title, clientIdentifier: "title"))
                }
                if !request.snapshot.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    requests.append(.init(sourceText: request.snapshot.body, clientIdentifier: "body"))
                }
                guard !requests.isEmpty else {
                    await MainActor.run {
                        result.fail("翻訳する原文がありません。", for: request, current: snapshot)
                    }
                    return
                }
                let responses = try await session.translations(from: requests)
                try Task.checkCancellation()
                guard requests.allSatisfy({ input in
                    responses.contains { $0.clientIdentifier == input.clientIdentifier }
                }) else { throw TranslationPanelError.incompleteResponse }
                let value = ArticleTranslation(
                    articleID: request.snapshot.articleID,
                    sourceFingerprint: request.snapshot.sourceFingerprint,
                    targetLanguage: "ja",
                    title: responses.first { $0.clientIdentifier == "title" }?.targetText ?? "",
                    body: responses.first { $0.clientIdentifier == "body" }?.targetText ?? ""
                )
                let accepted = await MainActor.run {
                    result.stage(value, for: request, current: snapshot)
                }
                guard accepted else { return }
                do {
                    try await model.saveTranslation(value)
                    await MainActor.run {
                        result.saved(value, for: request, current: snapshot)
                    }
                } catch {
                    await MainActor.run {
                        result.saveFailed(error, for: request, current: snapshot)
                    }
                }
            } catch is CancellationError {
                await MainActor.run {
                    if result.accepts(request, current: snapshot) { result.cancel() }
                }
            } catch {
                await MainActor.run {
                    result.fail("日本語訳を準備または生成できませんでした: \(error.localizedDescription)。原文は保持しています。", for: request, current: snapshot)
                }
            }
        }
        .onDisappear {
            result.cancel()
            result.invalidateCacheLoad()
            configuration = nil
        }
    }

    private func startTranslation() {
        _ = result.begin(snapshot: snapshot)
        result.message = "日本語の準備状況を確認しています。OSの言語ダウンロード画面が表示される場合があります。"
        if configuration == nil {
            if #available(macOS 26.4, iOS 26.4, *) {
                configuration = .init(
                    source: nil,
                    target: Locale.Language(identifier: "ja"),
                    preferredStrategy: .lowLatency
                )
            } else {
                configuration = .init(source: nil, target: Locale.Language(identifier: "ja"))
            }
        } else {
            configuration?.invalidate()
        }
    }

    private func cancelTranslation() {
        result.cancel()
        configuration = nil
    }

    private func retrySave() {
        guard let value = result.translation,
              value.articleID == snapshot.articleID,
              value.sourceFingerprint == snapshot.sourceFingerprint else {
            result.message = "元の記事が変更されたため、この日本語訳は保存できません。記事を再読み込みしてください。"
            return
        }
        let request = result.begin(snapshot: snapshot)
        Task {
            do {
                try await model.saveTranslation(value)
                result.saved(value, for: request, current: snapshot)
            } catch {
                result.saveFailed(error, for: request, current: snapshot)
            }
        }
    }
}

private enum TranslationPanelError: Error, LocalizedError {
    case incompleteResponse

    var errorDescription: String? { "翻訳結果の一部を取得できませんでした。再試行してください。" }
}
