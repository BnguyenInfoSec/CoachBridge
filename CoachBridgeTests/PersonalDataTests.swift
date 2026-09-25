import XCTest
@testable import CoachBridge

@MainActor
final class PersonalDataTests: XCTestCase {
    private let marker = "export-test-\(UUID().uuidString).json"
    private let fakeKey = "sk-ant-TEST-\(UUID().uuidString)"

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: PersonalData.supportDir.appendingPathComponent(marker))
        Keychain.delete(account: "export-test-account")
    }

    func testAnOldExportLeftInTmpIsRemovedByTheNextOne() throws {
        let stale = FileManager.default.temporaryDirectory.appendingPathComponent("coach-bridge-export-2020-01-01.json")
        try Data("{}".utf8).write(to: stale)
        let url = try PersonalData.export()
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
    }

    func testExportHasYourFilesAndSettingsButNeverKeys() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: PersonalData.supportDir, withIntermediateDirectories: true)
        try Data(#"{"title":"Group run","minutes":50}"#.utf8).write(to: PersonalData.supportDir.appendingPathComponent(marker))
        try Keychain.set(fakeKey, account: "export-test-account")
        UserDefaults.standard.set("export-test-value", forKey: "export.test.setting")
        defer { UserDefaults.standard.removeObject(forKey: "export.test.setting") }

        let url = try PersonalData.export()
        defer { try? fm.removeItem(at: url) }
        XCTAssertTrue(url.lastPathComponent.hasPrefix("coach-bridge-export-"))

        let data = try Data(contentsOf: url)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains(fakeKey), "an API key must never be exported")
        XCTAssertFalse(text.contains("sk-ant-TEST"))

        let doc = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(doc["format"] as? String, "coach-bridge-export")
        let files = try XCTUnwrap(doc["files"] as? [String: Any])
        let mine = try XCTUnwrap(files[marker] as? [String: Any])
        XCTAssertEqual(mine["title"] as? String, "Group run", "files are exported as JSON, not opaque blobs")
        let settings = try XCTUnwrap(doc["settings"] as? [String: Any])
        XCTAssertEqual(settings["export.test.setting"] as? String, "export-test-value")
    }
}
