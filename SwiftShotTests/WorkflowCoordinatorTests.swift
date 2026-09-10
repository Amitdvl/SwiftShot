import XCTest
@testable import SwiftShot

@MainActor
final class WorkflowCoordinatorTests: XCTestCase {
    func testNavigationCancelsAcquisitionAndInvalidatesItsToken() {
        let coordinator = CaptureSessionCoordinator()
        let old = coordinator.id
        let task = Task<[FrozenScreen], Error> { try await Task.sleep(for: .seconds(30)); return [] }
        coordinator.freezeTask = task
        let next = coordinator.begin()
        XCTAssertTrue(task.isCancelled)
        XCTAssertFalse(coordinator.isCurrent(old))
        XCTAssertTrue(coordinator.isCurrent(next))
        XCTAssertNil(coordinator.freezeTask)
    }

    func testExportAdmissionAndNewestClipboardWinner() throws {
        let coordinator = CaptureExportCoordinator()
        let firstID = UUID(), secondID = UUID()
        let first = try XCTUnwrap(coordinator.begin(documentID: firstID))
        coordinator.claimClipboard(first)
        XCTAssertTrue(coordinator.canPublishClipboard(first))
        XCTAssertNil(coordinator.begin(documentID: firstID))
        let second = try XCTUnwrap(coordinator.begin(documentID: secondID))
        coordinator.claimClipboard(second)
        XCTAssertFalse(coordinator.canPublishClipboard(first))
        XCTAssertTrue(coordinator.canPublishClipboard(second))
        coordinator.finish(first)
        XCTAssertTrue(coordinator.hasActiveExports)
        coordinator.finish(second)
        XCTAssertFalse(coordinator.hasActiveExports)
        XCTAssertFalse(coordinator.canPublishClipboard(second))
    }

    func testStaleFinishCannotReleaseNewerExportOfSameDocument() throws {
        let coordinator = CaptureExportCoordinator()
        let id = UUID()
        let first = try XCTUnwrap(coordinator.begin(documentID: id))
        coordinator.finish(first)
        let second = try XCTUnwrap(coordinator.begin(documentID: id))
        coordinator.finish(first)
        XCTAssertTrue(coordinator.isExporting(id))
        coordinator.finish(second)
        XCTAssertFalse(coordinator.isExporting(id))
    }
}
