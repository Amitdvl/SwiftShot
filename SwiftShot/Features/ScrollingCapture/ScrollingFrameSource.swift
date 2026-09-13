import AppKit
import CoreImage
import CoreMedia
import CoreVideo
import OSLog
import ScreenCaptureKit

/// Converts arbitrarily large wheel gestures into a short stream of bounded
/// pixel deltas while scrolling capture is active. The user's full gesture is
/// preserved; only its delivery rate changes so ScreenCaptureKit can observe
/// overlapping viewports instead of one uncapturable jump.
@MainActor
final class ScrollingInputPacer: NSObject {
    struct Buffer: Equatable, Sendable {
        private(set) var pendingPoints: Double = 0

        mutating func enqueue(_ points: Double) {
            guard points.isFinite else { return }
            pendingPoints += points
        }

        mutating func nextStep(maximumMagnitude: Double) -> Int32? {
            guard maximumMagnitude.isFinite, maximumMagnitude >= 1,
                  abs(pendingPoints) >= 1 else { return nil }
            let magnitude = min(abs(pendingPoints), maximumMagnitude)
            let step = Int32(magnitude.rounded(.down)) * (pendingPoints < 0 ? -1 : 1)
            pendingPoints -= Double(step)
            return step == 0 ? nil : step
        }

        mutating func reset() { pendingPoints = 0 }
    }

    private static let syntheticMarker: Int64 = 0x5357_5343_524F_4C4C
    private static let tickInterval: TimeInterval = 1.0 / 120.0
    private static let maximumPointsPerTick = 32.0

    private let logger = Logger(subsystem: "com.swiftshot.app", category: "ScrollingInput")
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var timer: Timer?
    private var buffer = Buffer()
    private var latestLocation = CGPoint.zero
    private var latestFlags = CGEventFlags()

    @discardableResult
    func start() -> Bool {
        stop()
        let mask = CGEventMask(1) << CGEventType.scrollWheel.rawValue
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let pacer = Unmanaged<ScrollingInputPacer>.fromOpaque(userInfo).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                MainActor.assumeIsolated { pacer.reenableTap() }
                return Unmanaged.passUnretained(event)
            }
            guard type == .scrollWheel else { return Unmanaged.passUnretained(event) }
            let consume = MainActor.assumeIsolated { pacer.intercept(event) }
            return consume ? nil : Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .defaultTap,
                                          eventsOfInterest: mask,
                                          callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            logger.error("Could not install scrolling input pacer")
            return false
        }
        eventTap = tap
        eventTapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let eventTapSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), eventTapSource, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)

        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.emitNextStep() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        return true
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        buffer.reset()
        if let eventTapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapSource, .commonModes) }
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
        eventTapSource = nil
        eventTap = nil
    }

    private func intercept(_ event: CGEvent) -> Bool {
        guard event.getIntegerValueField(.eventSourceUserData) != Self.syntheticMarker else {
            return false
        }
        let pointDelta = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
        let lineDelta = event.getDoubleValueField(.scrollWheelEventDeltaAxis1)
        let points = pointDelta != 0 ? pointDelta : lineDelta * 40
        guard points.isFinite, points != 0 else { return false }
        latestLocation = event.location
        latestFlags = event.flags
        buffer.enqueue(points)
        return true
    }

    private func emitNextStep() {
        guard let step = buffer.nextStep(maximumMagnitude: Self.maximumPointsPerTick),
              let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                  wheelCount: 1, wheel1: step, wheel2: 0, wheel3: 0) else { return }
        event.location = latestLocation
        event.flags = latestFlags
        event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
        event.post(tap: .cgSessionEventTap)
    }

    private func reenableTap() {
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
    }
}

@MainActor
protocol ScrollingFrameSource: AnyObject {
    func start(for region: CaptureRegionReference) async throws
        -> AsyncThrowingStream<ScrollingCaptureFrame, Error>
    func stop() async
}

enum ScrollingFrameSourceError: Error, Equatable, Sendable {
    case invalidQueueDepth(Int)
    case scaleMismatch(expected: CGFloat, actual: CGFloat)
    case invalidRegion
    case displayUnavailable
    case ownApplicationUnavailable
    case streamStopped(String)
}

@MainActor
final class ScreenCaptureKitScrollingFrameSource: ScrollingFrameSource {
    static let bufferedFrameCapacity = 8
    static let streamQueueDepth = 5

    private let memoryBudget: CaptureMemoryBudget
    private let displayCache = CaptureDisplayMetadataCache<SCDisplay, SCRunningApplication>(
        ownProcessID: ProcessInfo.processInfo.processIdentifier, processID: { $0.processID })
    private var stream: SCStream?
    private var output: ScrollingStreamOutput?
    private var reservedBytes = 0

    init(memoryBudget: CaptureMemoryBudget = CaptureMemoryBudget()) {
        self.memoryBudget = memoryBudget
    }

    static func configuration(for region: CaptureRegionReference, pointPixelScale: CGFloat,
                              queueDepth: Int = streamQueueDepth) throws -> SCStreamConfiguration {
        guard (1...8).contains(queueDepth) else {
            throw ScrollingFrameSourceError.invalidQueueDepth(queueDepth)
        }
        guard region.isValid, pointPixelScale.isFinite, pointPixelScale > 0 else {
            throw ScrollingFrameSourceError.invalidRegion
        }
        let expectedScaleX = region.nativeSize.width / region.rect.width
        let expectedScaleY = region.nativeSize.height / region.rect.height
        guard abs(expectedScaleX - expectedScaleY) < 0.0001,
              abs(expectedScaleX - pointPixelScale) < 0.0001 else {
            throw ScrollingFrameSourceError.scaleMismatch(expected: expectedScaleX, actual: pointPixelScale)
        }
        let size = try CaptureAcquisitionPolicy.dimensions(points: region.rect.size, scale: pointPixelScale)
        guard size.width == Int(region.nativeSize.width), size.height == Int(region.nativeSize.height) else {
            throw ScrollingFrameSourceError.invalidRegion
        }
        let configuration = ScreenCaptureService.configuration(size: size, window: false)
        configuration.sourceRect = region.rect
        configuration.queueDepth = queueDepth
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        return configuration
    }

    static func makeBufferedFrameStream(capacity: Int = bufferedFrameCapacity)
        -> (stream: AsyncThrowingStream<ScrollingCaptureFrame, Error>,
            continuation: AsyncThrowingStream<ScrollingCaptureFrame, Error>.Continuation) {
        precondition(capacity > 0)
        // Preserve the oldest pending frames: they are the bridge from the last
        // accepted viewport. Dropping those bridge frames makes every newer
        // frame impossible to place once the stitcher falls briefly behind.
        return AsyncThrowingStream<ScrollingCaptureFrame, Error>.makeStream(
            bufferingPolicy: .bufferingOldest(capacity))
    }

    func start(for region: CaptureRegionReference) async throws
        -> AsyncThrowingStream<ScrollingCaptureFrame, Error> {
        guard stream == nil, output == nil, reservedBytes == 0 else {
            throw ScrollingFrameSourceError.streamStopped("A scrolling stream is already active.")
        }
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw CaptureError.permissionDenied
        }
        try Task.checkCancellation()
        let layout = currentLayout()
        guard layout.contains(where: { $0.id == region.displayID && $0.frame == region.displayFrame }) else {
            throw ScrollingFrameSourceError.displayUnavailable
        }
        let metadata = try await displayCache.metadata(for: layout) { onScreenOnly in
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: onScreenOnly)
            return (content.displays, content.applications)
        }
        try Task.checkCancellation()
        guard let display = metadata.displays.first(where: { $0.displayID == region.displayID }) else {
            throw ScrollingFrameSourceError.displayUnavailable
        }
        guard metadata.excludedApplications.count == 1 else {
            throw ScrollingFrameSourceError.ownApplicationUnavailable
        }
        let filter = SCContentFilter(display: display,
            excludingApplications: metadata.excludedApplications, exceptingWindows: [])
        let scale = CGFloat(filter.pointPixelScale)
        let configuration = try Self.configuration(for: region, pointPixelScale: scale)
        let dimensions = try CaptureAcquisitionPolicy.dimensions(points: region.rect.size, scale: scale)
        try memoryBudget.reserve(dimensions.reservedBytes)
        reservedBytes = dimensions.reservedBytes

        let pair = Self.makeBufferedFrameStream()
        let output = ScrollingStreamOutput(continuation: pair.continuation,
            expectedWidth: dimensions.width, expectedHeight: dimensions.height,
            expectedScale: scale, expectedPointSize: region.rect.size)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        do {
            try stream.addStreamOutput(output, type: .screen,
                                       sampleHandlerQueue: output.sampleQueue)
            self.output = output
            self.stream = stream
            try await stream.startCapture()
            return pair.stream
        } catch {
            output.finish(throwing: error)
            self.output = nil
            self.stream = nil
            releaseReservation()
            displayCache.invalidate()
            throw error
        }
    }

    func stop() async {
        guard let stream else {
            output?.finish()
            output = nil
            releaseReservation()
            return
        }
        self.stream = nil
        let output = self.output
        self.output = nil
        do { try await stream.stopCapture() }
        catch { output?.finish(throwing: error) }
        if let output { try? stream.removeStreamOutput(output, type: .screen) }
        output?.finish()
        releaseReservation()
        displayCache.invalidate()
    }

    private func releaseReservation() {
        guard reservedBytes > 0 else { return }
        memoryBudget.release(reservedBytes)
        reservedBytes = 0
    }

    private func currentLayout() -> [CaptureDisplayLayout] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            return CaptureDisplayLayout(id: number.uint32Value, frame: screen.frame,
                                        scale: screen.backingScaleFactor)
        }
    }
}

private final class ScrollingStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate,
                                           @unchecked Sendable {
    let sampleQueue = DispatchQueue(label: "com.swiftshot.scrolling-capture.frames",
                                    qos: .userInitiated)
    private let continuation: AsyncThrowingStream<ScrollingCaptureFrame, Error>.Continuation
    private let expectedWidth: Int
    private let expectedHeight: Int
    private let expectedScale: CGFloat
    private let expectedPointSize: CGSize
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let lock = NSLock()
    private var finished = false

    init(continuation: AsyncThrowingStream<ScrollingCaptureFrame, Error>.Continuation,
         expectedWidth: Int, expectedHeight: Int, expectedScale: CGFloat,
         expectedPointSize: CGSize) {
        self.continuation = continuation
        self.expectedWidth = expectedWidth
        self.expectedHeight = expectedHeight
        self.expectedScale = expectedScale
        self.expectedPointSize = expectedPointSize
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let imageBuffer = sampleBuffer.imageBuffer else { return }
        guard let attachment = (CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let statusValue = attachment[.status] as? NSNumber,
              SCFrameStatus(rawValue: statusValue.intValue) == .complete else { return }
        let width = CVPixelBufferGetWidth(imageBuffer)
        let height = CVPixelBufferGetHeight(imageBuffer)
        guard width == expectedWidth, height == expectedHeight else {
            finish(throwing: ScrollingFrameSourceError.streamStopped(
                "The selected area changed resolution. Select it again."))
            return
        }
        if let value = attachment[.scaleFactor] as? NSNumber,
           abs(CGFloat(value.doubleValue) - expectedScale) > 0.0001 {
            finish(throwing: ScrollingFrameSourceError.scaleMismatch(
                expected: expectedScale, actual: CGFloat(value.doubleValue)))
            return
        }
        if let value = attachment[.contentRect] as? NSValue {
            let size = value.rectValue.size
            guard abs(size.width - expectedPointSize.width) <= 1,
                  abs(size.height - expectedPointSize.height) <= 1 else {
                finish(throwing: ScrollingFrameSourceError.streamStopped(
                    "The selected area changed while capturing."))
                return
            }
        }
        let ciImage = CIImage(cvPixelBuffer: imageBuffer)
        guard let image = context.createCGImage(ciImage,
            from: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else {
            finish(throwing: ScrollingFrameSourceError.streamStopped(
                "SwiftShot could not copy the latest frame."))
            return
        }
        lock.lock()
        let shouldYield = !finished
        lock.unlock()
        if shouldYield {
            continuation.yield(ScrollingCaptureFrame(image: image,
                                                     pointPixelScale: expectedScale))
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        finish(throwing: error)
    }

    func finish(throwing error: Error? = nil) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        lock.unlock()
        if let error { continuation.finish(throwing: error) }
        else { continuation.finish() }
    }
}

extension ScrollingFrameSourceError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidQueueDepth: return "SwiftShot could not start a bounded scrolling stream."
        case .scaleMismatch: return "The display scale changed. Select the scrolling area again."
        case .invalidRegion: return "The scrolling area is no longer valid. Select it again."
        case .displayUnavailable: return "The selected display changed or disconnected. Select the area again."
        case .ownApplicationUnavailable:
            return "SwiftShot could not safely exclude its own controls from this capture."
        case let .streamStopped(message): return message
        }
    }
}
