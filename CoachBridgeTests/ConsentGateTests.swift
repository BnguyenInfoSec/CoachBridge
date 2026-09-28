import XCTest
@testable import CoachBridge

/// The queue in front of the consent screen. Two features can ask at once (a note and a chat
/// message); a second screen presented over the first fails and would leave its caller waiting
/// forever, which Codex's review caught.
@MainActor
final class ConsentGateTests: XCTestCase {
    /// Stands in for the athlete: records each question and answers when the test says so.
    /// Main-actor like the real screen: unisolated, its async `ask` ran on a background thread
    /// and wrote `pending` while the test read it, a race that crashed about one run in thirty.
    @MainActor
    private final class FakeUser {
        var asked: [ConsentScope] = []
        var granted: Set<ConsentScope> = []
        private var pending: [ConsentScope: CheckedContinuation<Bool, Never>] = [:]

        func ask(_ scope: ConsentScope) async -> Bool {
            asked.append(scope)
            let answer = await withCheckedContinuation { pending[scope] = $0 }
            if answer { granted.insert(scope) }
            return answer
        }

        func isOpen(_ scope: ConsentScope) -> Bool { pending[scope] != nil }

        func answer(_ scope: ConsentScope, _ allowed: Bool) {
            pending.removeValue(forKey: scope)?.resume(returning: allowed)
        }
    }

    private func gate(_ user: FakeUser) -> ConsentGate {
        ConsentGate(askUser: { await user.ask($0) }, granted: { user.granted.contains($0) })
    }

    /// Lets queued tasks run until `condition` holds.
    private func settle(until condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { await Task.yield() }
    }

    func testTwoRequestsForTheSameScopeShareOneQuestion() async {
        let user = FakeUser()
        let g = gate(user)
        async let a = g.require(.ai)
        async let b = g.require(.ai)
        await settle { user.isOpen(.ai) }
        user.answer(.ai, true)
        let (first, second) = await (a, b)
        XCTAssertTrue(first)
        XCTAssertTrue(second)
        XCTAssertEqual(user.asked, [.ai], "one screen, not two")
    }

    func testADifferentScopeWaitsItsTurnAndGetsItsOwnAnswer() async {
        let user = FakeUser()
        let g = gate(user)
        async let ai = g.require(.ai)
        await settle { user.isOpen(.ai) }
        async let drive = g.require(.drive)
        await settle { false }                                   // give Drive every chance to jump the queue
        XCTAssertFalse(user.isOpen(.drive), "never two screens at once")
        user.answer(.ai, true)
        await settle { user.isOpen(.drive) }
        user.answer(.drive, false)
        let (aiAnswer, driveAnswer) = await (ai, drive)
        XCTAssertTrue(aiAnswer)
        XCTAssertFalse(driveAnswer, "Drive gets its own answer, not the AI's")
        XCTAssertEqual(user.asked, [.ai, .drive])
    }

    func testAlreadyAllowedDoesntAsk() async {
        let user = FakeUser()
        user.granted = [.drive]
        let allowed = await gate(user).require(.drive)
        XCTAssertTrue(allowed)
        XCTAssertTrue(user.asked.isEmpty)
    }

    /// A screen that can't be shown answers "no" (the gate's two-second fallback); the next
    /// request must ask again rather than wait on the old question.
    func testAFailedQuestionDoesntBlockTheNextOne() async {
        var attempts = 0
        let g = ConsentGate(askUser: { _ in attempts += 1; return false }, granted: { _ in false })
        let first = await g.require(.ai)
        let second = await g.require(.ai)
        XCTAssertFalse(first)
        XCTAssertFalse(second)
        XCTAssertEqual(attempts, 2)
    }
}
