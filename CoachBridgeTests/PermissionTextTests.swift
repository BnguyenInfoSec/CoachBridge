import XCTest
@testable import CoachBridge

/// The permission prompts are what App Review compares against the privacy policy and the app's
/// behaviour. When a provider is added or removed, these must change with it.
final class PermissionTextTests: XCTestCase {
    private func text(_ key: String) -> String { Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "" }

    func testHealthAndCalendarPromptsNameEveryProviderTheAppOffers() {
        for key in ["NSHealthShareUsageDescription", "NSCalendarsFullAccessUsageDescription"] {
            let t = text(key)
            XCTAssertFalse(t.isEmpty, key)
            for p in LLMProvider.allCases {
                switch p {
                case .anthropic: XCTAssertTrue(t.contains("Anthropic"), "\(key) must name Anthropic")
                case .openai: XCTAssertTrue(t.contains("OpenAI"), "\(key) must name OpenAI")
                case .hosted: XCTAssertTrue(t.contains("a server you set up"), "\(key) must mention the shared server option")
                }
            }
        }
    }

    func testLocationPromptNamesTheWeatherService() {
        XCTAssertTrue(text("NSLocationWhenInUseUsageDescription").contains("Apple Weather"))
    }
}
