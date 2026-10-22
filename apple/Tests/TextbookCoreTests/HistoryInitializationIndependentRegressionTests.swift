import Foundation
import XCTest
import CSQLite
import TextbookCore

@MainActor
final class HistoryInitializationIndependentRegressionTests: XCTestCase {
    private var directory: URL!
    private var database: URL { directory.appendingPathComponent("answers.sqlite") }

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("independent-history-initialization-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testConcurrentFirstOpenInitializersBothSaveAndReopenTheSameDatabase() async throws {
        let raw = try HistoryInitializationDatabase(url: database)
        XCTAssertEqual(try raw.rows("PRAGMA user_version"), [["integer:0"]])
        XCTAssertTrue(try raw.rows("SELECT name FROM sqlite_schema").isEmpty)

        let outcomes = try await firstOpens(raw: raw, count: 2)
        var stores: [HistoryStore] = []
        for (index, outcome) in outcomes.enumerated() {
            switch outcome {
            case .success(let store): stores.append(store)
            case .failure(let error):
                XCTFail("Concurrent first opener \(index) rejected the same valid database: \(error)")
            }
        }
        guard stores.count == 2 else { return }

        let book = Textbook.introductory
        let first = try book.answer(
            questionID: "model-action", optionID: "text", at: Date(timeIntervalSince1970: 100)
        )
        let second = try book.answer(
            questionID: "tool-result", optionID: "guess", at: Date(timeIntervalSince1970: 200)
        )
        try await stores[0].save(first, for: book)
        try await stores[1].save(second, for: book)
        for store in stores {
            let saved = try await store.attempts(for: book)
            XCTAssertEqual(saved, [first, second], "Both independent connections must see both saved answers")
        }
        let beforeReopen = try raw.snapshot()
        let reopened = try HistoryStore(url: database)
        let restored = try await reopened.attempts(for: book)
        XCTAssertEqual(restored, [first, second])
        XCTAssertEqual(try raw.snapshot(), beforeReopen, "Opening an initialized store must preserve its schema and answers")
    }

    func testFutureVersionCommittedBeforeInitializationLockIsRefusedWithoutMutation() async throws {
        let raw = try HistoryInitializationDatabase(url: database)
        var committed: HistoryInitializationSnapshot?
        let outcomes = try await firstOpens(raw: raw, count: 1) {
            try raw.execute("""
                CREATE TABLE future_owner(value TEXT NOT NULL);
                INSERT INTO future_owner VALUES('retain future history');
                PRAGMA user_version = 99;
                """)
            committed = try raw.snapshot()
        }

        assertRefused(outcomes, as: .unsupportedSchema(99))
        XCTAssertEqual(try raw.snapshot(), try XCTUnwrap(committed))
    }

    func testUnknownSchemaCommittedBeforeInitializationLockIsRefusedWithoutMutation() async throws {
        let raw = try HistoryInitializationDatabase(url: database)
        var committed: HistoryInitializationSnapshot?
        let outcomes = try await firstOpens(raw: raw, count: 1) {
            try raw.execute("""
                CREATE TABLE foreign_owner(value TEXT NOT NULL);
                INSERT INTO foreign_owner VALUES('retain this unversioned database');
                """)
            committed = try raw.snapshot()
        }

        assertRefused(outcomes, as: .corrupted)
        XCTAssertEqual(try raw.snapshot(), try XCTUnwrap(committed))
    }

    /// All initializers stop in SQLite's BEGIN trace, before it acquires the
    /// write lock. In the defective implementation they have already read the
    /// empty version-0 schema. Moving those reads inside the transaction still
    /// reaches this same gate, and lets each opener observe the preceding commit.
    private func firstOpens(
        raw: HistoryInitializationDatabase,
        count: Int,
        beforeCommit: () throws -> Void = {}
    ) async throws -> [Result<HistoryStore, any Error>] {
        try raw.execute("BEGIN IMMEDIATE")
        let gate = HistoryInitializationGate(expectedConnections: count)
        try HistoryInitializationTraceRegistry.shared.register(gate, for: database)
        defer {
            gate.release()
            HistoryInitializationTraceRegistry.shared.unregister(database)
            try? raw.execute("ROLLBACK")
        }
        let url = database
        let tasks = (0..<count).map { _ in
            Task.detached(priority: .userInitiated) {
                Result { try HistoryStore(url: url) }
            }
        }
        await fulfillment(of: [gate.entered], timeout: 5)
        let arrivalsBeforeCommit = gate.arrivalCount

        var fixtureFailure: (any Error)?
        do {
            try beforeCommit()
            try raw.execute("COMMIT")
        } catch {
            fixtureFailure = error
            try? raw.execute("ROLLBACK")
        }
        gate.release()
        var outcomes: [Result<HistoryStore, any Error>] = []
        for task in tasks { outcomes.append(await task.value) }
        XCTAssertEqual(arrivalsBeforeCommit, count, "Every independent SQLite connection must reach BEGIN before the lock is released")
        XCTAssertFalse(gate.watchdogExpired, "The causal gate must be explicitly released, never opened by its watchdog")
        if let fixtureFailure { throw fixtureFailure }
        return outcomes
    }

    private func assertRefused(
        _ outcomes: [Result<HistoryStore, any Error>],
        as expected: HistoryError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(outcomes.count, 1, file: file, line: line)
        for outcome in outcomes {
            switch outcome {
            case .success:
                XCTFail("Initialization must recheck the committed schema after acquiring its lock", file: file, line: line)
            case .failure(let error):
                XCTAssertEqual(error as? HistoryError, expected, file: file, line: line)
            }
        }
    }
}

private final class HistoryInitializationGate: @unchecked Sendable {
    let entered = XCTestExpectation(description: "independent HistoryStore connections reached BEGIN")
    private let condition = NSCondition()
    private var connections: Set<UInt> = []
    private var released = false
    private var expired = false

    init(expectedConnections: Int) {
        entered.expectedFulfillmentCount = expectedConnections
        entered.assertForOverFulfill = true
    }

    func pause(connection: OpaquePointer) {
        condition.lock()
        defer { condition.unlock() }
        guard connections.insert(UInt(bitPattern: connection)).inserted else { return }
        entered.fulfill()
        // This wait precedes SQLite's busy timeout; slow task scheduling cannot
        // consume the production connection's two-second lock wait allowance.
        let deadline = Date(timeIntervalSinceNow: 10)
        while !released {
            if !condition.wait(until: deadline) {
                expired = true
                released = true
                condition.broadcast()
            }
        }
    }

    func release() {
        condition.lock()
        defer { condition.unlock() }
        released = true
        condition.broadcast()
    }

    var arrivalCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return connections.count
    }

    var watchdogExpired: Bool {
        condition.lock()
        defer { condition.unlock() }
        return expired
    }
}

/// Only the registered file receives a trace. Existing connections and other
/// databases are untouched, and teardown removes just this extension entrypoint.
private final class HistoryInitializationTraceRegistry: @unchecked Sendable {
    static let shared = HistoryInitializationTraceRegistry()
    private let lock = NSLock()
    private var gates: [String: HistoryInitializationGate] = [:]

    func register(_ gate: HistoryInitializationGate, for url: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        let status = sqlite3_auto_extension(historyInitializationExtensionPointer())
        guard status == SQLITE_OK else {
            throw NSError(domain: "HistoryInitializationAutoExtension", code: Int(status))
        }
        gates[url.resolvingSymlinksInPath().path] = gate
    }

    func unregister(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        gates.removeValue(forKey: url.resolvingSymlinksInPath().path)
        if gates.isEmpty {
            sqlite3_cancel_auto_extension(historyInitializationExtensionPointer())
        }
    }

    func installTrace(on database: OpaquePointer) -> Int32 {
        guard let filename = sqlite3_db_filename(database, "main") else { return SQLITE_OK }
        let path = URL(fileURLWithPath: String(cString: filename)).resolvingSymlinksInPath().path
        lock.lock()
        let gate = gates[path]
        lock.unlock()
        guard let gate else { return SQLITE_OK }
        // The connection owns this retain until SQLITE_TRACE_CLOSE, including
        // connections whose HistoryStore initializer ultimately throws.
        let context = Unmanaged.passRetained(gate).toOpaque()
        let status = sqlite3_trace_v2(
            database, UInt32(SQLITE_TRACE_STMT | SQLITE_TRACE_CLOSE), historyInitializationTrace, context
        )
        if status != SQLITE_OK { Unmanaged<HistoryInitializationGate>.fromOpaque(context).release() }
        return status
    }
}

private func historyInitializationTrace(
    _ event: UInt32,
    _ context: UnsafeMutableRawPointer?,
    _ statement: UnsafeMutableRawPointer?,
    _ detail: UnsafeMutableRawPointer?
) -> Int32 {
    guard let context else { return SQLITE_OK }
    let gate = Unmanaged<HistoryInitializationGate>.fromOpaque(context)
    if event == UInt32(SQLITE_TRACE_CLOSE) {
        gate.release()
    } else if event == UInt32(SQLITE_TRACE_STMT), let statement {
        let prepared = OpaquePointer(statement)
        if let sql = sqlite3_sql(prepared), let database = sqlite3_db_handle(prepared),
           String(cString: sql).trimmingCharacters(in: .whitespacesAndNewlines).uppercased().hasPrefix("BEGIN IMMEDIATE") {
            gate.takeUnretainedValue().pause(connection: database)
        }
    }
    return SQLITE_OK
}

private func historyInitializationExtension(
    _ database: OpaquePointer?,
    _ message: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
    _ api: OpaquePointer?
) -> Int32 {
    guard let database else { return SQLITE_MISUSE }
    return HistoryInitializationTraceRegistry.shared.installTrace(on: database)
}

private func historyInitializationExtensionPointer() -> @convention(c) () -> Void {
    // sqlite3.h documents the actual three-argument extension ABI despite the
    // deliberately generic void(*)(void) registration signature.
    typealias Entry = @convention(c) (
        OpaquePointer?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?, OpaquePointer?
    ) -> Int32
    return unsafeBitCast(historyInitializationExtension as Entry, to: (@convention(c) () -> Void).self)
}

private struct HistoryInitializationSnapshot: Equatable {
    let version: [[String]]
    let schema: [[String]]
    let tables: [String: [[String]]]
}

private final class HistoryInitializationDatabase {
    private let database: OpaquePointer

    init(url: URL) throws {
        var opened: OpaquePointer?
        let status = sqlite3_open_v2(
            url.path, &opened, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil
        )
        guard status == SQLITE_OK, let opened else {
            if let opened { sqlite3_close_v2(opened) }
            throw NSError(domain: "HistoryInitializationSQLite", code: Int(status))
        }
        database = opened
    }

    deinit { sqlite3_close_v2(database) }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }

    func snapshot() throws -> HistoryInitializationSnapshot {
        var tables: [String: [[String]]] = [:]
        for row in try rows("SELECT name FROM sqlite_schema WHERE type='table' ORDER BY name") {
            let name = String(row[0].dropFirst("text:".count))
            let quoted = name.replacingOccurrences(of: "\"", with: "\"\"")
            tables[name] = try rows("SELECT * FROM \"\(quoted)\" ORDER BY rowid")
        }
        return HistoryInitializationSnapshot(
            version: try rows("PRAGMA user_version"),
            schema: try rows("SELECT type,name,tbl_name,rootpage,sql FROM sqlite_schema ORDER BY type,name"),
            tables: tables
        )
    }

    func rows(_ sql: String) throws -> [[String]] {
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &prepared, nil) == SQLITE_OK, let prepared else {
            throw failure()
        }
        defer { sqlite3_finalize(prepared) }
        var result: [[String]] = []
        while true {
            switch sqlite3_step(prepared) {
            case SQLITE_ROW:
                var row: [String] = []
                for column in 0..<sqlite3_column_count(prepared) {
                    switch sqlite3_column_type(prepared, column) {
                    case SQLITE_INTEGER: row.append("integer:\(sqlite3_column_int64(prepared, column))")
                    case SQLITE_FLOAT: row.append("real:\(sqlite3_column_double(prepared, column).bitPattern)")
                    case SQLITE_TEXT:
                        guard let text = sqlite3_column_text(prepared, column) else { throw failure() }
                        row.append("text:" + String(cString: text))
                    case SQLITE_NULL: row.append("null")
                    default: throw failure()
                    }
                }
                result.append(row)
            case SQLITE_DONE: return result
            default: throw failure()
            }
        }
    }

    private func failure() -> NSError {
        NSError(domain: "HistoryInitializationSQLite", code: Int(sqlite3_errcode(database)), userInfo: [
            NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(database)),
        ])
    }
}
