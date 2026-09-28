import XCTest
@testable import CoachBridge

final class ConsentTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        defaults = UserDefaults(suiteName: "ConsentTests")
        defaults.removePersistentDomain(forName: "ConsentTests")
    }

    func testNothingIsGrantedUntilTheAthleteSaysSo() {
        XCTAssertFalse(Consent.isGranted(.ai, recipient: "anthropic", defaults: defaults))
        Consent.grant(.ai, recipient: "anthropic", defaults: defaults)
        XCTAssertTrue(Consent.isGranted(.ai, recipient: "anthropic", defaults: defaults))
        XCTAssertFalse(Consent.isGranted(.drive, recipient: Consent.driveRecipient, defaults: defaults),
                       "saying yes to the AI isn't saying yes to Drive")
        Consent.revoke(.ai, defaults: defaults)
        XCTAssertFalse(Consent.isGranted(.ai, recipient: "anthropic", defaults: defaults))
    }

    /// A yes to Anthropic isn't a yes to OpenAI, or to a different server.
    func testANewRecipientAsksAgain() {
        Consent.grant(.ai, recipient: "anthropic", defaults: defaults)
        XCTAssertFalse(Consent.isGranted(.ai, recipient: "openai", defaults: defaults))
        let one = Consent.aiRecipient(provider: "hosted", hostedURL: "https://coach.example.com/api")
        let two = Consent.aiRecipient(provider: "hosted", hostedURL: "https://other.example.net")
        XCTAssertEqual(one, "hosted:coach.example.com")
        XCTAssertNotEqual(one, two)
        XCTAssertEqual(Consent.aiRecipient(provider: "anthropic"), "anthropic")
    }

    func testAnOlderVersionOfTheConsentDoesntCount() throws {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        defaults.set(try enc.encode(ConsentRecord(version: Consent.version - 1, recipient: "anthropic", grantedAt: .now)),
                     forKey: Consent.key(.ai))
        XCTAssertFalse(Consent.isGranted(.ai, recipient: "anthropic", defaults: defaults))
    }

    /// The explanation names who receives it, says what never goes, and how to take it back.
    func testTheExplanationIsSpecific() {
        for scope in ConsentScope.allCases {
            let c = Consent.copy(scope, recipientName: "OpenAI")
            XCTAssertFalse(c.sent.isEmpty)
            XCTAssertFalse(c.notSent.isEmpty)
            XCTAssertTrue(c.withdraw.contains("Settings → Data sharing"))
        }
        let ai = Consent.copy(.ai, recipientName: "OpenAI")
        XCTAssertTrue(ai.title.contains("OpenAI"))
        XCTAssertTrue(ai.whereItGoes.contains("no server"))
        XCTAssertTrue(ai.notSent.contains { $0.contains("weight") }, "matches the privacy policy: weight stays on the phone")
    }
}
