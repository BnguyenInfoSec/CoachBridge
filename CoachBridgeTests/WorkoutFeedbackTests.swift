import XCTest
@testable import CoachBridge

final class WorkoutFeedbackTests: XCTestCase {

    private func session(durationMin: Int? = nil, hr: String? = nil, power: String? = nil) -> PlanSession {
        var s = PlanSession(kind: .bike, title: "Endurance ride")
        s.rx = Prescription(durationMin: durationMin, heartRate: hr, power: power)
        return s
    }

    // MARK: Planned versus actual

    func testNoPlannedSessionIsAnExtra() {
        let c = SessionCompare.make(planned: nil, actualSeconds: 3600, avgHR: 140, avgPower: nil)
        XCTAssertFalse(c.hadPlan)
        XCTAssertTrue(c.lines.isEmpty)
        XCTAssertTrue(c.promptText.contains("wasn't on the plan"))
    }

    func testDurationWithinTenPercentIsOnTarget() {
        let c = SessionCompare.make(planned: session(durationMin: 90),
                                    actualSeconds: 84 * 60, avgHR: nil, avgPower: nil)
        XCTAssertEqual(c.lines.first?.status, .onTarget)
        XCTAssertEqual(c.lines.first?.delta, "")
        XCTAssertEqual(c.headline, "On plan.")
    }

    func testShortSessionIsFlaggedWithTheGap() {
        let c = SessionCompare.make(planned: session(durationMin: 90),
                                    actualSeconds: 60 * 60, avgHR: nil, avgPower: nil)
        XCTAssertEqual(c.lines.first?.status, .under)
        XCTAssertEqual(c.lines.first?.delta, "30 min short")
        XCTAssertEqual(c.misses.count, 1)
    }

    /// A five-minute floor, so a 20-minute session isn't called off-plan for finishing 2 min early.
    func testShortSessionsGetAFiveMinuteTolerance() {
        let c = SessionCompare.make(planned: session(durationMin: 20),
                                    actualSeconds: 16 * 60, avgHR: nil, avgPower: nil)
        XCTAssertEqual(c.lines.first?.status, .onTarget)
    }

    func testHeartRateInsideTheWindowIsOnTarget() {
        let c = SessionCompare.make(planned: session(hr: "138–151 bpm (Z2)"),
                                    actualSeconds: 3600, avgHR: 145, avgPower: nil)
        XCTAssertEqual(c.lines.first?.label, "Avg heart rate")
        XCTAssertEqual(c.lines.first?.status, .onTarget)
        XCTAssertEqual(c.lines.first?.planned, "138–151 bpm")
    }

    func testHeartRateOverTheWindowReportsHowFar() {
        let c = SessionCompare.make(planned: session(hr: "138–151 bpm"),
                                    actualSeconds: 3600, avgHR: 162, avgPower: nil)
        XCTAssertEqual(c.lines.first?.status, .over)
        XCTAssertEqual(c.lines.first?.delta, "11 bpm over")
    }

    func testMissingSamplesAreUnknownNotAFailure() {
        let c = SessionCompare.make(planned: session(hr: "138–151 bpm"),
                                    actualSeconds: 3600, avgHR: nil, avgPower: nil)
        XCTAssertEqual(c.lines.first?.status, .unknown)
        XCTAssertEqual(c.lines.first?.actual, "not recorded")
        XCTAssertTrue(c.misses.isEmpty, "no data is not the same as missing the target")
        XCTAssertTrue(c.headline.contains("Nothing to compare"))
    }

    func testDurationAndPowerTogether() {
        let c = SessionCompare.make(planned: session(durationMin: 60, power: "176–186 W"),
                                    actualSeconds: 62 * 60, avgHR: nil, avgPower: 150)
        XCTAssertEqual(c.lines.count, 2)
        XCTAssertEqual(c.lines[0].status, .onTarget)
        XCTAssertEqual(c.lines[1].status, .under)
        XCTAssertEqual(c.lines[1].delta, "26 W under")
        XCTAssertEqual(c.headline, "On plan apart from avg power.")
    }

    func testSessionWithNoTargetsSaysSo() {
        let c = SessionCompare.make(planned: session(), actualSeconds: 3600, avgHR: 140, avgPower: nil)
        XCTAssertTrue(c.hadPlan)
        XCTAssertTrue(c.lines.isEmpty)
        XCTAssertTrue(c.promptText.contains("no numeric targets"))
    }

    // MARK: Parsing the coach's reply

    private func toolData(_ o: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: o)
    }

    func testParsesAFullNote() {
        let note = WorkoutReviewer.parse(toolData([
            "headline": "Held Z2 better than last week",
            "body": "78 minutes at 144 bpm average, inside the window the whole way.",
            "toward_goal": "This is the aerobic work the build block is asking for.",
            "watch_for": "Third session this week above RPE 7.",
        ]), model: "claude-sonnet-5")
        XCTAssertEqual(note?.headline, "Held Z2 better than last week")
        XCTAssertNotNil(note?.towardGoal)
        XCTAssertNotNil(note?.watchFor)
        XCTAssertEqual(note?.model, "claude-sonnet-5")
    }

    func testMissingRequiredFieldsGiveNoNote() {
        XCTAssertNil(WorkoutReviewer.parse(toolData(["headline": "Only a headline"]), model: "m"))
        XCTAssertNil(WorkoutReviewer.parse(toolData(["body": "Only a body"]), model: "m"))
        XCTAssertNil(WorkoutReviewer.parse(Data("not json".utf8), model: "m"))
    }

    /// Models sometimes fill an optional field with a non-answer rather than leaving it out;
    /// showing "Watch for: N/A" would be worse than showing nothing.
    func testNonAnswersInOptionalFieldsAreDropped() {
        for filler in ["none", "N/A", "Nothing", "—", "no concerns.", ""] {
            let note = WorkoutReviewer.parse(toolData([
                "headline": "H", "body": "B", "watch_for": filler,
            ]), model: "m")
            XCTAssertNil(note?.watchFor, "expected \"\(filler)\" to be dropped")
        }
    }

    func testOverlongTextIsClipped() {
        let note = WorkoutReviewer.parse(toolData([
            "headline": String(repeating: "a", count: 400),
            "body": String(repeating: "b", count: 4000),
        ]), model: "m")
        XCTAssertEqual(note?.headline.count, 121)      // 120 plus the ellipsis
        XCTAssertEqual(note?.body.count, 901)
    }

    // MARK: Feel

    func testRPELabelsCoverTheWholeScale() {
        for v in 1...10 {
            XCTAssertFalse(WorkoutFeel.rpeLabel(v).isEmpty, "no label for RPE \(v)")
        }
        XCTAssertEqual(WorkoutFeel.rpeLabel(1), WorkoutFeel.rpeLabel(2))
    }

    func testFeelSummaryIncludesTheNoteOnlyWhenThereIsOne() {
        let bare = WorkoutFeel(rpe: 6, mood: .good)
        XCTAssertEqual(bare.summary, "RPE 6/10, good")
        let noted = WorkoutFeel(rpe: 9, mood: .tough, note: "Legs were flat")
        XCTAssertTrue(noted.summary.contains("\"Legs were flat\""))
    }

    func testEntryRoundTripsThroughJSON() throws {
        let entry = WorkoutEntry(
            id: UUID(), dateISO: "2026-09-22", sport: .bike,
            // A whole second, because the store encodes dates as ISO-8601 without fractional
            // seconds — a `.now` here would come back truncated and fail the comparison.
            feel: WorkoutFeel(rpe: 7, mood: .tough, note: "Wind on the way back",
                              answeredAt: Date(timeIntervalSince1970: 1_758_500_000)),
            note: CoachNote(headline: "H", body: "B", towardGoal: nil, watchFor: nil,
                            model: "m", createdAt: Date(timeIntervalSince1970: 0)))
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let back = try dec.decode(WorkoutEntry.self, from: enc.encode(entry))
        XCTAssertEqual(back, entry)
        XCTAssertTrue(back.isAnswered)
    }
}
