import Foundation
import Testing
@testable import Voice

@Suite("An Opt+1 completion is a compact confirmation")
struct PolishPillWordsTests {
    @Test("The pill shows a single confirmation")
    func compactConfirmation() {
        #expect(PolishPillWords.line == "Polished")
    }

    @Test("The explicit Changes window still offers scoped Undo and Try again")
    func changesWindowActions() {
        #expect(Notification.Name.flowUndoLastPolish.rawValue == "flow.undoLastPolish")
        #expect(Notification.Name.flowRetryLastPolish.rawValue == "flow.retryLastPolish")
    }
}
