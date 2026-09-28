import XCTest
@testable import CoachBridge

final class SessionPurposeTests: XCTestCase {
    private func s(_ kind: SessionKind, _ title: String, _ detail: String = "", minutes: Int? = nil) -> PlanSession {
        var rx = Prescription()
        rx.durationMin = minutes
        return PlanSession(kind: kind, title: title, detail: detail, rx: minutes == nil ? nil : rx)
    }

    /// Every kind of session, in every phase, gets a reason — never an empty card.
    func testEverySessionHasAPurpose() {
        let sessions = SessionKind.allCases.map { s($0, $0.label) } + [
            s(.bike, "Long ride", minutes: 180), s(.run, "Long run", minutes: 100), s(.swim, "Long swim", minutes: 70),
            s(.bike, "Key: sweet spot"), s(.run, "Key: IM-pace run"), s(.bike, "Brick", "2:00 + 10-min run off"),
            s(.flex, "Optional easy session"), s(.run, "Easy run", "30 min with walk breaks"),
        ]
        for phase in PlanBlueprint.blockOrder {
            for session in sessions {
                let text = SessionPurpose.text(for: session, phaseID: phase)
                XCTAssertGreaterThan(text.count, 40, "\(session.title) in \(phase): \(text)")
            }
        }
    }

    func testThePurposeMatchesTheWork() {
        XCTAssertTrue(SessionPurpose.what(s(.bike, "Key: sweet spot", "3 × 12 min sweet spot")).contains("FTP"))
        XCTAssertTrue(SessionPurpose.what(s(.run, "Key: IM-pace run", "IM pace")).contains("race pace"))
        XCTAssertTrue(SessionPurpose.what(s(.bike, "Endurance ride", minutes: 180)).contains("long ride"))
        XCTAssertTrue(SessionPurpose.what(s(.bike, "Endurance ride", minutes: 60)).contains("zone 2"))
        XCTAssertTrue(SessionPurpose.what(s(.bike, "Brick", "1:30 + 15-min run off")).contains("brick"))
        XCTAssertTrue(SessionPurpose.what(s(.lift, "Strength")).contains("Strength"))
        XCTAssertTrue(SessionPurpose.what(s(.flex, "Optional easy run")).contains("optional"),
                      "an optional session says it's optional")
    }

    func testThePhaseLineSaysWhereItFits() {
        let ride = s(.bike, "Endurance ride", minutes: 90)
        XCTAssertTrue(SessionPurpose.text(for: ride, phaseID: "b1").contains("Base 1"))
        XCTAssertTrue(SessionPurpose.text(for: ride, phaseID: "taper").contains("taper"))
        XCTAssertFalse(SessionPurpose.text(for: s(.rest, "Off"), phaseID: "build").contains("Build"),
                       "a rest day explains rest, not the block")
    }
}
