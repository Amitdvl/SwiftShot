import XCTest
@testable import SwiftShot

final class QuickWorkflowTests: XCTestCase {
    // Losing the dedicated quick-copy route forces every raw capture through editing.
    func testDefaultQuickCopyShortcutIsSeparateFromRegion() throws {
        let quick = try XCTUnwrap(ShortcutConfig.defaults.first { $0.mode == "quickCopy" })
        let region = try XCTUnwrap(ShortcutConfig.defaults.first { $0.mode == "region" })
        XCTAssertTrue(quick.enabled)
        XCTAssertEqual(quick.keyCode, region.keyCode)
        XCTAssertNotEqual(quick.modifiers, region.modifiers)
    }

    // Old saved preferences must gain the new route without losing custom bindings.
    func testSettingsMigrationAddsMissingQuickCopyWithoutReplacingBindings() throws {
        let json = #"{"saveDirectory":"/tmp","version":2,"shortcuts":[{"mode":"region","keyCode":7,"modifiers":768,"enabled":false,"displayString":"custom"}]}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.shortcuts.first(where: { $0.mode == "region" })?.keyCode, 7)
        XCTAssertEqual(settings.shortcuts.first(where: { $0.mode == "region" })?.enabled, false)
        XCTAssertNotNil(settings.shortcuts.first(where: { $0.mode == "quickCopy" }))
    }

    // Dropping these values on relaunch can turn a private workflow into disk history.
    func testPrivacyAndSeparateQuickStyleSurviveSettingsRoundTrip() throws {
        let json = #"{"saveDirectory":"/tmp","privateCapture":true,"showRecentThumbnail":false,"historyIndexingEnabled":false,"retentionDays":7,"shareMaxDimension":1600,"quickCopyStyle":{"backgroundID":"bundled:blue","padding":12,"cornerRadius":3,"shadow":0}}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        XCTAssertEqual(encoded["privateCapture"] as? Bool, true)
        XCTAssertEqual(encoded["showRecentThumbnail"] as? Bool, false)
        XCTAssertEqual(encoded["historyIndexingEnabled"] as? Bool, false)
        XCTAssertEqual(encoded["retentionDays"] as? Int, 7)
        XCTAssertEqual(encoded["shareMaxDimension"] as? Int, 1600)
        XCTAssertEqual((encoded["quickCopyStyle"] as? [String: Any])?["backgroundID"] as? String, "bundled:blue")
    }
}
