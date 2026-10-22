import Foundation
import CSQLite

public enum HistoryError: Error, LocalizedError, Equatable, Sendable {
    case unavailable
    case corrupted
    case unsupportedSchema(Int)
    case invalidAnswer
    case textbookVersionMismatch
    case conflictingAttempt

    public var errorDescription: String? {
        switch self {
        case .unavailable: "回答履歴を保存・読込できません。保存先の空き容量やアクセス権を確認してください。"
        case .corrupted: "回答履歴の形式を確認できません。既存ファイルは削除・初期化していません。"
        case .unsupportedSchema: "このアプリでは扱えない版の回答履歴です。既存データは変更していません。"
        case .invalidAnswer: "教材に含まれない問題・選択肢、または不正な回答です。"
        case .textbookVersionMismatch: "教材の版が一致しないため、この回答は保存しませんでした。"
        case .conflictingAttempt: "同じ回答IDに異なる内容があるため、上書きしませんでした。"
        }
    }
}

// The handle never escapes HistoryStore. All SQLite operations are actor-isolated;
// this owner only allows deterministic sqlite3_close_v2 from its deinitializer.
private final class SQLiteHandle: @unchecked Sendable {
    let pointer: OpaquePointer
    init(_ pointer: OpaquePointer) { self.pointer = pointer }
    deinit { sqlite3_close_v2(pointer) }
}

public protocol AnswerHistoryStoring: Sendable {
    func save(_ answer: AnswerAttempt, for book: Textbook) async throws
    func attempts(for book: Textbook) async throws -> [AnswerAttempt]
}

public actor HistoryStore: AnswerHistoryStoring {
    private let connection: SQLiteHandle
    private static let schemaVersion = 1

    public init(url: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
        } catch { throw HistoryError.unavailable }
        var opened: OpaquePointer?
        guard sqlite3_open_v2(url.path, &opened, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let opened else {
            if let opened { sqlite3_close_v2(opened) }
            throw HistoryError.unavailable
        }
        let handle = SQLiteHandle(opened)
        connection = handle
        sqlite3_busy_timeout(opened, 2_000)
        guard try Self.scalarText(opened, "PRAGMA quick_check") == "ok" else {
            throw HistoryError.corrupted
        }
        guard let version = Int(try Self.scalarText(opened, "PRAGMA user_version")) else {
            throw HistoryError.corrupted
        }
        guard version == 0 || version == Self.schemaVersion else {
            throw HistoryError.unsupportedSchema(version)
        }
        if version == 0 {
            try Self.execute(opened, "BEGIN IMMEDIATE")
            do {
                guard let lockedVersion = Int(try Self.scalarText(opened, "PRAGMA user_version")) else {
                    throw HistoryError.corrupted
                }
                if lockedVersion == 0 {
                    // Do not adopt an unknown existing database as an empty textbook store.
                    guard try Self.scalarText(opened, "SELECT count(*) FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'") == "0" else {
                        throw HistoryError.corrupted
                    }
                    try Self.execute(opened, """
                        CREATE TABLE answer_attempts (
                            id TEXT PRIMARY KEY NOT NULL,
                            textbook_id TEXT NOT NULL,
                            textbook_version INTEGER NOT NULL CHECK(textbook_version > 0),
                            question_id TEXT NOT NULL,
                            option_id TEXT NOT NULL,
                            is_correct INTEGER NOT NULL CHECK(is_correct IN (0, 1)),
                            answered_at_reference_seconds REAL NOT NULL
                        );
                        CREATE INDEX answer_book_version ON answer_attempts(textbook_id, textbook_version, answered_at_reference_seconds);
                        PRAGMA user_version = 1;
                        """)
                } else if lockedVersion != Self.schemaVersion {
                    throw HistoryError.unsupportedSchema(lockedVersion)
                }
                try Self.execute(opened, "COMMIT")
            } catch {
                try? Self.execute(opened, "ROLLBACK")
                throw error
            }
        }
        // Confirm the existing schema without modifying it.
        let probe = try Self.prepare(opened, "SELECT id, textbook_id, textbook_version, question_id, option_id, is_correct, answered_at_reference_seconds FROM answer_attempts LIMIT 0")
        sqlite3_finalize(probe)
    }

    public func save(_ answer: AnswerAttempt, for book: Textbook) throws {
        try Self.validate(answer, for: book)
        let db = connection.pointer
        let statement = try Self.prepare(db, """
            INSERT INTO answer_attempts
            (id, textbook_id, textbook_version, question_id, option_id, is_correct, answered_at_reference_seconds)
            VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO NOTHING
            """)
        defer { sqlite3_finalize(statement) }
        try Self.bind(answer.id.uuidString, to: 1, in: statement)
        try Self.bind(answer.textbookID, to: 2, in: statement)
        guard sqlite3_bind_int64(statement, 3, Int64(answer.textbookVersion)) == SQLITE_OK else { throw HistoryError.unavailable }
        try Self.bind(answer.questionID, to: 4, in: statement)
        try Self.bind(answer.optionID, to: 5, in: statement)
        guard sqlite3_bind_int(statement, 6, answer.isCorrect ? 1 : 0) == SQLITE_OK,
              sqlite3_bind_double(statement, 7, answer.answeredAt.timeIntervalSinceReferenceDate) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_DONE else { throw HistoryError.unavailable }
        if sqlite3_changes(db) == 0 {
            let existing = try attempts(for: book).first { $0.id == answer.id }
            guard existing == answer else { throw HistoryError.conflictingAttempt }
        }
    }

    public func attempts(for book: Textbook) throws -> [AnswerAttempt] {
        let statement = try Self.prepare(connection.pointer, """
            SELECT id, textbook_id, textbook_version, question_id, option_id, is_correct, answered_at_reference_seconds
            FROM answer_attempts WHERE textbook_id = ? AND textbook_version = ?
            ORDER BY answered_at_reference_seconds ASC, id ASC
            """)
        defer { sqlite3_finalize(statement) }
        try Self.bind(book.id, to: 1, in: statement)
        guard sqlite3_bind_int64(statement, 2, Int64(book.version)) == SQLITE_OK else { throw HistoryError.unavailable }
        var answers: [AnswerAttempt] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_DONE: return answers
            case SQLITE_ROW:
                guard let id = UUID(uuidString: try Self.columnText(statement, 0)),
                      sqlite3_column_type(statement, 2) == SQLITE_INTEGER,
                      sqlite3_column_type(statement, 5) == SQLITE_INTEGER,
                      [Int64(0), Int64(1)].contains(sqlite3_column_int64(statement, 5)),
                      sqlite3_column_type(statement, 6) == SQLITE_FLOAT || sqlite3_column_type(statement, 6) == SQLITE_INTEGER else {
                    throw HistoryError.corrupted
                }
                let answer = AnswerAttempt(
                    id: id, textbookID: try Self.columnText(statement, 1),
                    textbookVersion: Int(sqlite3_column_int64(statement, 2)),
                    questionID: try Self.columnText(statement, 3), optionID: try Self.columnText(statement, 4),
                    isCorrect: sqlite3_column_int64(statement, 5) == 1,
                    answeredAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 6))
                )
                do { try Self.validate(answer, for: book) }
                catch { throw HistoryError.corrupted }
                answers.append(answer)
            default: throw HistoryError.corrupted
            }
        }
    }

    private static func validate(_ answer: AnswerAttempt, for book: Textbook) throws {
        guard answer.textbookID == book.id, answer.textbookVersion == book.version else {
            throw HistoryError.textbookVersionMismatch
        }
        guard let question = book.question(answer.questionID), question.option(answer.optionID) != nil,
              answer.isCorrect == (answer.optionID == question.correctOptionID),
              answer.answeredAt.timeIntervalSince1970.isFinite else { throw HistoryError.invalidAnswer }
    }

    private static func execute(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw HistoryError.unavailable }
    }

    private static func prepare(_ db: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw HistoryError.corrupted
        }
        return statement
    }

    private static func scalarText(_ db: OpaquePointer, _ sql: String) throws -> String {
        let statement = try prepare(db, sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw HistoryError.corrupted }
        guard let value = sqlite3_column_text(statement, 0) else { throw HistoryError.corrupted }
        return String(cString: value)
    }

    private static func columnText(_ statement: OpaquePointer, _ index: Int32) throws -> String {
        guard sqlite3_column_type(statement, index) == SQLITE_TEXT,
              let value = sqlite3_column_text(statement, index) else { throw HistoryError.corrupted }
        return String(cString: value)
    }

    private static func bind(_ text: String, to index: Int32, in statement: OpaquePointer) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard text.withCString({ sqlite3_bind_text(statement, index, $0, -1, transient) }) == SQLITE_OK else {
            throw HistoryError.unavailable
        }
    }
}
