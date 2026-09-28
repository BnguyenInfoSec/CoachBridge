import XCTest
@testable import CoachBridge

final class PrivacyPolicyTests: XCTestCase {
    /// The policy ships inside the app, so Settings can always show it.
    func testThePolicyIsBundled() {
        let text = PolicyDocument.bundledText
        XCTAssertTrue(text.hasPrefix("# Coach Bridge privacy policy"), String(text.prefix(80)))
    }

    func testItParsesIntoReadableBlocks() {
        let blocks = PolicyDocument.blocks(PolicyDocument.bundledText)
        XCTAssertTrue(blocks.contains(.heading(1, "Coach Bridge privacy policy")))
        let rows = blocks.compactMap { if case .row(let c, let h) = $0 { return (c, h) } else { return nil } }
        XCTAssertGreaterThanOrEqual(rows.count, 5, "the where-it-goes table becomes one card per destination")
        XCTAssertEqual(rows.first?.1, ["Destination", "What", "When"])
        XCTAssertFalse(blocks.contains { if case .paragraph(let p) = $0 { return p.hasPrefix("|") } else { return false } },
                       "no raw table syntax shown")
    }

    /// The policy must keep naming every provider the app can send to (App Review compares them).
    func testThePolicyNamesEveryProvider() {
        let text = PolicyDocument.bundledText
        XCTAssertTrue(text.contains("Anthropic"))
        XCTAssertTrue(text.contains("OpenAI"))
        XCTAssertTrue(text.contains("a server you set up"))
    }
}
