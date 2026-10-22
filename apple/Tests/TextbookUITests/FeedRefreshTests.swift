import Combine
import Foundation
import XCTest
import TextbookCore
@testable import TextbookUI

@MainActor
final class FeedRefreshTests: XCTestCase {
    func testHealthyFeedBecomesVisibleBeforeSlowFeedFinishes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FeedLibraryStore(directory: directory)
        let slow = try await store.addSubscription(url: URL(string: "https://a.example/slow")!)
        let fast = try await store.addSubscription(url: URL(string: "https://b.example/fast")!)
        let visible = expectation(description: "healthy article visible while slow request is gated")
        let fetcher = ControlledRefreshFetcher(gated: [slow.id])
        let model = FeedReaderModel(store: store, fetcher: fetcher)
        var fulfilled = false
        let observation = model.$articles.sink { articles in
            if !fulfilled && articles.contains(where: { $0.id == fast.id + "-article" }) {
                fulfilled = true
                visible.fulfill()
            }
        }
        let clock = ContinuousClock()
        let start = clock.now
        let loading = Task { await model.initialize() }
        await fulfillment(of: [visible], timeout: 2)
        print("Mixed-feed diagnostic: healthy article observed after \(start.duration(to: clock.now)); slow request still gated")
        let active = await fetcher.activeIDs
        XCTAssertTrue(active.contains(slow.id))
        XCTAssertTrue(model.isRefreshing)
        await fetcher.releaseAll()
        await loading.value
        withExtendedLifetime(observation) {}
    }
    func testConcurrencyBoundAndCancellationIgnoreLateSuccessAndFailure() async throws {
        for failLate in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = try FeedLibraryStore(directory: directory)
            var subscriptions: [FeedSubscription] = []
            for url in ["https://a.example/1", "https://a.example/2", "https://b.example/1", "https://c.example/1", "https://d.example/1"] {
                subscriptions.append(try await store.addSubscription(url: URL(string: url)!))
            }
            let fetcher = ControlledRefreshFetcher(gated: Set(subscriptions.map(\.id)))
            if failLate { await fetcher.setFailures(Set(subscriptions.map(\.id))) }
            let model = FeedReaderModel(store: store, fetcher: fetcher)
            let loading = Task { await model.initialize() }
            let started = await waitUntil { await fetcher.started.count == 3 }
            XCTAssertTrue(started)
            let initial = await fetcher.started
            XCTAssertEqual(Set(initial.compactMap { $0.url.host }), ["a.example", "b.example", "c.example"])
            model.cancelRefresh()
            XCTAssertTrue(model.isStoppingRefresh)
            await model.refresh() // Cancellation cannot start overlapping work.
            await fetcher.releaseAll()
            await loading.value
            let requests = await fetcher.started
            let maxActive = await fetcher.maximumActive
            let maxPerHost = await fetcher.maximumPerHost
            XCTAssertEqual(requests.count, 3)
            XCTAssertEqual(maxActive, 3)
            XCTAssertEqual(maxPerHost, 1)
            XCTAssertFalse(model.isRefreshing)
            XCTAssertTrue(model.articles.isEmpty)
            XCTAssertTrue(model.failureByFeed.isEmpty)
            XCTAssertTrue(model.lastSuccessfulRefreshes.isEmpty)
            XCTAssertTrue(model.refreshPhases.values.allSatisfy { $0 == .cancelled })
            let saved = try await store.articles()
            let history = try await store.lastSuccessfulRefreshes()
            XCTAssertTrue(saved.isEmpty)
            XCTAssertTrue(history.isEmpty)
        }
    }

    func testQueuedHostsEventuallyRunAndIndividualRetryPreservesConditionalHeaders() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FeedLibraryStore(directory: directory)
        var subscriptions: [FeedSubscription] = []
        for url in ["https://a.example/1", "https://a.example/2", "https://b.example/1", "https://c.example/1", "https://d.example/1"] {
            subscriptions.append(try await store.addSubscription(url: URL(string: url)!))
        }
        let failed = subscriptions[1]
        let fetcher = ControlledRefreshFetcher(gated: [])
        await fetcher.setFailures([failed.id])
        let model = FeedReaderModel(store: store, fetcher: fetcher)
        await model.initialize()
        XCTAssertEqual(model.articles.count, 4)
        XCTAssertEqual(model.lastSuccessfulRefreshes.count, 4)
        XCTAssertEqual(model.refreshPhases[failed.id], .failed)
        XCTAssertEqual(Set(model.failureByFeed.keys), [failed.id])
        await fetcher.setFailures([])
        await model.refresh(ids: [failed.id])
        XCTAssertEqual(model.articles.count, 5)
        XCTAssertEqual(model.lastSuccessfulRefreshes.count, 5)
        XCTAssertTrue(model.failureByFeed.isEmpty)
        XCTAssertEqual(model.refreshPhases[failed.id], .updated)
        let afterRetry = await fetcher.started
        XCTAssertEqual(afterRetry.count, 6)
        XCTAssertEqual(afterRetry.last?.id, failed.id)
        await fetcher.setNotModified(true)
        await model.refresh(ids: [failed.id])
        let conditional = await fetcher.started.last
        XCTAssertEqual(conditional?.eTag, "fixture-etag")
        XCTAssertEqual(conditional?.lastModified, "fixture-modified")
        XCTAssertEqual(model.refreshPhases[failed.id], .unchanged)
        let reopened = try FeedLibraryStore(directory: directory)
        let dates = try await reopened.lastSuccessfulRefreshes()
        XCTAssertEqual(dates, model.lastSuccessfulRefreshes)
    }

    func testParentCancellationStopsSchedulingAndIgnoresLateResponse() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FeedLibraryStore(directory: directory)
        let first = try await store.addSubscription(url: URL(string: "https://a.example/1")!)
        _ = try await store.addSubscription(url: URL(string: "https://a.example/2")!)
        let fetcher = ControlledRefreshFetcher(gated: [first.id])
        let model = FeedReaderModel(store: store, fetcher: fetcher)
        let loading = Task { await model.initialize() }
        let started = await waitUntil { await fetcher.started.count == 1 }
        XCTAssertTrue(started)
        loading.cancel()
        await fetcher.releaseAll()
        await loading.value
        let count = await fetcher.started.count
        XCTAssertEqual(count, 1)
        XCTAssertTrue(model.articles.isEmpty)
        XCTAssertFalse(model.isRefreshing)
    }

    func testMixedHTTPTransportShowsParsedArticleWhileSlowHostWaitsAndRetries304() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FeedLibraryStore(directory: directory)
        _ = try await store.addSubscription(url: URL(string: "https://a.example/slow")!)
        let healthy = try await store.addSubscription(url: URL(string: "https://b.example/feed")!)
        let failing = try await store.addSubscription(url: URL(string: "https://c.example/failure")!)
        let transport = MixedRefreshTransport()
        let model = FeedReaderModel(store: store, fetcher: FeedHTTPClient(transport: transport))
        let visible = expectation(description: "parsed HTTP article visible before delayed response")
        var fulfilled = false
        let observation = model.$articles.sink { articles in
            if !fulfilled && articles.contains(where: { $0.title == "HTTP fixture article" }) {
                fulfilled = true
                visible.fulfill()
            }
        }
        let clock = ContinuousClock()
        let start = clock.now
        let loading = Task { await model.initialize() }
        await fulfillment(of: [visible], timeout: 2)
        print("HTTP transport diagnostic: healthy parsed article observed after \(start.duration(to: clock.now)); slow response not released")
        let didWait = await transport.isWaiting
        XCTAssertTrue(didWait)
        XCTAssertTrue(model.isRefreshing)
        await transport.release()
        await loading.value
        XCTAssertEqual(model.refreshPhases[healthy.id], .updated)
        XCTAssertEqual(model.refreshPhases[failing.id], .failed)
        XCTAssertNotNil(model.lastSuccessfulRefreshes[healthy.id])
        XCTAssertNil(model.lastSuccessfulRefreshes[failing.id])
        await model.refresh(ids: [healthy.id])
        let request = await transport.requests.last
        XCTAssertEqual(request?.value(forHTTPHeaderField: "If-None-Match"), "http-etag")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "If-Modified-Since"), "Wed, 21 Oct 2026 00:00:00 GMT")
        XCTAssertEqual(model.refreshPhases[healthy.id], .unchanged)
        XCTAssertEqual(model.articles.map(\.title), ["HTTP fixture article"])
        withExtendedLifetime(observation) {}
    }

    private func waitUntil(_ condition: () async -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if await condition() { return true }
            await Task.yield()
        }
        return false
    }

}

private actor ControlledRefreshFetcher: FeedFetching {
    private let gated: Set<String>
    private var gates: [String: CheckedContinuation<Void, Never>] = [:]
    private var released = false
    private(set) var activeIDs: Set<String> = []
    private(set) var started: [FeedSubscription] = []
    private(set) var maximumActive = 0
    private(set) var maximumPerHost = 0
    private var failures: Set<String> = []
    private var notModified = false
    func setFailures(_ ids: Set<String>) { failures = ids }
    func setNotModified(_ value: Bool) { notModified = value }

    init(gated: Set<String>) { self.gated = gated }

    func fetch(_ subscription: FeedSubscription) async throws -> FeedFetchResult {
        activeIDs.insert(subscription.id)
        started.append(subscription)
        maximumActive = max(maximumActive, activeIDs.count)
        let hostCount = Set(started.filter { activeIDs.contains($0.id) && $0.url.host == subscription.url.host }.map(\.id)).count
        maximumPerHost = max(maximumPerHost, hostCount)
        if gated.contains(subscription.id) && !released {
            // Deliberately ignore cancellation to test stale completions.
            await withCheckedContinuation { gates[subscription.id] = $0 }
        }
        activeIDs.remove(subscription.id)
        if failures.contains(subscription.id) { throw FeedError.unavailable }
        if notModified { return .notModified }
        return .updated(ParsedFeed(id: subscription.id, sourceURL: subscription.url, title: "Fixture", articles: [
            FeedArticle(id: subscription.id + "-article", feedID: subscription.id, title: "Healthy article", url: nil, content: "Saved body")
        ]), eTag: "fixture-etag", lastModified: "fixture-modified")
    }

    func releaseAll() {
        released = true
        let pending = gates.values
        gates.removeAll()
        for gate in pending { gate.resume() }
    }
}

private actor MixedRefreshTransport: FeedHTTPTransport {
    private var gate: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var isWaiting = false
    private(set) var requests: [URLRequest] = []

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let url = request.url!
        if url.host == "a.example" && !released {
            isWaiting = true
            await withCheckedContinuation { gate = $0 }
            isWaiting = false
        }
        let status = url.host == "b.example"
            ? (request.value(forHTTPHeaderField: "If-None-Match") == nil ? 200 : 304) : 503
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [
            "ETag": "http-etag", "Last-Modified": "Wed, 21 Oct 2026 00:00:00 GMT"
        ])!
        return (Data("<rss><channel><title>Fixture</title><item><guid>http-fixture</guid><title>HTTP fixture article</title><description>Original body</description></item></channel></rss>".utf8), response)
    }

    func release() {
        released = true
        gate?.resume()
        gate = nil
    }
}
