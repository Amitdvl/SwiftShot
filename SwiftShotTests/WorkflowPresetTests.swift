import XCTest
@testable import SwiftShot

final class WorkflowPresetTests: XCTestCase {
    func testLegacyDecorativeRegionDoesNotStyleQuickCopyOrWindow() {
        var settings = AppSettings.default
        settings.style.backgroundID = "bundled:blue"
        XCTAssertEqual(settings.style(for: .region).backgroundID, "bundled:blue")
        XCTAssertEqual(settings.style(for: .window).backgroundID, "")
        XCTAssertEqual(settings.style(for: .quickCopy).backgroundID, "")
    }

    func testEachWorkflowStyleAndNamedPresetRoundTripIndependently() throws {
        var settings = AppSettings.default
        var style = CaptureStyle()
        style.backgroundID = "bundled:blue"
        settings.setStyle(style, for: .window)
        settings.presets = [CaptureStylePreset(name: "Review", style: style)]
        settings.retentionSavedCount = 50
        let loaded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(loaded.style(for: .window), style)
        XCTAssertEqual(loaded.style(for: .region).backgroundID, "")
        XCTAssertEqual(loaded.style(for: .quickCopy).backgroundID, "")
        XCTAssertEqual(loaded.presets, settings.presets)
        XCTAssertEqual(loaded.retentionSavedCount, 50)
    }
}
