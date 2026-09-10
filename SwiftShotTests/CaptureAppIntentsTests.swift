import XCTest
@testable import SwiftShot

@MainActor
final class CaptureAppIntentsTests: XCTestCase {
    func testIntentRouterPreservesExplicitModeQuickCopyAndPrivacy() async throws {
        var received: [CaptureIntentAction] = []
        let router = CaptureIntentRouter { received.append($0) }
        try await router.route(.start(mode: .window, quickCopy: true, privateCapture: true))
        try await router.route(.lastRegion(quickCopy: false))
        try await router.route(.history)
        XCTAssertEqual(received, [.start(mode: .window, quickCopy: true, privateCapture: true), .lastRegion(quickCopy: false), .history])
    }

    func testIntentRouterPropagatesErrorsInsteadOfClaimingSuccess() async {
        let router = CaptureIntentRouter { _ in throw CaptureError.permissionDenied }
        do { try await router.route(.history); XCTFail("The system caller must receive the failure") }
        catch { XCTAssertTrue(error is CaptureError) }
    }

    func testEverySystemModeMapsToItsNativeCaptureMode() {
        XCTAssertEqual(CaptureIntentMode.region.captureMode, .region)
        XCTAssertEqual(CaptureIntentMode.window.captureMode, .window)
        XCTAssertEqual(CaptureIntentMode.fullscreen.captureMode, .fullscreen)
        XCTAssertEqual(CaptureIntentMode.ocr.captureMode, .ocr)
    }
}
