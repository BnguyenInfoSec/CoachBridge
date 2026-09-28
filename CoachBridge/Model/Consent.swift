import Foundation

/// The athlete's explicit OK before their data leaves the phone for a third party: the AI
/// provider they chose, or their Google Drive. App Store guidelines 5.1.1 and 5.1.2 ask for this,
/// and it's the right default for health data whatever the rules say.
///
/// A consent is for one recipient: switching from Anthropic to OpenAI, or to a different server,
/// asks again. Raising `version` when what's shared changes asks everyone again.
enum ConsentScope: String, CaseIterable, Identifiable, Sendable {
    case ai, drive
    var id: String { rawValue }
}

struct ConsentRecord: Codable, Equatable, Sendable {
    var version: Int
    var recipient: String
    var grantedAt: Date
}

enum Consent {
    /// Bump when the list of what's shared changes, so everyone is asked again.
    static let version = 1

    static func key(_ scope: ConsentScope) -> String { "consent.\(scope.rawValue)" }

    static func record(_ scope: ConsentScope, defaults: UserDefaults = .standard) -> ConsentRecord? {
        guard let data = defaults.data(forKey: key(scope)) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(ConsentRecord.self, from: data)
    }

    static func isGranted(_ scope: ConsentScope, recipient: String, defaults: UserDefaults = .standard) -> Bool {
        guard let r = record(scope, defaults: defaults) else { return false }
        return r.version == version && r.recipient == recipient
    }

    static func grant(_ scope: ConsentScope, recipient: String, now: Date = .now, defaults: UserDefaults = .standard) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(ConsentRecord(version: version, recipient: recipient, grantedAt: now)) {
            defaults.set(data, forKey: key(scope))
        }
    }

    static func revoke(_ scope: ConsentScope, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(scope))
    }

    // MARK: Who receives it

    /// The AI recipient: the provider, and for a self-hosted server its host (pass `hostedURL`
    /// only then), so pointing the app at a different server asks again.
    static func aiRecipient(provider: String, hostedURL: String? = nil) -> String {
        guard let hostedURL else { return provider }
        return "\(provider):" + (PromptSafety.webURL(hostedURL)?.host ?? "unset")
    }

    static let driveRecipient = "google-drive"

    static let declinedMessage = "Nothing was sent. The coach needs your OK to share your training data with your AI provider; you can allow it in Settings → Data sharing."

    // MARK: What the athlete is told

    struct Copy: Equatable, Sendable {
        let title: String
        let sent: [String]
        let notSent: [String]
        let whereItGoes: String
        let when: String
        let withdraw: String
    }

    /// Plain and specific: what goes, where, when, what doesn't, and how to take it back.
    static func copy(_ scope: ConsentScope, recipientName: String) -> Copy {
        switch scope {
        case .ai:
            return Copy(
                title: "Share your training data with \(recipientName)?",
                sent: [
                    "Summaries of your recent health data: resting heart rate, HRV, sleep and training load, if Share my Health summary is on in Settings",
                    "Your workouts, how they felt and your notes on them",
                    "Your training profile and plan: your race, available time, bike, shoes and fuel",
                    "Your calendar's busy times and event titles, when the coach plans your week around them",
                    "Anything you type to the coach",
                ],
                notSent: [
                    "Photos of places you train",
                    "Your weight for the tire-pressure calculator",
                    "Your location",
                    "Your API key, except to \(recipientName) itself",
                ],
                whereItGoes: "Straight from this iPhone to \(recipientName), using your own key. Coach Bridge has no server and never sees it. \(recipientName)'s terms and data retention apply to what it receives.",
                when: "Only when you ask: sending a chat message, updating the week, or getting a coach's note on a workout.",
                withdraw: "You can withdraw this any time in Settings → Data sharing. The coach stops working until you allow it again. What was already sent stays under \(recipientName)'s policies.")
        case .drive:
            return Copy(
                title: "Save a daily health summary to your Google Drive?",
                sent: [
                    "One file per day with that day's health metrics: resting heart rate, HRV, sleep, activity, weight and workouts",
                ],
                notSent: [
                    "Your chats, notes and training plan",
                    "Photos, your location and your keys",
                ],
                whereItGoes: "A Coach folder in your own Google Drive. The app can only see files it created there. Google's terms apply, and anyone you share that folder with can read it.",
                when: "Once a day, automatically, after you first unlock your iPhone, and whenever you tap Export.",
                withdraw: "You can withdraw this any time in Settings → Data sharing, which stops the exports. Files already in your Drive stay there until you delete them.")
        }
    }
}
