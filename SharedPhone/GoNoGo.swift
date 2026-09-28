import Foundation

/// Should today's session go ahead as planned? A plain answer from the recovery signal and how
/// hard the session is — for the widget, where there's room for a word, not a paragraph.
///
/// Deliberately says nothing numeric: it appears on the Lock Screen, where anyone holding the
/// phone can read it.
enum GoNoGo: String, Codable, Sendable, CaseIterable {
    case go, goEasy, swapToEasy, rest, byFeel

    var title: String {
        switch self {
        case .go: return "Go"
        case .goEasy: return "Go easy"
        case .swapToEasy: return "Swap to easy"
        case .rest: return "Rest day"
        case .byFeel: return "Go by feel"
        }
    }

    var detail: String {
        switch self {
        case .go: return "Recovered — train as planned."
        case .goEasy: return "Recovery is down; keep it truly easy."
        case .swapToEasy: return "Recovery is down; make today's hard session easy."
        case .rest: return "Nothing planned. Recovery is training too."
        case .byFeel: return "Not enough recent data for a recovery read."
        }
    }

    var symbol: String {
        switch self {
        case .go: return "checkmark.circle.fill"
        case .goEasy, .swapToEasy: return "exclamationmark.triangle.fill"
        case .rest: return "bed.double.fill"
        case .byFeel: return "questionmark.circle.fill"
        }
    }
}
