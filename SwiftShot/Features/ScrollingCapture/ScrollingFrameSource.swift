import AppKit
import CoreImage
import CoreMedia
import CoreVideo
import ScreenCaptureKit

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
                              queueDepth: Int = 3) throws -> SCStreamConfiguration {
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
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 15)
        return configuration
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

        let pair = AsyncThrowingStream<ScrollingCaptureFrame, Error>.makeStream(
            bufferingPolicy: .bufferingNewest(3))
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
