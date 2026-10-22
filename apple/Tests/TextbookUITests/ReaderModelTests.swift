import Foundation
import XCTest
import TextbookCore
@testable import TextbookUI

private actor SuspendedHistory: AnswerHistoryStoring {
    private var saved: [AnswerAttempt] = []
    private var saveGate: CheckedContinuation<Void, Never>?
    private var startGate: CheckedContinuation<Void, Never>?
    private var started = false
    private let shouldFail: Bool

    init(shouldFail: Bool = false) { self.shouldFail = shouldFail }

    func save(_ answer: AnswerAttempt, for book: Textbook) async throws {
        await withCheckedContinuation { continuation in
            saveGate = continuation
            started = true
            startGate?.resume()
            startGate = nil
        }
        if shouldFail { throw HistoryError.unavailable }
        saved.append(answer)
    }

    func attempts(for book: Textbook) -> [AnswerAttempt] { saved }

    func waitForSave() async {
        guard !started else { return }
        await withCheckedContinuation { startGate = $0 }
    }

    func finishSave() {
        saveGate?.resume()
        saveGate = nil
    }
}

@MainActor
final class ReaderModelTests: XCTestCase {
    func testNavigationDuringSaveDoesNotMarkAnotherQuestionAsSaved() async throws {
        let history = SuspendedHistory()
        let model = ReaderModel(dataDirectory: nil, store: history)
        await model.initialize()
        model.selectedOption = "text"
        let saving = Task { await model.submit() }
        await history.waitForSave()

        model.selectedPage = "tool"
        model.changePage()
        XCTAssertNil(model.feedback)
        XCTAssertFalse(model.isSaved)
        await history.finishSave()
        await saving.value

        XCTAssertEqual(model.history.count, 1)
        XCTAssertFalse(model.isSaved)
        model.selectedPage = "model"
        model.changePage()
        XCTAssertEqual(model.feedback?.questionID, "model-action")
        XCTAssertTrue(model.isSaved)
    }

    func testFailedSaveKeepsAnswerWhenNavigatingAwayAndBack() async {
        let history = SuspendedHistory(shouldFail: true)
        let model = ReaderModel(dataDirectory: nil, store: history)
        await model.initialize()
        model.selectedOption = "saved"
        let saving = Task { await model.submit() }
        await history.waitForSave()
        let pendingID = model.feedback?.id
        model.selectedPage = "tool"
        model.changePage()
        await history.finishSave()
        await saving.value

        model.selectedPage = "model"
        model.changePage()
        XCTAssertEqual(model.feedback?.id, pendingID)
        XCTAssertEqual(model.selectedOption, "saved")
        XCTAssertFalse(model.isSaved)
        XCTAssertTrue(model.history.isEmpty)
    }
}
