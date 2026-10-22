import Foundation
import XCTest
import CSQLite
@testable import TextbookCore

@MainActor
final class HistoryStoreTests: XCTestCase {
    private var directory: URL!
    private var database: URL { directory.appendingPathComponent("answers.sqlite") }
    private let book = Textbook.introductory

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tsumiki-history-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testAnswersSurviveReopeningAndRetainTheirFeedbackResult() async throws {
        let store = try HistoryStore(url: database)
        let correct = try book.answer(questionID: "model-action", optionID: "text", at: Date(timeIntervalSince1970: 100))
        let incorrect = try book.answer(questionID: "tool-result", optionID: "guess", at: Date(timeIntervalSince1970: 200))
        try await store.save(correct, for: book)
        try await store.save(incorrect, for: book)

        let reopened = try HistoryStore(url: database)
        let restored = try await reopened.attempts(for: book)
        XCTAssertEqual(restored, [correct, incorrect])
        XCTAssertTrue(restored[0].isCorrect)
        XCTAssertFalse(restored[1].isCorrect)
    }

    func testRetryIsIdempotentAndConflictingIDNeverOverwrites() async throws {
        let store = try HistoryStore(url: database)
        let answer = try book.answer(
            questionID: "model-action", optionID: "text",
            at: Date(timeIntervalSinceReferenceDate: 814000000.0000001)
        )
        try await store.save(answer, for: book)
        try await store.save(answer, for: book)
        let reopened = try HistoryStore(url: database)
        try await reopened.save(answer, for: book)
        let conflicting = try book.answer(questionID: "model-action", optionID: "saved", id: answer.id, at: answer.answeredAt)
        do {
            try await store.save(conflicting, for: book)
            XCTFail("A reused ID with different content must fail")
        } catch { XCTAssertEqual(error as? HistoryError, .conflictingAttempt) }
        let restored = try await reopened.attempts(for: book)
        XCTAssertEqual(restored, [answer])
    }

    func testTextbookVersionsRemainSeparateAndMismatchIsRejected() async throws {
        let store = try HistoryStore(url: database)
        let next = Textbook(id: book.id, version: 2, title: book.title, sections: book.sections)
        let oldAnswer = try book.answer(questionID: "model-action", optionID: "text")
        try await store.save(oldAnswer, for: book)
        let nextHistory = try await store.attempts(for: next)
        XCTAssertTrue(nextHistory.isEmpty)
        do {
            try await store.save(oldAnswer, for: next)
            XCTFail("An answer from a different textbook version must fail")
        } catch { XCTAssertEqual(error as? HistoryError, .textbookVersionMismatch) }
        let newAnswer = try next.answer(questionID: "model-action", optionID: "saved")
        try await store.save(newAnswer, for: next)
        let oldHistory = try await store.attempts(for: book)
        let newHistory = try await store.attempts(for: next)
        XCTAssertEqual(oldHistory, [oldAnswer])
        XCTAssertEqual(newHistory, [newAnswer])
    }

    func testFailedWriteRetainsExistingHistoryAndCanBeRetried() async throws {
        let store = try HistoryStore(url: database)
        let first = try book.answer(questionID: "model-action", optionID: "text")
        try await store.save(first, for: book)
        try execute("CREATE TRIGGER simulate_write_failure BEFORE INSERT ON answer_attempts BEGIN SELECT RAISE(ABORT, 'simulated write failure'); END")
        let pending = try book.answer(questionID: "agent-stop", optionID: "hold")
        do {
            try await store.save(pending, for: book)
            XCTFail("Write failure must be reported")
        } catch { XCTAssertEqual(error as? HistoryError, .unavailable) }
        let retained = try await store.attempts(for: book)
        XCTAssertEqual(retained, [first])
        try execute("DROP TRIGGER simulate_write_failure")
        try await store.save(pending, for: book)
        let retried = try await store.attempts(for: book)
        XCTAssertEqual(Set(retried.map(\.id)), Set([first.id, pending.id]))
    }

    func testCorruptedFileIsReportedAndNotReplaced() throws {
        let bytes = Data("This is not a SQLite database. Preserve me.".utf8)
        try bytes.write(to: database)
        XCTAssertThrowsError(try HistoryStore(url: database)) { error in
            XCTAssertEqual(error as? HistoryError, .corrupted)
        }
        XCTAssertEqual(try Data(contentsOf: database), bytes)
    }

    func testUnknownSchemaIsPreserved() throws {
        try execute("PRAGMA user_version = 99")
        let bytes = try Data(contentsOf: database)
        XCTAssertThrowsError(try HistoryStore(url: database)) { error in
            XCTAssertEqual(error as? HistoryError, .unsupportedSchema(99))
        }
        XCTAssertEqual(try Data(contentsOf: database), bytes)
    }

    func testInvalidStoredResultIsReportedWithoutRepairingIt() async throws {
        let store = try HistoryStore(url: database)
        let answer = try book.answer(questionID: "model-action", optionID: "text")
        try await store.save(answer, for: book)
        try execute("UPDATE answer_attempts SET is_correct = 0")
        let bytes = try Data(contentsOf: database)
        do {
            _ = try await store.attempts(for: book)
            XCTFail("Stored result contradicting this textbook must be reported")
        } catch { XCTAssertEqual(error as? HistoryError, .corrupted) }
        XCTAssertEqual(try Data(contentsOf: database), bytes)
    }

    func testInvalidChoiceIsRejectedBeforePersistence() throws {
        XCTAssertThrowsError(try book.answer(questionID: "model-action", optionID: "unknown"))
        XCTAssertThrowsError(try book.answer(questionID: "unknown", optionID: "text"))
    }

    func testLargeStoredBooleanIntegersAreRejectedWithoutTruncation() async throws {
        for invalidValue in [Int64(4294967296), Int64(4294967297)] {
            let store = try HistoryStore(url: database)
            if try await store.attempts(for: book).isEmpty {
                try await store.save(book.answer(questionID: "model-action", optionID: "text"), for: book)
            }
            try execute("PRAGMA ignore_check_constraints = ON; UPDATE answer_attempts SET is_correct = \(invalidValue)")
            do {
                _ = try await store.attempts(for: book)
                XCTFail("Out-of-range stored booleans must be rejected")
            } catch { XCTAssertEqual(error as? HistoryError, .corrupted) }
            try execute("UPDATE answer_attempts SET is_correct = 1")
        }
    }

    private func execute(_ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(database.path, &db) == SQLITE_OK, let db else {
            throw HistoryError.unavailable
        }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw HistoryError.unavailable }
    }
}
