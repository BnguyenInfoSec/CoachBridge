import XCTest
@testable import CoachBridge

final class SessionEditingTests: XCTestCase {
    private func planned(_ kind: SessionKind, _ title: String, minutes: Int = 60) -> PlanSession {
        var rx = Prescription()
        rx.durationMin = minutes
        rx.heartRate = "138–151 bpm"
        rx.fuelDuring = "60 g/h"
        return PlanSession(kind: kind, title: title, detail: "Steady", rx: rx, startTime: "07:15")
    }

    // MARK: Adopting a planned session

    func testAdoptingKeepsTheSessionAndMarksWhatItReplaces() {
        let c = CustomSession.adopting(planned(.bike, "Endurance ride", minutes: 150), on: "2026-10-03", startTime: "06:30")
        XCTAssertEqual(c.date, "2026-10-03")
        XCTAssertEqual(c.startTime, "06:30", "the time the calendar placed it wins over the plan's")
        XCTAssertEqual(c.durationMin, 150)
        XCTAssertEqual(c.kind, .bike)
        XCTAssertEqual(c.title, "Endurance ride")
        XCTAssertEqual(c.notes, "Steady")
        XCTAssertEqual(c.replaces, .bike)
        XCTAssertEqual(c.rx?.heartRate, "138–151 bpm")
        XCTAssertEqual(c.rx?.fuelDuring, "60 g/h", "fuelling carries over rather than resetting")
        XCTAssertTrue(c.planSession().addedByAthlete, "once edited, the plan treats it as the athlete's")
        XCTAssertEqual(c.planSession().rx?.durationMin, 150)
    }

    func testEditedSessionReplacesOnlyOnePlannedSessionOfItsKind() {
        let day = [planned(.run, "Easy run"), planned(.lift, "Strength"), planned(.run, "Strides")]
        let mine = CustomSession.adopting(day[0], on: "2026-10-03", startTime: nil)
        let left = CustomSession.remaining(planned: day, replacedBy: [mine])
        XCTAssertEqual(left.map(\.title), ["Strength", "Strides"])
    }

    func testAddedSessionsReplaceNothing() {
        let day = [planned(.run, "Easy run")]
        let added = CustomSession(date: "2026-10-03", startTime: "18:00", durationMin: 50, kind: .run, title: "Group run")
        XCTAssertEqual(CustomSession.remaining(planned: day, replacedBy: [added]).count, 1)
    }

    /// If Claude later renames the planned session, the athlete's edit still replaces it —
    /// matching is by kind, not title, so the day doesn't end up with both.
    func testReplacementSurvivesClaudeRenamingTheSession() {
        let mine = CustomSession.adopting(planned(.swim, "CSS set"), on: "2026-10-03", startTime: nil)
        let left = CustomSession.remaining(planned: [planned(.swim, "Technique + CSS")], replacedBy: [mine])
        XCTAssertTrue(left.isEmpty)
    }

    // MARK: Sanitising what the athlete types

    func testSanitisingCapsAndCleansText() {
        var c = CustomSession(date: "2026-10-03", startTime: "25:99", durationMin: 5_000, kind: .run,
                              title: "  Tempo\nrun\u{0007}  ", notes: String(repeating: "x", count: 5_000))
        c.rx = Prescription(distance: "10 km\u{0000}", intensity: "   ", pace: String(repeating: "p", count: 500))
        let s = c.sanitized()
        XCTAssertEqual(s.title, "Tempo run", "line breaks become spaces, control characters go")
        XCTAssertEqual(s.notes.count, CustomSession.maxNotes)
        XCTAssertEqual(s.durationMin, CustomSession.durationRange.upperBound)
        XCTAssertEqual(s.startTime, "06:00", "an impossible time falls back rather than reaching the calendar")
        XCTAssertEqual(s.rx?.distance, "10 km")
        XCTAssertNil(s.rx?.intensity, "a blank target is no target")
        XCTAssertEqual(s.rx?.pace?.count, CustomSession.maxTarget)
    }

    func testBlankTitleFallsBackToTheKind() {
        let c = CustomSession(date: "2026-10-03", startTime: "06:00", durationMin: 30, kind: .swim, title: "  \n ")
        XCTAssertEqual(c.sanitized().title, "Swim")
    }

    func testNotesKeepTheirLineBreaks() {
        let c = CustomSession(date: "2026-10-03", startTime: "06:00", durationMin: 30, kind: .run,
                              title: "Run", notes: "Meet at the pier\nBring gels")
        XCTAssertEqual(c.sanitized().notes, "Meet at the pier\nBring gels")
    }

    func testTimeValidation() {
        for ok in ["00:00", "06:05", "23:59"] { XCTAssertTrue(CustomSession.isTime(ok), ok) }
        for bad in ["24:00", "6:05", "06:60", "0605", "06:05:00", "", "ab:cd", "-1:00", ":"] {
            XCTAssertFalse(CustomSession.isTime(bad), bad)
        }
    }

    // MARK: Compatibility and the prompt

    /// Files written by v2.7 have none of the new fields and must still load.
    func testDecodesSessionsSavedBeforeTargetsExisted() throws {
        let json = """
        [{"id":"6F1C7C3A-8E5B-4C8B-9D2A-1B2C3D4E5F60","date":"2026-10-03","startTime":"06:00",
          "durationMin":50,"kind":"run","title":"Group run","notes":"","createdAt":"2026-09-20T10:00:00Z"}]
        """
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let list = try dec.decode([CustomSession].self, from: Data(json.utf8))
        XCTAssertEqual(list.first?.title, "Group run")
        XCTAssertNil(list.first?.rx)
        XCTAssertNil(list.first?.replaces)
    }

    func testLineForClaudeIncludesTargetsWhenSet() {
        var c = CustomSession(date: "2026-10-03", startTime: "06:00", durationMin: 90, kind: .bike, title: "Hill repeats")
        c.rx = Prescription(distance: "40 km", power: "240–260 W")
        c.indoor = true
        XCTAssertEqual(c.line(), "2026-10-03 06:00 · bike · Hill repeats · 90 min · 40 km, 240–260 W · indoor")
    }
}
