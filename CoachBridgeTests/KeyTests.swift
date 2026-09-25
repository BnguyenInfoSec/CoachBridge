import XCTest
@testable import CoachBridge

final class KeyTests: XCTestCase {
    private var saved: [String: Any?] = [:]
    private let keys = [LLMProvider.key, AppSettings.hostedURLKey]

    override func setUp() {
        for k in keys { saved[k] = UserDefaults.standard.object(forKey: k) }
    }

    override func tearDown() {
        for k in keys {
            if let v = saved[k] ?? nil { UserDefaults.standard.set(v, forKey: k) } else { UserDefaults.standard.removeObject(forKey: k) }
        }
    }

    func testMissingKeyNamesTheProviderYouChose() {
        UserDefaults.standard.set(LLMProvider.openai.rawValue, forKey: LLMProvider.key)
        let m = LLMFactory.missingSetupMessage(for: "chat with the coach")
        XCTAssertTrue(m.hasPrefix("No OpenAI API key is saved on this iPhone"), m)
        XCTAssertFalse(m.contains("Anthropic"), "it used to always say Anthropic")
        XCTAssertTrue(m.contains("deleting the app removes them"))
    }

    func testSharedServerNeedsItsAddressFirst() {
        UserDefaults.standard.set(LLMProvider.hosted.rawValue, forKey: LLMProvider.key)
        UserDefaults.standard.set("", forKey: AppSettings.hostedURLKey)
        XCTAssertTrue(LLMFactory.missingSetupMessage(for: "get plan updates").contains("shared server's address"))
    }

    /// The test uses each provider's free model list — nothing is generated, nothing billed —
    /// and sends the key only to that provider, in its own header format.
    func testKeyChecksAreFreeAndGoOnlyToTheProvider() throws {
        let a = try XCTUnwrap(KeyTester.request(provider: .anthropic, key: "sk-ant-x"))
        XCTAssertEqual(a.url?.host, "api.anthropic.com")
        XCTAssertEqual(a.url?.path, "/v1/models")
        XCTAssertEqual(a.httpMethod ?? "GET", "GET")
        XCTAssertEqual(a.value(forHTTPHeaderField: "x-api-key"), "sk-ant-x")
        XCTAssertNil(a.value(forHTTPHeaderField: "Authorization"))

        let o = try XCTUnwrap(KeyTester.request(provider: .openai, key: "sk-x"))
        XCTAssertEqual(o.url?.host, "api.openai.com")
        XCTAssertEqual(o.url?.path, "/v1/models")
        XCTAssertEqual(o.value(forHTTPHeaderField: "Authorization"), "Bearer sk-x")

        XCTAssertNil(KeyTester.request(provider: .hosted, key: "t"))
    }
}
