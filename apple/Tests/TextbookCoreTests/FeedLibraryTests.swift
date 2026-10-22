import Foundation
import XCTest
@testable import TextbookCore

@MainActor
final class FeedLibraryTests: XCTestCase {
    func testRSSNormalizesTextResolvesLinksAndKeepsIdentity() throws {
        let xml = """
        <rss><channel><title>ニュース</title><item><guid>one</guid><title><![CDATA[<b>日本語 &amp; &#x65e5;</b>]]></title><link>/story#part</link><description><![CDATA[<p>A&nbsp;B</p>]]></description><pubDate>Tue, 03 Jun 2008 11:05:30 GMT</pubDate></item></channel></rss>
        """
        let parser = RSSFeedParser()
        let first = try parser.parse(data: Data(xml.utf8), responseURL: URL(string: "https://example.com/feed.xml")!)
        let second = try parser.parse(data: Data(xml.utf8), responseURL: URL(string: "https://example.com/feed.xml")!)
        XCTAssertEqual(first.title, "ニュース")
        // RSS titles are plain text even when CDATA is used for XML escaping.
        XCTAssertEqual(first.articles[0].title, "<b>日本語 &amp; &#x65e5;</b>")
        XCTAssertEqual(first.articles[0].summary, "A B")
        XCTAssertEqual(first.articles[0].url?.absoluteString, "https://example.com/story")
        XCTAssertNotNil(first.articles[0].publishedAt)
        XCTAssertEqual(first.articles[0].id, second.articles[0].id)
    }

    func testAtomBaseAndUnsafeXMLAreHandledOffline() throws {
        let atom = """
        <feed xml:base="https://example.com/base/"><title>Atom</title><entry><id>tag:example,1</id><title>題</title><link href="article"/><content type="xhtml"><div>本文 <b>です</b></div></content><updated>not a date</updated></entry></feed>
        """
        let feed = try RSSFeedParser().parse(data: Data(atom.utf8), responseURL: URL(string: "https://origin.invalid/feed")!)
        XCTAssertEqual(feed.articles[0].url?.absoluteString, "https://example.com/base/article")
        XCTAssertEqual(feed.articles[0].content, "本文 です")
        XCTAssertNil(feed.articles[0].publishedAt)
        XCTAssertThrowsError(try RSSFeedParser().parse(data: Data("<!DOCTYPE x []><rss/>".utf8), responseURL: URL(string: "https://example.com/feed")!))
    }

    func testBookmarksAndFreshTranslationsSurviveReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = URL(string: "https://example.com/feed")!
        let parsed = try RSSFeedParser().parse(data: Data("<rss><channel><title>x</title><item><guid>a</guid><title>old</title><description>body</description></item></channel></rss>".utf8), responseURL: url)
        let store = try FeedLibraryStore(directory: directory)
        try await store.saveFetchedFeed(parsed)
        let article = try await store.articles().first!
        let bookmarked = try await store.toggleBookmark(articleID: article.id)
        XCTAssertTrue(bookmarked)
        try await store.saveTranslation(ArticleTranslation(articleID: article.id, sourceFingerprint: article.sourceFingerprint, targetLanguage: "ja", title: "訳", body: "訳文"))
        let reopened = try FeedLibraryStore(directory: directory)
        let restoredBookmarks = try await reopened.bookmarkedArticles()
        let restoredTranslation = try await reopened.translation(articleID: article.id, targetLanguage: "ja")
        XCTAssertEqual(restoredBookmarks.map(\.id), [article.id])
        XCTAssertNotNil(restoredTranslation)
    }
}
