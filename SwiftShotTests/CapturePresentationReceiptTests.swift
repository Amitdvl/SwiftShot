import XCTest
@testable import SwiftShot

final class CapturePresentationReceiptTests: XCTestCase {
    func testOnlyVisibleCurrentPresentationCanCompleteAndOnlyOnce() {
        var receipt = CapturePresentationReceipt()
        let first = UUID(), second = UUID()
        receipt.request(first)
        XCTAssertFalse(receipt.complete(first, isVisible: false))
        receipt.request(second)
        XCTAssertFalse(receipt.complete(first, isVisible: true), "A queued old layout cannot complete a newer presentation")
        XCTAssertTrue(receipt.complete(second, isVisible: true))
        XCTAssertFalse(receipt.complete(second, isVisible: true), "Repeated layout must preserve first readiness")
        receipt.request(second)
        XCTAssertFalse(receipt.complete(second, isVisible: true), "Re-rendering the same identity is not a new frame measurement")
        receipt.request(first)
        XCTAssertTrue(receipt.complete(first, isVisible: true))
    }
}
