import XCTest
@testable import CoachBridge

final class TirePressureTests: XCTestCase {
    private func rec(_ kg: Double = 75, _ bike: TirePressure.Bike = .road, _ w: Int = 28,
                     _ setup: Gear.TireSetup? = .tubeless, _ rim: TirePressure.Rim? = .hooked,
                     _ riding: TirePressure.Riding = .roadTraining) -> TirePressure.Result {
        TirePressure.recommend(riderKg: kg, bike: bike, widthMM: w, setup: setup, rim: rim, riding: riding)!
    }

    /// Calibration point from the modern calculators: 75 kg, 28 mm road tubeless ≈ 60 / 65 psi.
    func testTheCalibrationPoint() {
        let r = rec()
        XCTAssertEqual(r.frontPSI, 61, accuracy: 3)
        XCTAssertEqual(r.rearPSI, 66, accuracy: 3)
        XCTAssertLessThan(r.frontPSI, r.rearPSI, "the rear carries more")
    }

    func testWiderTiresAndLighterRidersRunLower() {
        XCTAssertGreaterThan(rec(75, .road, 25).rearPSI, rec(75, .road, 28).rearPSI)
        XCTAssertGreaterThan(rec(75, .road, 28).rearPSI, rec(75, .road, 32).rearPSI)
        XCTAssertGreaterThan(rec(90).rearPSI, rec(60).rearPSI)
        let gravel = rec(75, .gravel, 40)
        XCTAssertEqual(gravel.rearPSI, 37, accuracy: 4, "gravel 40 mm lands in the mid-30s")
    }

    /// Every combination: never over the hookless limit on a hookless rim, never under the floor,
    /// always a sensible number. Swept, not spot-checked.
    func testSweepStaysSafe() {
        for kg in stride(from: 45.0, through: 130, by: 5) {
            for bike in TirePressure.Bike.allCases {
                for w in [23, 25, 28, 30, 32, 35, 40, 45, 50, 56, 61] {
                    for setup: Gear.TireSetup? in [nil, .clincher, .tubeless, .tubular] {
                        for rim in TirePressure.Rim.allCases {
                            for riding in TirePressure.Riding.allCases {
                                let r = rec(kg, bike, w, setup, rim, riding)
                                if rim == .hookless {
                                    XCTAssertLessThanOrEqual(max(r.frontPSI, r.rearPSI), 72.5)
                                }
                                XCTAssertGreaterThanOrEqual(min(r.frontPSI, r.rearPSI), 15)
                                XCTAssertLessThanOrEqual(max(r.frontPSI, r.rearPSI), TirePressure.typicalMaxPSI(widthMM: w))
                            }
                        }
                    }
                }
            }
        }
    }

    func testHooklessCapIsExplained() {
        let r = rec(110, .road, 25, .tubeless, .hookless, .raceDay)
        XCTAssertEqual(r.rearPSI, 72.5)
        XCTAssertTrue(r.notes.contains { $0.contains("hookless") || $0.contains("72.5") })
    }

    func testTubesRunHigherAndWetRunsLower() {
        XCTAssertGreaterThan(rec(75, .road, 28, .clincher).rearPSI, rec(75, .road, 28, .tubeless).rearPSI)
        XCTAssertLessThan(rec(riding: .wet).rearPSI, rec(riding: .roadTraining).rearPSI)
    }

    func testImpossibleInputsGiveNothing() {
        XCTAssertNil(TirePressure.recommend(riderKg: 5, bike: .road, widthMM: 28, setup: nil, rim: nil, riding: .roadTraining))
        XCTAssertNil(TirePressure.recommend(riderKg: 75, bike: .road, widthMM: 200, setup: nil, rim: nil, riding: .roadTraining))
    }

    func testBarConversion() {
        XCTAssertEqual(rec().rearBar, rec().rearPSI / 14.5038, accuracy: 0.0001)
    }
}

private extension TirePressureTests {
    func rec(riding: TirePressure.Riding) -> TirePressure.Result { rec(75, .road, 28, .tubeless, .hooked, riding) }
}
