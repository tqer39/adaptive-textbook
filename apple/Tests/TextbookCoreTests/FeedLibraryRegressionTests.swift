import Foundation
import XCTest
import CSQLite
@testable import TextbookCore

@MainActor
final class FeedLibraryRegressionTests: XCTestCase {
    func testSummaryFallbackDoesNotDecodePlainTextTwice() throws {
        let xml = """
        <rss><channel><item><guid>escaped</guid><title>Source</title>
        <description><![CDATA[Discuss &lt;LLM&gt; design &amp;copy;]]></description>
        </item></channel></rss>
        """
        let feed = try RSSFeedParser().parse(data: Data(xml.utf8), responseURL: URL(string: "https://example.com/feed")!)
        let article = try XCTUnwrap(feed.articles.first)

        XCTAssertEqual(article.summary, "Discuss <LLM> design &copy;")
        XCTAssertEqual(article.content, article.summary)
        XCTAssertEqual(article.translationSourceBody, article.summary)
    }

    func testPlainTitlesAndAtomTextStayLiteralWhileRSSDescriptionUsesHTML() throws {
        let rss = """
        <rss><channel><title>配信</title><item><guid>plain</guid>
        <title>Literal &lt;b&gt; &amp;copy; 日本語</title>
        <description>Body &lt;b&gt; &amp;copy; 日本語</description>
        </item></channel></rss>
        """
        let source = URL(string: "https://example.com/feed")!
        let rssArticle = try XCTUnwrap(RSSFeedParser().parse(data: Data(rss.utf8), responseURL: source).articles.first)
        XCTAssertEqual(rssArticle.title, "Literal <b> &copy; 日本語")
        XCTAssertEqual(rssArticle.summary, "Body © 日本語")

        let atom = """
        <feed><title>Atom</title><entry><id>text</id>
        <title>Default &lt;b&gt; &amp;copy;</title>
        <summary type="text"><![CDATA[Explicit <b> &copy;]]></summary>
        <content type="html">&lt;p&gt;HTML &amp;copy;&lt;/p&gt;</content>
        </entry></feed>
        """
        let atomArticle = try XCTUnwrap(RSSFeedParser().parse(data: Data(atom.utf8), responseURL: source).articles.first)
        XCTAssertEqual(atomArticle.title, "Default <b> &copy;")
        XCTAssertEqual(atomArticle.summary, "Explicit <b> &copy;")
        XCTAssertEqual(atomArticle.content, "HTML ©")
    }

    func testXHTMLAndMixedCharacterCDATAContentNormalizeAtTheirOwnLayer() throws {
        let xml = """
        <feed><title>x</title><entry><id>mixed</id><title>題</title>
        <summary type="html">前 &lt;b&gt; <![CDATA[<p>HTML &copy; 日本語</p>]]> 後 &amp;copy;</summary>
        <content type="xhtml"><div><p>first &lt;b&gt; &amp;copy;</p><p>second <b>日本語</b></p></div></content>
        </entry></feed>
        """
        let article = try XCTUnwrap(RSSFeedParser().parse(
            data: Data(xml.utf8), responseURL: URL(string: "https://example.com/feed")!
        ).articles.first)

        XCTAssertEqual(article.summary, "前\nHTML © 日本語\n後 ©")
        XCTAssertEqual(article.content, "first <b> &copy;\nsecond 日本語")
    }

    func testAtomHTMLSplitAcrossAdjacentCDATAChunksMatchesUnsplitPayload() throws {
        let source = URL(string: "https://example.com/feed")!
        let split = """
        <feed><title>x</title><entry><id>split</id><title>題</title>
        <summary type="html"><![CDATA[<p>first &co]]><![CDATA[py;</p><p>second</p>]]></summary>
        </entry></feed>
        """
        let unsplit = """
        <feed><title>x</title><entry><id>unsplit</id><title>題</title>
        <summary type="html"><![CDATA[<p>first &copy;</p><p>second</p>]]></summary>
        </entry></feed>
        """

        let splitSummary = try XCTUnwrap(RSSFeedParser().parse(data: Data(split.utf8), responseURL: source).articles.first).summary
        let unsplitSummary = try XCTUnwrap(RSSFeedParser().parse(data: Data(unsplit.utf8), responseURL: source).articles.first).summary

        XCTAssertEqual(splitSummary, "first ©\nsecond")
        XCTAssertEqual(splitSummary, unsplitSummary)
    }

    func testAtomXHTMLTitlesPreserveBlockBoundariesAndEscapedCode() throws {
        let xml = """
        <feed><title type="xhtml"><div><p>配信 First &lt;feed-code&gt;</p><p>配信 Second</p></div></title>
        <entry><id>one</id><title type="xhtml"><div><p>記事 First &lt;entry-code&gt;</p><p>記事 Second</p></div></title></entry></feed>
        """

        let feed = try RSSFeedParser().parse(
            data: Data(xml.utf8), responseURL: URL(string: "https://example.com/feed")!
        )

        XCTAssertEqual(feed.title, "配信 First <feed-code>\n配信 Second")
        XCTAssertEqual(feed.articles.first?.title, "記事 First <entry-code>\n記事 Second")
    }

    func testMaximumLengthUnterminatedHTMLMarkupRemainsBoundedLiteralText() throws {
        let payload = String(repeating: "<", count: RSSFeedParser.maximumTextLength)
        let xml = """
        <rss><channel><item><guid>bounded</guid><title>Title</title>
        <description><![CDATA[\(payload)]]></description>
        </item></channel></rss>
        """

        let summary = try XCTUnwrap(RSSFeedParser().parse(
            data: Data(xml.utf8), responseURL: URL(string: "https://example.com/feed")!
        ).articles.first).summary

        XCTAssertEqual(summary.count, RSSFeedParser.maximumTextLength)
        XCTAssertTrue(summary.allSatisfy { $0 == "<" })
    }

    func testRSSEscapedAndCDATAHTMLProduceTheSameInertReadableBody() throws {
        let source = URL(string: "https://example.com/feed")!
        let escaped = """
        <rss><channel><item><guid>escaped</guid><title>Apple &lt;News&gt;</title>
        <description>&lt;p&gt;First&amp;nbsp;paragraph.&lt;/p&gt;&lt;p&gt;&lt;a href=&quot;https://example.com&quot;&gt;Second&lt;/a&gt; &amp;copy;&lt;/p&gt;</description>
        </item></channel></rss>
        """
        let cdata = """
        <rss><channel><item><guid>cdata</guid><title>Apple &lt;News&gt;</title>
        <description><![CDATA[<p>First&nbsp;paragraph.</p><p><a href="https://example.com">Second</a> &copy;</p>]]></description>
        </item></channel></rss>
        """

        let escapedArticle = try XCTUnwrap(RSSFeedParser().parse(data: Data(escaped.utf8), responseURL: source).articles.first)
        let cdataArticle = try XCTUnwrap(RSSFeedParser().parse(data: Data(cdata.utf8), responseURL: source).articles.first)

        XCTAssertEqual(escapedArticle.title, "Apple <News>")
        XCTAssertEqual(escapedArticle.summary, "First paragraph.\nSecond ©")
        XCTAssertEqual(cdataArticle.summary, escapedArticle.summary)
    }

    func testRSSMixedCharacterAndCDATAHTMLKeepsParagraphBoundaries() throws {
        let source = URL(string: "https://example.com/feed")!
        let mixed = """
        <rss><channel><item><guid>mixed</guid><title>Title</title>
        <description>before<![CDATA[<p>inside</p>]]>after</description>
        </item></channel></rss>
        """
        let escaped = """
        <rss><channel><item><guid>escaped</guid><title>Title</title>
        <description>before&lt;p&gt;inside&lt;/p&gt;after</description>
        </item></channel></rss>
        """

        let mixedBody = try XCTUnwrap(RSSFeedParser().parse(data: Data(mixed.utf8), responseURL: source).articles.first).summary
        let escapedBody = try XCTUnwrap(RSSFeedParser().parse(data: Data(escaped.utf8), responseURL: source).articles.first).summary
        XCTAssertEqual(mixedBody, "before\ninside\nafter")
        XCTAssertEqual(mixedBody, escapedBody)
    }

    func testEmptyDTDIsRejectedInASCIICompatibleAndUnicodeEncodings() throws {
        let source = URL(string: "https://example.com/feed")!
        let variants: [(String, String.Encoding)] = [
            ("ISO-8859-1", .isoLatin1), ("windows-1252", .windowsCP1252),
            ("UTF-8", .utf8), ("UTF-16", .utf16),
            ("UTF-16LE", .utf16LittleEndian), ("UTF-16BE", .utf16BigEndian),
            ("UTF-32", .utf32), ("UTF-32LE", .utf32LittleEndian), ("UTF-32BE", .utf32BigEndian),
        ]
        for (label, encoding) in variants {
            let body = "<rss><!-- literal <!ENTITY example> --><channel><title>café</title><item><title>Article</title><description><![CDATA[literal <!DOCTYPE example>]]></description></item></channel></rss>"
            let declaration = "<?xml version=\"1.0\" encoding=\"\(label)\"?>"
            if !label.hasPrefix("UTF-32") {
                // Darwin XMLParser does not consistently accept safe UTF-32
                // documents. All of their DTD declarations must still be
                // rejected by preflight, before reaching that parser.
                let safe = try XCTUnwrap((declaration + body).data(using: encoding))
                XCTAssertEqual(try RSSFeedParser().parse(data: safe, responseURL: source).title, "café", label)
            }
            let unsafe = try XCTUnwrap((declaration + "<!DOCTYPE rss>" + body).data(using: encoding))
            XCTAssertThrowsError(try RSSFeedParser().parse(data: unsafe, responseURL: source), label) {
                XCTAssertEqual($0 as? FeedError, .unsafeXML, label)
            }
            let unsafeEntity = try XCTUnwrap((declaration + "<!ENTITY example 'value'>" + body).data(using: encoding))
            XCTAssertThrowsError(try RSSFeedParser().parse(data: unsafeEntity, responseURL: source), label) {
                XCTAssertEqual($0 as? FeedError, .unsafeXML, label)
            }
        }
    }

    func testMalformedCommentContainingDeclarationExampleRemainsMalformedXML() throws {
        let xml = "<rss><!-- literal <!DOCTYPE example><channel/></rss>"
        XCTAssertThrowsError(try RSSFeedParser().parse(
            data: Data(xml.utf8), responseURL: URL(string: "https://example.com/feed")!
        )) {
            XCTAssertEqual($0 as? FeedError, .malformedXML)
        }
    }

    func testDeclarationKeywordPrefixesAreNotTreatedAsDTDDeclarations() throws {
        let source = URL(string: "https://example.com/feed")!
        for xml in ["<!DOCTYPEexample><rss/>", "<!ENTITYexample><rss/>"] {
            XCTAssertThrowsError(try RSSFeedParser().parse(data: Data(xml.utf8), responseURL: source)) {
                XCTAssertEqual($0 as? FeedError, .malformedXML)
            }
        }
    }

    func testConcurrentSourceUpdateCannotBeOverwrittenByWaitingStaleTranslation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("feed-library.sqlite")
        let gate = SQLiteWriteContentionGate()
        let store = try FeedLibraryStore(url: database, onWriteContention: { gate.pauseOnce() })
        let subscription = try FeedSubscription(url: URL(string: "https://example.com/feed")!)
        let before = FeedArticle(id: "article", feedID: subscription.id, title: "Before", url: nil, content: "Old source")
        try await store.saveFetchedFeed(ParsedFeed(id: subscription.id, sourceURL: subscription.url, title: "Feed", articles: [before]))
        let stale = ArticleTranslation(articleID: before.id, sourceFingerprint: before.sourceFingerprint, targetLanguage: "ja", title: "古い訳", body: "古い本文")
        let after = FeedArticle(id: before.id, feedID: before.feedID, title: "After", url: nil, content: "Updated source")
        let fresh = ArticleTranslation(articleID: after.id, sourceFingerprint: after.sourceFingerprint, targetLanguage: "ja", title: "新しい訳", body: "新しい本文")
        let otherScene = try FeedTestSQLiteConnection(url: database)
        try otherScene.execute("BEGIN IMMEDIATE")
        defer {
            gate.release()
            try? otherScene.execute("ROLLBACK")
        }

        let saving = Task { try await store.saveTranslation(stale) }
        // Synchronize on SQLite's actual writer contention, rather than a delay
        // or the order in which the two Swift tasks happened to be scheduled.
        await fulfillment(of: [gate.started], timeout: 5)
        try otherScene.execute("UPDATE articles SET title=?,content=? WHERE id=?", values: [after.title, after.content, after.id])
        try otherScene.execute(
            "INSERT INTO translations(article_id,source_fingerprint,target_language,title,body) VALUES(?,?,?,?,?)",
            values: [fresh.articleID, fresh.sourceFingerprint, fresh.targetLanguage, fresh.title, fresh.body]
        )
        try otherScene.execute("COMMIT")
        gate.release()

        do {
            try await saving.value
            XCTFail("A translation waiting behind a newer source update must be rejected")
        } catch { XCTAssertEqual(error as? FeedError, .staleTranslation) }
        XCTAssertFalse(gate.timedOut)
        let retained = try await store.translation(articleID: after.id, targetLanguage: "ja")
        XCTAssertEqual(retained, fresh)
        // The rejected transaction must also leave the connection ready for a
        // subsequent valid save, with the newer record still intact.
        try await store.saveTranslation(fresh)
        let reopened = try FeedLibraryStore(url: database)
        let persisted = try await reopened.translation(articleID: after.id, targetLanguage: "ja")
        XCTAssertEqual(persisted, fresh)
    }

    func testCDATAEntitiesDecodeOnceAndAtomParagraphsRemainSeparate() throws {
        let xml = """
        <feed><title>x</title><entry><id>one</id>
        <title><![CDATA[&amp;copy;]]></title>
        <content type="xhtml"><div><p>first</p><p>second <b>line</b></p></div></content>
        </entry></feed>
        """
        let feed = try RSSFeedParser().parse(data: Data(xml.utf8), responseURL: URL(string: "https://example.com/feed")!)
        XCTAssertEqual(feed.articles[0].title, "&amp;copy;")
        XCTAssertEqual(feed.articles[0].content, "first\nsecond line")
    }

    func testRSSHTMLHandlesGeneralNamedEntitiesAndPreservesPlainCDATAHeading() throws {
        let xml = """
        <rss><channel><title>x</title><item><guid>entities-and-code</guid>
        <title><![CDATA[<b>literal</b> &copy;]]></title>
        <description><![CDATA[Use <T> here <a title="1 > 0">and this link</a>: &eacute; &rarr;.]]></description>
        </item></channel></rss>
        """

        let article = try XCTUnwrap(RSSFeedParser().parse(
            data: Data(xml.utf8), responseURL: URL(string: "https://example.com/feed")!
        ).articles.first)

        XCTAssertEqual(article.title, "<b>literal</b> &copy;")
        XCTAssertEqual(article.summary, "Use <T> here and this link: é →.")
    }

    func testRemovedSubscriptionCannotBeRecreatedByLateStore() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = URL(string: "https://example.com/feed")!
        let store = try FeedLibraryStore(directory: directory)
        let subscription = try await store.addSubscription(url: source)
        try await store.removeSubscription(id: subscription.id)
        let feed = ParsedFeed(id: subscription.id, sourceURL: subscription.url, title: "late", articles: [])

        let saved = try await store.saveFetchedFeedIfSubscribed(feed)

        XCTAssertFalse(saved)
        let subscriptions = try await store.subscriptions()
        XCTAssertTrue(subscriptions.isEmpty)
    }

    func testAtomNamespaceBaseAndEntitiesRemainInertText() throws {
        let xml = """
        <atom:feed xmlns:atom="http://www.w3.org/2005/Atom" xml:base="https://example.com/news/">
          <atom:title>配信</atom:title><atom:entry><atom:id>entry-1</atom:id>
          <atom:title type="html"><![CDATA[<em>日本語</em> &amp; &#169;]]></atom:title>
          <atom:link href="today#section"/><atom:summary type="xhtml"><div>要約 <b>本文</b></div></atom:summary>
          <atom:content type="xhtml"><div>完全 <span>本文</span></div></atom:content>
          <atom:published>2024-01-02T03:04:05+09:00</atom:published></atom:entry>
        </atom:feed>
        """
        let feed = try RSSFeedParser().parse(
            data: Data(xml.utf8), responseURL: URL(string: "https://origin.example/feed.xml")!
        )

        XCTAssertEqual(feed.title, "配信")
        XCTAssertEqual(feed.articles[0].url?.absoluteString, "https://example.com/news/today")
        XCTAssertEqual(feed.articles[0].title, "日本語 & ©")
        XCTAssertEqual(feed.articles[0].summary, "要約 本文")
        XCTAssertEqual(feed.articles[0].content, "完全 本文")
        XCTAssertNotNil(feed.articles[0].publishedAt)
    }

    func testAtomXHTMLChildrenDoNotReplaceEntryMetadata() throws {
        let xml = """
        <feed><title>Feed</title><entry><id>entry</id><title>Entry</title>
        <link href="https://example.com/original"/>
        <content type="xhtml"><div><summary>Nested summary</summary><link href="https://example.com/embedded">Linked text</link></div></content>
        </entry></feed>
        """

        let article = try XCTUnwrap(RSSFeedParser().parse(
            data: Data(xml.utf8), responseURL: URL(string: "https://example.com/feed")!
        ).articles.first)

        XCTAssertEqual(article.title, "Entry")
        XCTAssertEqual(article.summary, "")
        XCTAssertEqual(article.content, "Nested summaryLinked text")
        XCTAssertEqual(article.url?.absoluteString, "https://example.com/original")
    }

    func testRefreshKeepsBookmarkButRejectsStaleTranslation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("feed-library-regression", isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = URL(string: "https://example.com/feed.xml")!
        let parser = RSSFeedParser()
        let first = try parser.parse(data: Data("<rss><channel><title>x</title><item><guid>g</guid><title>before</title><description>body</description></item></channel></rss>".utf8), responseURL: source)
        let store = try FeedLibraryStore(directory: directory)
        try await store.saveFetchedFeed(first)
        let initialArticles = try await store.articles()
        let article = try XCTUnwrap(initialArticles.first)
        let isNowBookmarked = try await store.toggleBookmark(articleID: article.id)
        XCTAssertTrue(isNowBookmarked)
        try await store.saveTranslation(ArticleTranslation(articleID: article.id, sourceFingerprint: article.sourceFingerprint, targetLanguage: "ja", title: "訳", body: "訳文"))

        let updated = try parser.parse(data: Data("<rss><channel><title>x</title><item><guid>g</guid><title>after</title><description>new body</description></item></channel></rss>".utf8), responseURL: source)
        try await store.saveFetchedFeed(updated)
        let bookmarks = try await store.bookmarkedArticles()
        let translation = try await store.translation(articleID: article.id, targetLanguage: "ja")
        XCTAssertEqual(bookmarks.map(\.id), [article.id])
        XCTAssertNil(translation)

        let stale = ArticleTranslation(articleID: article.id, sourceFingerprint: article.sourceFingerprint, targetLanguage: "fr", title: "ancien", body: "ancien")
        do {
            try await store.saveTranslation(stale)
            XCTFail("A translation of an old source snapshot must not be saved")
        } catch { XCTAssertEqual(error as? FeedError, .staleTranslation) }
    }

    func testSummaryOnlySourceChangeInvalidatesCachedTranslation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = URL(string: "https://example.com/feed")!
        let parser = RSSFeedParser()
        let first = try parser.parse(
            data: Data("<rss><channel><title>x</title><item><guid>g</guid><title>same</title><description>first summary</description></item></channel></rss>".utf8),
            responseURL: source
        )
        let store = try FeedLibraryStore(directory: directory)
        try await store.saveFetchedFeed(first)
        let storedArticles = try await store.articles()
        let article = try XCTUnwrap(storedArticles.first)
        try await store.saveTranslation(ArticleTranslation(
            articleID: article.id,
            sourceFingerprint: article.sourceFingerprint,
            targetLanguage: "ja",
            title: "同じ",
            body: "最初"
        ))

        let second = try parser.parse(
            data: Data("<rss><channel><title>x</title><item><guid>g</guid><title>same</title><description>second summary</description></item></channel></rss>".utf8),
            responseURL: source
        )
        XCTAssertNotEqual(first.articles[0].sourceFingerprint, second.articles[0].sourceFingerprint)
        try await store.saveFetchedFeed(second)

        let staleTranslation = try await store.translation(articleID: article.id, targetLanguage: "ja")
        XCTAssertNil(staleTranslation)
    }

    func testTranslationReadUsesOneSnapshotAcrossSQLiteHandles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("feed-library.sqlite")
        let source = URL(string: "https://example.com/feed")!
        let subscription = try FeedSubscription(url: source)
        let article = FeedArticle(id: "snapshot", feedID: subscription.id, title: "Before", url: nil, content: "Old source")
        let store = try FeedLibraryStore(url: database)
        try await store.saveFetchedFeed(ParsedFeed(id: subscription.id, sourceURL: source, title: "Feed", articles: [article]))
        try await store.saveTranslation(ArticleTranslation(
            articleID: article.id, sourceFingerprint: article.sourceFingerprint,
            targetLanguage: "ja", title: "以前", body: "古い本文"
        ))

        // Leave the old cache row in place while another scene commits a new
        // source. The cache lookup must compare both rows from one SQL snapshot.
        let otherScene = try FeedTestSQLiteConnection(url: database)
        try otherScene.execute("BEGIN IMMEDIATE")
        try otherScene.execute(
            "UPDATE articles SET title=?,content=? WHERE id=?",
            values: ["After", "New source", article.id]
        )
        try otherScene.execute("COMMIT")

        let cachedTranslation = try await store.translation(articleID: article.id, targetLanguage: "ja")
        XCTAssertNil(cachedTranslation)
    }

    func testConditionalHTTPAndRedirectedDocumentBaseKeepSubscriptionIdentity() async throws {
        let source = URL(string: "https://EXAMPLE.com:443/feed.xml#fragment")!
        let final = URL(string: "https://cdn.example.net/feeds/current.xml")!
        let subscription = try FeedSubscription(url: source, eTag: "old-tag", lastModified: "yesterday")
        let recorder = RequestRecorder()
        let xml = "<rss><channel><title>x</title><item><guid>1</guid><title>a</title><link>story</link></item></channel></rss>"
        let response = try XCTUnwrap(HTTPURLResponse(url: final, statusCode: 200, httpVersion: nil, headerFields: ["ETag": "new-tag"]))
        let client = FeedHTTPClient(transport: StubTransport(data: Data(xml.utf8), response: response, recorder: recorder))

        let result = try await client.fetch(subscription)
        let recordedRequest = await recorder.last
        let request = try XCTUnwrap(recordedRequest)
        XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "old-tag")
        XCTAssertEqual(request.value(forHTTPHeaderField: "If-Modified-Since"), "yesterday")
        guard case .updated(let feed, let eTag, _) = result else { return XCTFail("Expected an updated feed") }
        XCTAssertEqual(feed.id, subscription.id)
        XCTAssertEqual(feed.sourceURL, subscription.url)
        XCTAssertEqual(feed.articles[0].feedID, subscription.id)
        XCTAssertEqual(feed.articles[0].url?.absoluteString, "https://cdn.example.net/feeds/story")
        XCTAssertEqual(eTag, "new-tag")

        let notModified = try XCTUnwrap(HTTPURLResponse(url: source, statusCode: 304, httpVersion: nil, headerFields: nil))
        let unchanged = try await FeedHTTPClient(transport: StubTransport(data: Data(), response: notModified, recorder: recorder)).fetch(subscription)
        XCTAssertEqual(unchanged, .notModified)

        let downgraded = try XCTUnwrap(HTTPURLResponse(url: URL(string: "http://example.com/feed")!, statusCode: 200, httpVersion: nil, headerFields: nil))
        do {
            _ = try await FeedHTTPClient(transport: StubTransport(data: Data(xml.utf8), response: downgraded, recorder: recorder)).fetch(subscription)
            XCTFail("A redirect downgrade must be rejected")
        } catch { XCTAssertEqual(error as? FeedError, .redirectDowngrade) }
    }

    func testUTF16DTDAndOversizedResponsesAreRejected() async throws {
        let source = URL(string: "https://example.com/feed")!
        let unsafe = "<?xml version=\"1.0\" encoding=\"UTF-16\"?><!DOCTYPE rss [<!ENTITY x SYSTEM \"file:///etc/passwd\">]><rss/>"
        XCTAssertThrowsError(try RSSFeedParser().parse(data: unsafe.data(using: .utf16)!, responseURL: source)) {
            XCTAssertEqual($0 as? FeedError, .unsafeXML)
        }
        let response = try XCTUnwrap(HTTPURLResponse(url: source, statusCode: 200, httpVersion: nil, headerFields: nil))
        let bytes = Data(repeating: 0x20, count: 2 * 1024 * 1024 + 1)
        do {
            _ = try await FeedHTTPClient(transport: StubTransport(data: bytes, response: response, recorder: RequestRecorder())).fetch(try FeedSubscription(url: source))
            XCTFail("Oversized responses must fail before XML parsing")
        } catch { XCTAssertEqual(error as? FeedError, .responseTooLarge) }
    }

    func testFractionalAtomDateLinkBaseAndIdempotentBookmarkRemovalPersistence() async throws {
        let source = URL(string: "https://example.com/feed")!
        let xml = """
        <feed><title>x</title><entry><id>same</id><title>a</title>
        <link xml:base="https://assets.example/path/" href="article"/>
        <updated>2024-01-02T03:04:05.678Z</updated></entry></feed>
        """
        let feed = try RSSFeedParser().parse(data: Data(xml.utf8), responseURL: source)
        let unbookmarked = FeedArticle(id: "unbookmarked", feedID: feed.id, title: "discard", url: nil)
        let storedFeed = ParsedFeed(id: feed.id, sourceURL: feed.sourceURL, title: feed.title, articles: feed.articles + [unbookmarked])
        XCTAssertNotNil(feed.articles[0].publishedAt)
        XCTAssertEqual(feed.articles[0].url?.absoluteString, "https://assets.example/path/article")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FeedLibraryStore(directory: directory)
        try await store.saveFetchedFeed(storedFeed)
        let articleID = feed.articles[0].id
        try await store.setBookmarked(articleID: articleID, bookmarked: true)
        try await store.setBookmarked(articleID: articleID, bookmarked: true)
        try await store.removeSubscription(id: feed.id)
        let reopened = try FeedLibraryStore(directory: directory)
        let bookmarks = try await reopened.bookmarkedArticles()
        let remaining = try await reopened.articles(feedID: feed.id, limit: 10)
        XCTAssertEqual(bookmarks.map(\.id), [articleID])
        XCTAssertEqual(remaining.map(\.id), [articleID])
    }

    func testUnbookmarkingRetainedArticleFromRemovedSubscriptionDeletesSnapshotAndTranslation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let subscription = try FeedSubscription(url: URL(string: "https://example.com/feed")!)
        let article = FeedArticle(id: "retained", feedID: subscription.id, title: "Title", url: nil, content: "Source")
        let translation = ArticleTranslation(
            articleID: article.id,
            sourceFingerprint: article.sourceFingerprint,
            targetLanguage: "ja",
            title: "題",
            body: "翻訳"
        )
        let store = try FeedLibraryStore(directory: directory)
        try await store.saveFetchedFeed(ParsedFeed(
            id: subscription.id,
            sourceURL: subscription.url,
            title: "Feed",
            articles: [article]
        ))
        try await store.saveTranslation(translation)
        try await store.setBookmarked(articleID: article.id, bookmarked: true)
        try await store.removeSubscription(id: subscription.id)

        try await store.setBookmarked(articleID: article.id, bookmarked: false)
        try await store.setBookmarked(articleID: article.id, bookmarked: false)

        let bookmarks = try await store.bookmarkedArticles()
        let articles = try await store.articles()
        XCTAssertTrue(bookmarks.isEmpty)
        XCTAssertTrue(articles.isEmpty)
        do {
            _ = try await store.translation(articleID: article.id, targetLanguage: "ja")
            XCTFail("Removing the final bookmark must remove its orphaned translation")
        } catch {
            XCTAssertEqual(error as? FeedError, .articleNotFound)
        }
        let reopened = try FeedLibraryStore(directory: directory)
        let persistedArticles = try await reopened.articles()
        XCTAssertTrue(persistedArticles.isEmpty)
    }

    func testIdentityIsFeedScopedAndDuplicateEntriesUpdateDeterministically() throws {
        let xml = """
        <rss><channel><title>x</title>
        <item><guid>shared</guid><title>old</title></item>
        <item><guid>shared</guid><title>new</title></item>
        </channel></rss>
        """
        let parser = RSSFeedParser()
        let first = try parser.parse(data: Data(xml.utf8), responseURL: URL(string: "https://one.example/feed")!)
        let second = try parser.parse(data: Data(xml.utf8), responseURL: URL(string: "https://two.example/feed")!)
        XCTAssertEqual(first.articles.count, 1)
        XCTAssertEqual(first.articles[0].title, "new")
        XCTAssertNotEqual(first.articles[0].id, second.articles[0].id)
    }

    func testFutureAndMalformedSchemasArePreserved() throws {
        for sql in ["PRAGMA user_version=99", "CREATE TABLE subscriptions(id INTEGER); PRAGMA user_version=1"] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let database = directory.appendingPathComponent("feed-library.sqlite")
            var db: OpaquePointer?
            XCTAssertEqual(sqlite3_open(database.path, &db), SQLITE_OK)
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
            sqlite3_close(db)
            let before = try Data(contentsOf: database)
            XCTAssertThrowsError(try FeedLibraryStore(directory: directory))
            XCTAssertEqual(try Data(contentsOf: database), before)
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = directory.appendingPathComponent("feed-library.sqlite")
        let corrupt = Data("not a sqlite database".utf8)
        try corrupt.write(to: database)
        XCTAssertThrowsError(try FeedLibraryStore(directory: directory)) {
            XCTAssertEqual($0 as? FeedError, .corrupted)
        }
        XCTAssertEqual(try Data(contentsOf: database), corrupt)
    }
}

private final class SQLiteWriteContentionGate: @unchecked Sendable {
    let started = XCTestExpectation(description: "translation reached a held SQLite write lock")
    private let lock = NSLock()
    private let resume = DispatchSemaphore(value: 0)
    private var entered = false
    private var expired = false

    var timedOut: Bool { lock.withLock { expired } }

    func pauseOnce() {
        let shouldPause = lock.withLock {
            guard !entered else { return false }
            entered = true
            return true
        }
        guard shouldPause else { return }
        started.fulfill()
        if resume.wait(timeout: .now() + 10) == .timedOut {
            lock.withLock { expired = true }
        }
    }

    func release() { resume.signal() }
}

private final class FeedTestSQLiteConnection {
    private let db: OpaquePointer

    init(url: URL) throws {
        var opened: OpaquePointer?
        guard sqlite3_open(url.path, &opened) == SQLITE_OK, let opened else {
            if let opened { sqlite3_close(opened) }
            throw FeedError.unavailable
        }
        db = opened
    }

    deinit { sqlite3_close(db) }

    func execute(_ sql: String, values: [String] = []) throws {
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &prepared, nil) == SQLITE_OK, let statement = prepared else {
            throw FeedError.unavailable
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            guard value.withCString({ sqlite3_bind_text(statement, Int32(offset + 1), $0, -1, transient) }) == SQLITE_OK else {
                throw FeedError.unavailable
            }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw FeedError.unavailable }
    }
}

private actor RequestRecorder {
    private(set) var last: URLRequest?
    func record(_ request: URLRequest) { last = request }
}

private struct StubTransport: FeedHTTPTransport, @unchecked Sendable {
    let data: Data
    let response: HTTPURLResponse
    let recorder: RequestRecorder
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        await recorder.record(request)
        return (data, response)
    }
}

// Append to FeedLibraryRegressionTests.swift so the existing private SQLite
// contention gate and connection helpers remain available in this file.
extension FeedLibraryRegressionTests {
    func testWaitingBookmarkSaveCannotCreateOrphanAfterOtherConnectionDeletesArticle() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("feed-library.sqlite")
        let gate = SQLiteWriteContentionGate()
        let store = try FeedLibraryStore(url: database, onWriteContention: { gate.pauseOnce() })
        let subscription = try FeedSubscription(url: URL(string: "https://example.com/feed")!)
        let article = FeedArticle(id: "bookmark-race", feedID: subscription.id, title: "Original", url: nil, content: "Source snapshot")
        try await store.saveFetchedFeed(ParsedFeed(id: subscription.id, sourceURL: subscription.url, title: "Feed", articles: [article]))
        try await store.saveTranslation(ArticleTranslation(
            articleID: article.id, sourceFingerprint: article.sourceFingerprint,
            targetLanguage: "ja", title: "題", body: "本文"
        ))
        let initiallyBookmarked = try await store.isBookmarked(articleID: article.id)
        XCTAssertFalse(initiallyBookmarked)
        let otherScene = try FeedTestSQLiteConnection(url: database)
        try otherScene.execute("BEGIN IMMEDIATE")
        defer {
            gate.release()
            try? otherScene.execute("ROLLBACK")
        }

        let saving = Task { try await store.setBookmarked(articleID: article.id, bookmarked: true) }
        // The actual SQLite busy callback proves A reached B's held writer lock;
        // no assumed task order or timed sleep controls this interleaving.
        await fulfillment(of: [gate.started], timeout: 5)
        try otherScene.execute("DELETE FROM translations WHERE article_id=?", values: [article.id])
        try otherScene.execute("DELETE FROM articles WHERE id=?", values: [article.id])
        try otherScene.execute("DELETE FROM subscriptions WHERE id=?", values: [subscription.id])
        try otherScene.execute("COMMIT")
        gate.release()

        do {
            _ = try await saving.value
            XCTFail("The bookmark save must recheck existence after the other connection commits deletion")
        } catch { XCTAssertEqual(error as? FeedError, .articleNotFound) }
        XCTAssertFalse(gate.timedOut)
        let stillBookmarked = try await store.isBookmarked(articleID: article.id)
        let articles = try await store.articles()
        let subscriptions = try await store.subscriptions()
        let bookmarks = try await store.bookmarkedArticles()
        XCTAssertFalse(stillBookmarked)
        XCTAssertTrue(articles.isEmpty)
        XCTAssertTrue(subscriptions.isEmpty)
        XCTAssertTrue(bookmarks.isEmpty)
        // Check the physical table too: a JOIN-based listing could hide an orphan.
        let orphanCount = try otherScene.regressionScalarInteger("SELECT count(*) FROM bookmarks b LEFT JOIN articles a ON a.id=b.article_id WHERE a.id IS NULL")
        let translationCount = try otherScene.regressionScalarInteger("SELECT count(*) FROM translations")
        XCTAssertEqual(orphanCount, 0)
        XCTAssertEqual(translationCount, 0)
        let reopened = try FeedLibraryStore(url: database)
        let persistedBookmark = try await reopened.isBookmarked(articleID: article.id)
        let persistedArticles = try await reopened.articles()
        XCTAssertFalse(persistedBookmark)
        XCTAssertTrue(persistedArticles.isEmpty)
    }

    func testBookmarkCommittedBeforeOtherConnectionRemovesSubscriptionKeepsSnapshotAndTranslation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("feed-library.sqlite")
        let savingScene = try FeedLibraryStore(url: database)
        let removingScene = try FeedLibraryStore(url: database)
        let subscription = try FeedSubscription(url: URL(string: "https://example.com/feed")!)
        let article = FeedArticle(id: "retained-bookmark-race", feedID: subscription.id, title: "Original", url: nil, content: "Offline snapshot")
        let translation = ArticleTranslation(
            articleID: article.id, sourceFingerprint: article.sourceFingerprint,
            targetLanguage: "ja", title: "保存した題", body: "保存した本文"
        )
        try await savingScene.saveFetchedFeed(ParsedFeed(id: subscription.id, sourceURL: subscription.url, title: "Feed", articles: [article]))
        try await savingScene.saveTranslation(translation)

        // Completion establishes the reverse commit order through the public APIs.
        try await savingScene.setBookmarked(articleID: article.id, bookmarked: true)
        try await removingScene.removeSubscription(id: subscription.id)

        let subscriptions = try await removingScene.subscriptions()
        let bookmarks = try await savingScene.bookmarkedArticles()
        let articles = try await removingScene.articles()
        let retainedTranslation = try await savingScene.translation(articleID: article.id, targetLanguage: "ja")
        XCTAssertTrue(subscriptions.isEmpty)
        XCTAssertEqual(bookmarks, [article])
        XCTAssertEqual(articles, [article])
        XCTAssertEqual(retainedTranslation, translation)
        let reopened = try FeedLibraryStore(url: database)
        let reopenedArticles = try await reopened.bookmarkedArticles()
        let reopenedTranslation = try await reopened.translation(articleID: article.id, targetLanguage: "ja")
        XCTAssertEqual(reopenedArticles, [article])
        XCTAssertEqual(reopenedTranslation, translation)
    }
}

private extension FeedTestSQLiteConnection {
    func regressionScalarInteger(_ sql: String) throws -> Int64 {
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &prepared, nil) == SQLITE_OK, let statement = prepared else {
            throw FeedError.unavailable
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_type(statement, 0) == SQLITE_INTEGER else {
            throw FeedError.corrupted
        }
        return sqlite3_column_int64(statement, 0)
    }
}
