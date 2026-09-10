import XCTest
@testable import SwiftShot

final class CaptureLatencyTraceTests: XCTestCase {
    func testDisabledAndExplicitNilMarksNeverReadTheClockOrRetainEvents() {
        let clock = TraceClock()
        let trace = CaptureLatencyTrace(now: { clock.read() })
        XCTAssertFalse(trace.mark(.captureRequested, for: UUID()))
        XCTAssertFalse(trace.mark(.captureRequested, for: nil))
        XCTAssertFalse(trace.endRun(nil))
        XCTAssertEqual(clock.readCount, 0)
        XCTAssertTrue(trace.snapshot().runs.isEmpty)
    }

    func testArmedTraceRecordsActualOffsetsAndClosedPresentationMetadata() throws {
        let clock = TraceClock(1_000_000)
        let trace = CaptureLatencyTrace(now: { clock.read() })
        let id = UUID()
        XCTAssertTrue(trace.beginRun(id))
        clock.set(3_500_000)
        XCTAssertTrue(trace.mark(.layoutStarted, for: id, presentation: .selector, surface: 0))
        clock.set(5_000_000)
        XCTAssertTrue(trace.mark(.receiptDelivered, for: id, presentation: .editor, surface: 0))
        let run = try XCTUnwrap(trace.snapshot().runs.first)
        XCTAssertEqual(run.id, id)
        XCTAssertEqual(run.events.map(\.offsetMilliseconds), [2.5, 4])
        XCTAssertEqual(run.events.map(\.stage), [.layoutStarted, .receiptDelivered])
        XCTAssertEqual(run.events.map(\.presentation), [.selector, .editor])
        XCTAssertEqual(run.events.map(\.surface), [0, 0])
        XCTAssertFalse(run.isComplete)
    }

    func testStaleAndEndedCallbacksCannotWriteIntoANewerRun() throws {
        let clock = TraceClock()
        let trace = CaptureLatencyTrace(now: { clock.read() })
        let old = UUID(), current = UUID()
        XCTAssertTrue(trace.beginRun(old))
        XCTAssertTrue(trace.beginRun(current))
        let reads = clock.readCount
        XCTAssertFalse(trace.mark(.transactionCompleted, for: old))
        XCTAssertFalse(trace.mark(.receiptDelivered, for: nil))
        XCTAssertFalse(trace.endRun(old))
        XCTAssertEqual(clock.readCount, reads)
        XCTAssertEqual(trace.snapshot().activeRunID, current)
        XCTAssertTrue(trace.endRun(current))
        XCTAssertFalse(trace.mark(.receiptDelivered, for: current))
        XCTAssertNil(trace.snapshot().activeRunID)
        XCTAssertTrue(trace.snapshot().runs.allSatisfy(\.isComplete))
    }

    func testEventAndRunOverflowAreBoundedAndReportedWithoutClockReads() throws {
        let clock = TraceClock()
        let trace = CaptureLatencyTrace(runCapacity: 2, eventCapacity: 2, now: { clock.read() })
        let first = UUID(), second = UUID(), third = UUID()
        XCTAssertTrue(trace.beginRun(first))
        XCTAssertTrue(trace.mark(.layoutStarted, for: first))
        XCTAssertTrue(trace.mark(.layoutFinished, for: first))
        let reads = clock.readCount
        XCTAssertFalse(trace.mark(.displayStarted, for: first))
        XCTAssertEqual(clock.readCount, reads)
        XCTAssertEqual(trace.snapshot().runs.first?.droppedEvents, 1)
        XCTAssertEqual(trace.snapshot().runs.first?.events.count, 2)
        XCTAssertTrue(trace.beginRun(second))
        XCTAssertTrue(trace.beginRun(third))
        XCTAssertEqual(trace.snapshot().runs.map(\.id), [second, third])
        XCTAssertEqual(trace.snapshot().droppedRuns, 1)
        XCTAssertFalse(trace.mark(.receiptDelivered, for: first))
    }

    func testDuplicateArmDoesNotResetTraceAndResetDisarmsPendingCallbacks() throws {
        let trace = CaptureLatencyTrace()
        let id = UUID()
        XCTAssertTrue(trace.beginRun(id))
        XCTAssertTrue(trace.mark(.captureRequested, for: id))
        XCTAssertFalse(trace.beginRun(id))
        XCTAssertEqual(trace.snapshot().runs.first?.events.count, 1)
        trace.reset()
        XCTAssertFalse(trace.mark(.receiptDelivered, for: id))
        XCTAssertTrue(trace.snapshot().runs.isEmpty)
        XCTAssertEqual(trace.snapshot().droppedRuns, 0)
        XCTAssertNil(trace.snapshot().activeRunID)
    }

    func testInvalidSurfaceAndBackwardsClockDoNotProduceMisleadingEvents() throws {
        let clock = TraceClock(5_000_000)
        let trace = CaptureLatencyTrace(now: { clock.read() })
        let id = UUID()
        XCTAssertTrue(trace.beginRun(id))
        XCTAssertFalse(trace.mark(.panelOrderStarted, for: id, surface: -1))
        XCTAssertFalse(trace.mark(.panelOrderStarted, for: id, surface: 16))
        clock.set(4_000_000)
        XCTAssertFalse(trace.mark(.layoutStarted, for: id))
        XCTAssertTrue(trace.snapshot().runs.first?.events.isEmpty == true)
    }

    func testExportContainsOnlyTraceSchemaMetadata() throws {
        let trace = CaptureLatencyTrace()
        let id = UUID()
        trace.beginRun(id)
        trace.mark(.receiptEnqueued, for: id, presentation: .selector, surface: 1)
        let data = try JSONEncoder().encode(trace.snapshot())
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["schemaVersion", "runs", "droppedRuns", "activeRunID"])
        let runs = try XCTUnwrap(json["runs"] as? [[String: Any]])
        let run = try XCTUnwrap(runs.first)
        XCTAssertEqual(Set(run.keys), ["id", "events", "droppedEvents", "isComplete"])
        let events = try XCTUnwrap(run["events"] as? [[String: Any]])
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(Set(event.keys), ["stage", "offsetMilliseconds", "presentation", "surface"])
        XCTAssertEqual(event["stage"] as? String, "receiptEnqueued")
    }

    // New Window phase values must survive the real export/decoder boundary without native identity fields.
    func testWindowPhaseEventsRoundTripAndLateReturnCannotEnterReplacementRun() throws {
        let names = ["windowCaptureStarted", "windowMetadataStarted", "windowMetadataResolved",
                     "windowImageRequestStarted", "windowImageRequestReturned", "windowResultPrepared"]
        let stages = try names.map { try XCTUnwrap(CaptureLatencyTrace.Stage(rawValue: $0), "Window phase is not supported by the trace schema: \($0)") }
        let clock = TraceClock()
        let trace = CaptureLatencyTrace(now: { clock.read() })
        let first = UUID(), second = UUID()
        XCTAssertTrue(trace.beginRun(first))
        let offsets: [UInt64] = [1, 3, 8, 9, 17, 18]
        for (stage, offset) in zip(stages, offsets) {
            clock.set(offset * 1_000_000)
            XCTAssertTrue(trace.mark(stage, for: first))
        }
        XCTAssertTrue(trace.beginRun(second))
        let reads = clock.readCount
        XCTAssertFalse(trace.mark(stages[4], for: first), "An old image-request return must not attach to the replacement run")
        XCTAssertEqual(clock.readCount, reads)

        let data = try JSONEncoder().encode(trace.snapshot())
        let decoded = try JSONDecoder().decode(CaptureLatencyTrace.Report.self, from: data)
        let old = try XCTUnwrap(decoded.runs.first)
        XCTAssertEqual(old.id, first)
        XCTAssertEqual(old.events.map(\.stage.rawValue), names)
        XCTAssertEqual(old.events.map(\.offsetMilliseconds), [1, 3, 8, 9, 17, 18])
        XCTAssertTrue(old.events.allSatisfy { $0.presentation == nil && $0.surface == nil })
        XCTAssertTrue(decoded.runs.last?.events.isEmpty == true)
        XCTAssertEqual(decoded.activeRunID, second)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let runs = try XCTUnwrap(json["runs"] as? [[String: Any]])
        let events = try XCTUnwrap(runs.first?["events"] as? [[String: Any]])
        for event in events {
            XCTAssertEqual(Set(event.keys), ["stage", "offsetMilliseconds"], "Window timing must not export window/display IDs, titles, pixels, or other payload")
        }
    }
}

private final class TraceClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64
    private var reads = 0
    init(_ value: UInt64 = 0) { self.value = value }
    var readCount: Int { lock.withLock { reads } }
    func set(_ value: UInt64) { lock.withLock { self.value = value } }
    func read() -> UInt64 { lock.withLock { reads += 1; return value } }
}
