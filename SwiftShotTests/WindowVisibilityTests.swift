import XCTest
import CoreGraphics
@testable import SwiftShot

final class WindowVisibilityTests: XCTestCase {
    func testFullyCoveredWindowsAreSkipped() {
        let window = CGRect(x: 100, y: 100, width: 400, height: 300)
        XCTAssertFalse(WindowVisibility.hasVisibleArea(window, behind: [CGRect(x: 0, y: 0, width: 1000, height: 1000)]))
        XCTAssertFalse(WindowVisibility.hasVisibleArea(window, behind: [
            CGRect(x: 100, y: 100, width: 200, height: 300), CGRect(x: 300, y: 100, width: 200, height: 300)
        ]))
    }

    func testPartiallyExposedWindowsRemainSelectable() {
        let window = CGRect(x: -500, y: 100, width: 400, height: 300)
        XCTAssertTrue(WindowVisibility.hasVisibleArea(window, behind: [CGRect(x: -500, y: 100, width: 390, height: 300)]))
        XCTAssertTrue(WindowVisibility.hasVisibleArea(window, behind: [CGRect(x: 0, y: 0, width: 1000, height: 1000)]))
    }
}
