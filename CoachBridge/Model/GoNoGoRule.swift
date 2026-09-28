import Foundation

/// The decision behind `GoNoGo` (the enum itself is in SharedPhone/, so the widget can show it
/// without compiling the plan engine).
extension GoNoGo {
    /// Sessions with work above endurance pace. Only swim, bike and run can be: effort is read
    /// from the title, and "golf at race pace" isn't an interval session.
    static func isHard(_ s: PlanSession) -> Bool {
        let sport = Prescriber.sport(of: s)
        guard sport == .swim || sport == .bike || sport == .run else { return false }
        switch Prescriber.effort(of: s, sport: sport) {
        case .steady, .sweetSpot, .imPace: return true
        default: return false
        }
    }

    static func decide(recovery: RecoverySignal.Level?, today: [PlanSession]) -> GoNoGo {
        let training = today.filter { $0.kind != .rest }
        guard !training.isEmpty else { return .rest }
        switch recovery {
        case .good?, .normal?: return .go
        case .caution?: return training.contains(where: isHard) ? .swapToEasy : .goEasy
        case .unknown?, nil: return .byFeel
        }
    }
}
