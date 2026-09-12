import AppKit
import XCTest
@testable import SwiftShot

@MainActor
final class StatusItemRegressionTests: XCTestCase {
    func testInstalledAppDeclaresAgentLaunchMode() throws {
        let info = try XCTUnwrap(Bundle.main.infoDictionary)
        XCTAssertEqual(
            info["LSUIElement"] as? Bool,
            true,
            "SwiftShot must be classified as a menu-bar agent before Control Center hosts its status item"
        )
    }
}
