import XCTest
import AppKit
import ScreenCaptureKit
import CoreVideo
@testable import SwiftShot

@MainActor
final class CaptureAcquisitionPolicyTests: XCTestCase {
    private let displays = [
        CaptureDisplayLayout(id: 10, frame: CGRect(x: 0, y: 0, width: 1000, height: 800)),
        CaptureDisplayLayout(id: 20, frame: CGRect(x: -800, y: 100, width: 800, height: 600))
    ]

    func testFullscreenTargetsOnlyDisplayUnderPointer() throws {
        let selected = try CaptureAcquisitionPolicy.targets(mode: .fullscreen, pointer: CGPoint(x: -200, y: 300), displays: displays)
        XCTAssertEqual(selected.map(\.id), [20])
    }

    func testFullscreenFallsBackToFirstDisplayWhenPointerIsOutsideLayout() throws {
        let selected = try CaptureAcquisitionPolicy.targets(mode: .fullscreen, pointer: CGPoint(x: 5000, y: 5000), displays: displays)
        XCTAssertEqual(selected.map(\.id), [10])
    }

    func testRegionAndOCRRetainAllDisplaysWithoutRequiringWindowMetadata() throws {
        for mode in [CaptureMode.region, .ocr] {
            let selected = try CaptureAcquisitionPolicy.targets(mode: mode, pointer: .zero, displays: displays)
            XCTAssertEqual(selected.map(\.id), [10, 20])
        }
    }

    func testDisplayMetadataExcludesOnlyExactCurrentProcessWithoutWindowMetadata() async throws {
        let cache = CaptureDisplayMetadataCache<Int, MetadataTestApplication>(ownProcessID: 42, processID: { $0.pid })
        var queries: [Bool] = []
        let result = try await cache.metadata(for: displays) { onScreenOnly in
            queries.append(onScreenOnly)
            return (displays: [7], applications: [
                MetadataTestApplication(pid: 11, bundleID: "same.bundle"),
                MetadataTestApplication(pid: 42, bundleID: "same.bundle"),
                MetadataTestApplication(pid: 73, bundleID: "other.bundle")
            ])
        }
        XCTAssertEqual(result.excludedApplications.map(\.pid), [42])
        XCTAssertEqual(result.displays, [7])
        XCTAssertEqual(queries, [true])
    }

    func testMissingOwnApplicationUsesOneOffscreenMetadataRefresh() async throws {
        let cache = CaptureDisplayMetadataCache<Int, MetadataTestApplication>(ownProcessID: 42, processID: { $0.pid })
        var queries: [Bool] = []
        let result = try await cache.metadata(for: displays) { onScreenOnly in
            queries.append(onScreenOnly)
            return onScreenOnly ? (displays: [1], applications: []) :
                (displays: [2], applications: [MetadataTestApplication(pid: 42, bundleID: "own.bundle")])
        }
        XCTAssertEqual(queries, [true, false])
        XCTAssertEqual(result.excludedApplications.map(\.pid), [42])
        XCTAssertEqual(result.displays, [2], "Use the refreshed display metadata with its own-app record")
    }

    func testUnresolvedOwnApplicationFailsClosedAndIsNotCached() async throws {
        let cache = CaptureDisplayMetadataCache<Int, MetadataTestApplication>(ownProcessID: 42, processID: { $0.pid })
        var queries: [Bool] = []
        do {
            _ = try await cache.metadata(for: displays) { onScreenOnly in
                queries.append(onScreenOnly)
                return (displays: [1], applications: [MetadataTestApplication(pid: 11, bundleID: "own.bundle")])
            }
            XCTFail("Display capture must not receive an empty own-app exclusion")
        } catch {
            XCTAssertTrue(error is CaptureError)
            XCTAssertTrue(error.localizedDescription.contains("Window"), "Offer the explicit-window fallback")
        }
        XCTAssertEqual(queries, [true, false], "No retries beyond one offscreen refresh")
        let retry = try await cache.metadata(for: displays) { onScreenOnly in
            queries.append(onScreenOnly)
            return (displays: [2], applications: [MetadataTestApplication(pid: 42, bundleID: "own.bundle")])
        }
        XCTAssertEqual(queries, [true, false, true])
        XCTAssertEqual(retry.excludedApplications.map(\.pid), [42])
        XCTAssertEqual(retry.displays, [2])
    }

    func testPositiveOwnApplicationCacheSharesDisplayInvalidationBoundaries() async throws {
        let cache = CaptureDisplayMetadataCache<Int, MetadataTestApplication>(ownProcessID: 42, processID: { $0.pid })
        var queries = 0
        let query: @MainActor (Bool) async throws -> (displays: [Int], applications: [MetadataTestApplication]) = { _ in
            queries += 1
            return (displays: [queries], applications: [MetadataTestApplication(pid: 42, bundleID: "own.bundle")])
        }
        _ = try await cache.metadata(for: displays, query: query)
        let reused = try await cache.metadata(for: Array(displays.reversed()), query: query)
        XCTAssertEqual(reused.displays, [1])
        XCTAssertEqual(reused.excludedApplications.map(\.pid), [42])
        XCTAssertEqual(queries, 1)
        cache.invalidate()
        let refreshed = try await cache.metadata(for: displays, query: query)
        XCTAssertEqual(refreshed.displays, [2])
        let changed = try await cache.metadata(for: [displays[0]], query: query)
        XCTAssertEqual(changed.displays, [3])
        XCTAssertEqual(changed.excludedApplications.map(\.pid), [42])
        XCTAssertEqual(queries, 3)
    }

    func testEmptyAndDuplicateDisplayLayoutsAreRejected() {
        XCTAssertThrowsError(try CaptureAcquisitionPolicy.targets(mode: .region, pointer: .zero, displays: []))
        XCTAssertThrowsError(try CaptureAcquisitionPolicy.targets(mode: .region, pointer: .zero, displays: [displays[0], displays[0]]))
    }

    func testLayoutValidationIgnoresEnumerationOrderButRejectsMovedOrRemovedDisplay() {
        XCTAssertTrue(CaptureAcquisitionPolicy.layoutMatches(displays, Array(displays.reversed())))
        XCTAssertFalse(CaptureAcquisitionPolicy.layoutMatches(displays, [displays[0]]))
        let moved = CaptureDisplayLayout(id: 20, frame: CGRect(x: -800, y: 101, width: 800, height: 600))
        XCTAssertFalse(CaptureAcquisitionPolicy.layoutMatches(displays, [displays[0], moved]))
    }

    func testRetinaPixelDimensionsAndAlignedMemoryReservation() throws {
        let size = try CaptureAcquisitionPolicy.dimensions(points: CGSize(width: 100, height: 50), scale: 2)
        XCTAssertEqual(size.width, 200)
        XCTAssertEqual(size.height, 100)
        // 200 BGRA pixels => 800 bytes, aligned to 1024, with two buffers reserved.
        XCTAssertEqual(size.reservedBytes, 204_800)
    }

    func testWindowConfigurationRetainsAlphaAndExcludesShadowAtNativeResolution() throws {
        let size = try CaptureAcquisitionPolicy.dimensions(points: CGSize(width: 500, height: 300), scale: 2)
        let configuration = ScreenCaptureService.configuration(size: size, window: true)
        XCTAssertFalse(configuration.shouldBeOpaque)
        XCTAssertTrue(configuration.ignoreShadowsSingleWindow)
        XCTAssertFalse(configuration.showsCursor)
        XCTAssertFalse(configuration.scalesToFit)
        XCTAssertEqual(configuration.width, 1000)
        XCTAssertEqual(configuration.height, 600)
        XCTAssertEqual(configuration.pixelFormat, kCVPixelFormatType_32BGRA)
        XCTAssertEqual(configuration.captureResolution, .best)
    }

    func testInvalidAndOverflowingDimensionsFailBeforeAllocation() {
        for size in [CGSize.zero, CGSize(width: -1, height: 50), CGSize(width: CGFloat.infinity, height: 1),
                     CGSize(width: CGFloat.greatestFiniteMagnitude, height: 2), CGSize(width: 9000, height: 9000)] {
            XCTAssertThrowsError(try CaptureAcquisitionPolicy.dimensions(points: size, scale: 1))
        }
        for scale in [CGFloat.zero, -1, .nan, .infinity] {
            XCTAssertThrowsError(try CaptureAcquisitionPolicy.dimensions(points: CGSize(width: 100, height: 100), scale: scale))
        }
    }

    func testMemoryBudgetRejectsAggregateAndOverlappingSessionAllocationsAndReleases() throws {
        let budget = CaptureMemoryBudget(limit: 100)
        try budget.reserve(60)
        XCTAssertThrowsError(try budget.reserve(41))
        try budget.reserve(40)
        XCTAssertThrowsError(try budget.reserve(1))
        budget.release(60)
        try budget.reserve(60)
        budget.release(100)
        try budget.reserve(100)
    }

    func testMemoryBudgetRejectsOverflowWithoutLosingExistingReservation() throws {
        let budget = CaptureMemoryBudget(limit: Int.max)
        try budget.reserve(Int.max - 10)
        XCTAssertThrowsError(try budget.reserve(20))
        budget.release(Int.max - 10)
        try budget.reserve(Int.max)
    }

    func testBatchBoundsConcurrencyAndReturnsInputOrderDespiteCompletionOrder() async throws {
        let probe = AcquisitionConcurrencyProbe()
        let values = try await CaptureAcquisitionBatch.run(Array(0..<5), maximumConcurrent: 2) { value in
            probe.enter()
            defer { probe.leave() }
            try await Task.sleep(for: value == 0 ? .milliseconds(30) : .milliseconds(2))
            return value * 10
        }
        XCTAssertEqual(values, [0, 10, 20, 30, 40])
        XCTAssertEqual(probe.peak, 2)
        XCTAssertEqual(probe.active, 0)
    }

    func testBatchFailureCancelsInFlightWorkAndDoesNotStartRemainingWork() async {
        let probe = AcquisitionConcurrencyProbe()
        do {
            _ = try await CaptureAcquisitionBatch.run(Array(0..<6), maximumConcurrent: 2) { value in
                probe.started.append(value)
                if value == 0 { throw CaptureError.failed("Acquisition failed") }
                try await Task.sleep(for: .seconds(10))
                return value
            }
            XCTFail("Failed acquisition must not yield a partial screen set")
        } catch {
            XCTAssertTrue(probe.started.allSatisfy { $0 < 2 })
        }
    }

    func testAlreadyCancelledBatchStartsNoAcquisition() async {
        let probe = AcquisitionConcurrencyProbe()
        let task = Task { @MainActor in
            return try await CaptureAcquisitionBatch.run([1, 2, 3], maximumConcurrent: 2) { value in
                probe.started.append(value)
                return value
            }
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation must propagate") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(probe.started.isEmpty)
    }
}

@MainActor
private final class AcquisitionConcurrencyProbe {
    var active = 0
    var peak = 0
    var started: [Int] = []
    func enter() { active += 1; peak = max(peak, active) }
    func leave() { active -= 1 }
}

private struct MetadataTestApplication {
    let pid: Int32
    let bundleID: String
}
