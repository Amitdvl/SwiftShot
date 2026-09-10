import CoreGraphics
import Foundation
import XCTest
@testable import SwiftShot

@MainActor
final class WindowImageCallbackBridgeTests: XCTestCase {
    // Break: recording after the await resumes measures the actor hop, not SDK delivery.
    func testCallbackTimestampIsRecordedBeforeRequestReturnsOrCallerResumes() async throws {
        let clock = WindowCallbackClock(1_000_000)
        let trace = CaptureLatencyTrace(now: { clock.read() })
        let runID = UUID()
        trace.beginRun(runID)
        let image = try fixtureImage()
        var stagesBeforeRequestReturns: [CaptureLatencyTrace.Stage] = []

        do {
            let returned = try await WindowImageCallbackBridge.capture(traceRunID: runID, trace: trace) { callback in
                clock.set(4_000_000)
                callback(image, nil)
                stagesBeforeRequestReturns = trace.snapshot().runs[0].events.map(\.stage)
                clock.set(90_000_000)
            }
            XCTAssertTrue(returned === image, "The bridge must return the SDK's image, not a rendered or encoded copy")
        } catch {
            XCTFail("The successful SDK callback must return its image: \(error)")
        }
        trace.mark(.windowImageRequestReturned, for: runID)
        let events = try XCTUnwrap(trace.snapshot().runs.first).events
        XCTAssertEqual(stagesBeforeRequestReturns, [.windowImageCallbackReceived])
        XCTAssertEqual(events.map(\.stage), [.windowImageCallbackReceived, .windowImageRequestReturned])
        XCTAssertEqual(events.map(\.offsetMilliseconds), [3, 89])
        XCTAssertTrue(events.allSatisfy { $0.presentation == nil && $0.surface == nil })
    }

    // Break: dispatching the callback mark to MainActor loses its native-thread boundary.
    func testBackgroundCallbackRecordsWhileMainActorIsStillInsideRequest() async throws {
        let clock = WindowCallbackClock(2_000_000)
        let trace = CaptureLatencyTrace(now: { clock.read() })
        let runID = UUID()
        trace.beginRun(runID)
        let image = try fixtureImage()
        let observation = WindowCallbackObservation()
        let callbackFinished = DispatchSemaphore(value: 0)

        do {
            let returned = try await WindowImageCallbackBridge.capture(traceRunID: runID, trace: trace) { callback in
                DispatchQueue.global(qos: .userInitiated).async {
                    clock.set(7_000_000)
                    callback(image, nil)
                    observation.record(onMainThread: Thread.isMainThread,
                                       events: trace.snapshot().runs[0].events)
                    callbackFinished.signal()
                }
                // Bound the negative case. The production bridge never blocks;
                // only this fixture holds MainActor to expose an illicit hop.
                XCTAssertEqual(callbackFinished.wait(timeout: .now() + 2), .success)
                clock.set(100_000_000)
            }
            XCTAssertTrue(returned === image)
        } catch {
            XCTFail("The background SDK callback must return its image: \(error)")
        }
        let observed = observation.snapshot()
        XCTAssertEqual(observed.onMainThread, false)
        XCTAssertEqual(observed.events.map(\.stage), [.windowImageCallbackReceived])
        XCTAssertEqual(observed.events.map(\.offsetMilliseconds), [5])
        XCTAssertEqual(trace.snapshot().runs[0].events.map(\.offsetMilliseconds), [5])
    }

    // Break: the bridge returns or fails when the SDK request returns, before
    // the deferred callback delivers pixels. Added after the original RED run;
    // this case requires its own negative-control evidence.
    func testDeferredCallbackKeepsCapturePendingUntilSDKDeliversImage() async throws {
        let clock = WindowCallbackClock(1_000_000)
        let trace = CaptureLatencyTrace(now: { clock.read() })
        let runID = UUID()
        trace.beginRun(runID)
        let image = try fixtureImage()
        let gate = WindowDeferredCallbackGate()
        let requestReturned = expectation(description: "SDK request returned without invoking its callback")
        let captureCompleted = expectation(description: "Deferred callback completed the capture")
        let capture = Task { @MainActor in
            do {
                let returned = try await WindowImageCallbackBridge.capture(traceRunID: runID, trace: trace) { callback in
                    gate.callback = callback
                    // The queued barrier cannot execute until this synchronous
                    // MainActor request has returned. It is not a timing guess.
                    DispatchQueue.main.async { requestReturned.fulfill() }
                }
                gate.result = .success(returned)
            } catch {
                gate.result = .failure(error)
            }
            captureCompleted.fulfill()
        }
        defer { capture.cancel(); gate.callback = nil }

        await fulfillment(of: [requestReturned], timeout: 1)
        XCTAssertNil(gate.result, "Returning from the SDK request must not complete image acquisition")
        XCTAssertTrue(trace.snapshot().runs[0].events.isEmpty, "No callback boundary exists before SDK delivery")
        guard let callback = gate.callback else {
            return XCTFail("The SDK must receive a callback that survives its request returning")
        }
        clock.set(8_000_000)
        callback(image, nil)
        await fulfillment(of: [captureCompleted], timeout: 1)
        switch gate.result {
        case .success(let returned): XCTAssertTrue(returned === image)
        case .failure(let error): XCTFail("Deferred SDK success must return its exact image: \(error)")
        case nil: XCTFail("The capture must resume after the deferred callback")
        }
        XCTAssertEqual(trace.snapshot().runs[0].events.map(\.stage), [.windowImageCallbackReceived])
        XCTAssertEqual(trace.snapshot().runs[0].events.map(\.offsetMilliseconds), [7])
    }

    // Break: eager cancellation releases the capture reservation while the SDK
    // still owns an in-flight image request. Uses the real budget and bridge;
    // the surrounding guard/defer mirror the unchanged Window service boundary.
    func testCancellationRetainsMemoryReservationUntilDeferredCallbackFinishes() async throws {
        let budget = CaptureMemoryBudget(limit: 32)
        let trace = CaptureLatencyTrace()
        let runID = UUID()
        trace.beginRun(runID)
        let image = try fixtureImage()
        let gate = WindowDeferredCallbackGate()
        let requestReturned = expectation(description: "Reserved SDK request returned without completing")
        let captureCompleted = expectation(description: "Canceled capture drained its SDK callback")
        let capture = Task { @MainActor in
            defer { captureCompleted.fulfill() }
            do {
                try budget.reserve(32)
                defer { budget.release(32) }
                let returned = try await WindowImageCallbackBridge.capture(traceRunID: runID, trace: trace) { callback in
                    gate.callback = callback
                    DispatchQueue.main.async { requestReturned.fulfill() }
                }
                // The bridge transports SDK completion; the service's existing
                // post-await check prevents canceled pixels from publication.
                try Task.checkCancellation()
                gate.result = .success(returned)
            } catch {
                gate.result = .failure(error)
            }
        }
        defer { capture.cancel(); gate.callback = nil }
        await fulfillment(of: [requestReturned], timeout: 1)
        XCTAssertNil(gate.result)
        assertReservationIsHeld(budget)

        capture.cancel()
        // Service another actor/queue turn after cancellation, without using a
        // sleep duration as evidence that the owned request remains pending.
        await withCheckedContinuation { (barrier: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { barrier.resume() }
        }
        XCTAssertNil(gate.result, "Cancellation must not complete the bridge before SDK delivery")
        assertReservationIsHeld(budget)
        guard let callback = gate.callback else {
            return XCTFail("The pending SDK callback must remain available after cancellation")
        }
        callback(image, nil)
        await fulfillment(of: [captureCompleted], timeout: 1)
        switch gate.result {
        case .failure(let error): XCTAssertTrue(error is CancellationError)
        case .success: XCTFail("Canceled SDK pixels must fail the post-await guard")
        case nil: XCTFail("The canceled request must drain once SDK completion arrives")
        }
        XCTAssertEqual(trace.snapshot().runs[0].events.map(\.stage), [.windowImageCallbackReceived])
        try budget.reserve(32)
        budget.release(32)
    }

    // Break: resolving activeRunID at completion labels old pixels as the new run.
    func testLateCallbackCannotAttachToReplacementTraceRun() async throws {
        let clock = WindowCallbackClock()
        let trace = CaptureLatencyTrace(now: { clock.read() })
        let oldRun = UUID(), replacementRun = UUID()
        trace.beginRun(oldRun)
        let image = try fixtureImage()

        do {
            let returned = try await WindowImageCallbackBridge.capture(traceRunID: oldRun, trace: trace) { callback in
                clock.set(5_000_000)
                trace.beginRun(replacementRun)
                clock.set(9_000_000)
                callback(image, nil)
            }
            XCTAssertTrue(returned === image, "Trace rejection must not alter acquisition results")
        } catch {
            XCTFail("A stale diagnostic ID must not reject otherwise valid SDK pixels: \(error)")
        }
        let report = trace.snapshot()
        XCTAssertEqual(report.runs.map(\.id), [oldRun, replacementRun])
        XCTAssertTrue(report.runs.allSatisfy { $0.events.isEmpty })
        XCTAssertEqual(report.activeRunID, replacementRun)
        XCTAssertEqual(clock.readCount, 2, "Rejected stale marks must not consult the clock")
    }

    // Break: a nil/unarmed request falls back to the current diagnostic run.
    func testNilTraceIDDoesNotRecordInAnUnrelatedActiveRun() async throws {
        let clock = WindowCallbackClock()
        let trace = CaptureLatencyTrace(now: { clock.read() })
        let unrelatedRun = UUID()
        trace.beginRun(unrelatedRun)
        let image = try fixtureImage()
        do {
            let returned = try await WindowImageCallbackBridge.capture(traceRunID: nil, trace: trace) { callback in
                callback(image, nil)
            }
            XCTAssertTrue(returned === image)
        } catch {
            XCTFail("Disabled instrumentation must preserve successful acquisition: \(error)")
        }
        XCTAssertEqual(trace.snapshot().activeRunID, unrelatedRun)
        XCTAssertTrue(trace.snapshot().runs[0].events.isEmpty)
        XCTAssertEqual(clock.readCount, 1)
    }

    // Break: dropping or wrapping an SDK error loses its original failure identity.
    func testSDKErrorIsPropagatedWithoutSubstitutionAndCallbackIsTraced() async {
        let trace = CaptureLatencyTrace()
        let runID = UUID()
        trace.beginRun(runID)
        let expected = NSError(domain: "SyntheticWindowSDK", code: 731)
        do {
            _ = try await WindowImageCallbackBridge.capture(traceRunID: runID, trace: trace) { callback in
                callback(nil, expected)
            }
            XCTFail("The SDK error must be thrown")
        } catch {
            let received = error as NSError
            XCTAssertTrue(received === expected,
                errorIdentityDiagnostic("window-error", expected: expected, actual: error, received: received))
        }
        XCTAssertEqual(trace.snapshot().runs[0].events.map(\.stage), [.windowImageCallbackReceived])
    }

    // Break: preferring a non-nil image over an SDK error incorrectly publishes failure pixels.
    func testSDKErrorTakesPrecedenceWhenCallbackAlsoContainsAnImage() async throws {
        let trace = CaptureLatencyTrace()
        let runID = UUID()
        trace.beginRun(runID)
        let image = try fixtureImage()
        let expected = NSError(domain: "SyntheticWindowSDK", code: 732)
        do {
            _ = try await WindowImageCallbackBridge.capture(traceRunID: runID, trace: trace) { callback in
                callback(image, expected)
            }
            XCTFail("An SDK error must win even when an image accompanies it")
        } catch {
            let received = error as NSError
            XCTAssertTrue(received === expected,
                errorIdentityDiagnostic("window-image-and-error", expected: expected, actual: error, received: received))
        }
        XCTAssertEqual(trace.snapshot().runs[0].events.map(\.stage), [.windowImageCallbackReceived])
    }

    // Break: a malformed empty callback resumes successfully or never resumes.
    func testMissingImageAndErrorFailsClosedAfterRecordingCallback() async {
        let trace = CaptureLatencyTrace()
        let runID = UUID()
        trace.beginRun(runID)
        let captureCompleted = expectation(description: "Empty callback resumes with a capture failure")
        let capture = Task { @MainActor in
            defer { captureCompleted.fulfill() }
            do {
                _ = try await WindowImageCallbackBridge.capture(traceRunID: runID, trace: trace) { callback in
                    callback(nil, nil)
                }
                XCTFail("An empty callback cannot produce a captured image")
            } catch {
                guard let failure = error as? CaptureError, case .failed = failure else {
                    return XCTFail("An empty SDK result must become an explicit capture failure, got \(error)")
                }
            }
        }
        defer { capture.cancel() }
        // Do not await the owned task's value: a missing-resume mutation must
        // fail this bounded expectation instead of suspending the test forever.
        await fulfillment(of: [captureCompleted], timeout: 1)
        XCTAssertEqual(trace.snapshot().runs[0].events.map(\.stage), [.windowImageCallbackReceived])
    }

    // Break: the event is recorded locally but lost or enriched with pixels/identity on export.
    func testCallbackEventSurvivesRealTraceExportWithOnlyTimingMetadata() async throws {
        let trace = CaptureLatencyTrace()
        let runID = UUID()
        trace.beginRun(runID)
        let image = try fixtureImage()
        do {
            _ = try await WindowImageCallbackBridge.capture(traceRunID: runID, trace: trace) { callback in
                callback(image, nil)
            }
        } catch {
            XCTFail("The SDK callback must complete before export: \(error)")
        }
        let data = try JSONEncoder().encode(trace.snapshot())
        let decoded = try JSONDecoder().decode(CaptureLatencyTrace.Report.self, from: data)
        XCTAssertEqual(decoded.runs[0].events.map(\.stage), [.windowImageCallbackReceived])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let runs = try XCTUnwrap(json["runs"] as? [[String: Any]])
        let events = try XCTUnwrap(runs[0]["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 1)
        if let event = events.first { XCTAssertEqual(Set(event.keys), ["stage", "offsetMilliseconds"]) }
    }

    private func assertReservationIsHeld(_ budget: CaptureMemoryBudget,
                                         file: StaticString = #filePath, line: UInt = #line) {
        do {
            try budget.reserve(1)
            budget.release(1)
            XCTFail("An in-flight SDK request must retain the full reservation", file: file, line: line)
        } catch {
            guard let failure = error as? CaptureError, case .failed = failure else {
                return XCTFail("The real capture budget must reject over-admission: \(error)", file: file, line: line)
            }
        }
    }

    private func errorIdentityDiagnostic(_ label: String, expected: NSError,
                                         actual: any Error, received: NSError) -> String {
        // Synthetic fixture metadata only; never print userInfo or descriptions.
        "WINDOW_ERROR_IDENTITY path=\(label) expectedType=\(String(reflecting: type(of: expected))) " +
        "actualErrorType=\(String(reflecting: type(of: actual))) receivedType=\(String(reflecting: type(of: received))) " +
        "expectedDomain=\(expected.domain) receivedDomain=\(received.domain) " +
        "expectedCode=\(expected.code) receivedCode=\(received.code) " +
        "expectedObject=\(ObjectIdentifier(expected)) receivedObject=\(ObjectIdentifier(received)) " +
        "identical=\(received === expected)"
    }

    private func fixtureImage() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8,
            bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.25, green: 0.5, blue: 0.75, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        return try XCTUnwrap(context.makeImage())
    }
}

@MainActor
private final class WindowDeferredCallbackGate {
    var callback: (@Sendable (CGImage?, (any Error)?) -> Void)?
    var result: Result<CGImage, any Error>?
}

private final class WindowCallbackClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64
    private var reads = 0
    init(_ value: UInt64 = 0) { self.value = value }
    var readCount: Int { lock.withLock { reads } }
    func set(_ value: UInt64) { lock.withLock { self.value = value } }
    func read() -> UInt64 { lock.withLock { reads += 1; return value } }
}

private final class WindowCallbackObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var onMainThread: Bool?
    private var events: [CaptureLatencyTrace.Event] = []
    func record(onMainThread: Bool, events: [CaptureLatencyTrace.Event]) {
        lock.withLock { self.onMainThread = onMainThread; self.events = events }
    }
    func snapshot() -> (onMainThread: Bool?, events: [CaptureLatencyTrace.Event]) {
        lock.withLock { (onMainThread, events) }
    }
}
