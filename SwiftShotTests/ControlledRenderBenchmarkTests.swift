import XCTest
import CoreGraphics
import CoreText
import ImageIO
@testable import SwiftShot

/// Controlled renderer microbenchmarks. These do not launch selectors, use the
/// pasteboard, paste into another application, save files, or claim E2E timings.
/// This exact file also compiles against the preserved baseline plus the neutral
/// WorkflowPerformance resource-sampling file.
final class ControlledRenderBenchmarkTests: XCTestCase {
    private struct Sample: Encodable {
        let schemaVersion = 1
        let kind = "renderer-microbenchmark"
        let scenario: String
        let lifecycle: String
        let sampleIndex: Int
        let renderMilliseconds: Double
        let cpuMilliseconds: Double?
        let residentStartBytes: UInt64?
        let residentEndBytes: UInt64?
        let peakResidentBytes: UInt64?
        let imageWidth: Int
        let imageHeight: Int
        let pngBytes: Int
    }

    func testNative4KFirstUseRenderer() async throws {
        try await benchmark(reuseRenderer: false)
    }

    func testNative4KRepeatedRenderer() async throws {
        try await benchmark(reuseRenderer: true)
    }

    private func benchmark(reuseRenderer: Bool) async throws {
        let image = try fixture()
        let count: Int
        if let configured = ProcessInfo.processInfo.environment["SWIFTSHOT_BENCHMARK_SAMPLES"] {
            guard let parsed = Int(configured), (1...1000).contains(parsed) else {
                XCTFail("SWIFTSHOT_BENCHMARK_SAMPLES must be an integer in 1...1000")
                return
            }
            count = parsed
        } else { count = 30 }
        let ordinary = [
            CaptureAnnotation(kind: .arrow, start: CGPoint(x: 3000, y: 1750), end: CGPoint(x: 2250, y: 900), lineWidth: 8),
            CaptureAnnotation(kind: .rectangle, start: CGPoint(x: 1400, y: 600), end: CGPoint(x: 2700, y: 1300), lineWidth: 6),
            CaptureAnnotation(kind: .text, start: CGPoint(x: 400, y: 400), end: .zero, text: "Review the crop", fontSize: 48)
        ]
        let redacted = ordinary + [CaptureAnnotation(kind: .redact, start: CGPoint(x: 800, y: 900), end: CGPoint(x: 1600, y: 1200))]
        for (scenario, annotations) in [("raw-4k", [CaptureAnnotation]()), ("ordinary-edited-4k", ordinary), ("redacted-4k", redacted)] {
            // Same immutable request reused across samples on BOTH builds. That
            // measures repeated Copy→Save work without changing semantics.
            let request = RenderRequest(image: image,
                edits: CaptureEdits(crop: CGRect(x: 0, y: 0, width: 3840, height: 2160), annotations: annotations), backgroundURL: nil)
            let sharedRenderer = ImageRenderer()
            for index in 0..<count {
                let renderer = reuseRenderer ? sharedRenderer : ImageRenderer()
                let before = WorkflowResourceSample.capture()
                let started = DispatchTime.now().uptimeNanoseconds
                let result = try await renderer.render(request)
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
                let after = WorkflowResourceSample.capture()
                XCTAssertEqual(result.image.width, 3840)
                XCTAssertEqual(result.image.height, 2160)
                XCTAssertGreaterThan(result.png.count, 0)
                let cpu: Double?
                if let start = before.cpuNanoseconds, let end = after.cpuNanoseconds, end >= start {
                    cpu = Double(end - start) / 1_000_000
                } else { cpu = nil }
                let sample = Sample(scenario: scenario, lifecycle: reuseRenderer ? "renderer-reuse" : "renderer-first-use",
                    sampleIndex: index, renderMilliseconds: elapsed, cpuMilliseconds: cpu,
                    residentStartBytes: before.residentBytes, residentEndBytes: after.residentBytes,
                    peakResidentBytes: after.peakResidentBytes, imageWidth: result.image.width,
                    imageHeight: result.image.height, pngBytes: result.png.count)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let data = try encoder.encode(sample)
                print("SWIFTSHOT_BENCHMARK \(String(decoding: data, as: UTF8.self))")
            }
        }
    }

    /// Deterministic, non-private, text-heavy synthetic desktop card. Creation
    /// happens outside measured intervals; both builds receive identical pixels.
    private func fixture() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 3840, height: 2160, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0.95, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 3840, height: 2160))
        let font = CTFontCreateWithName("Helvetica" as CFString, 26, nil)
        for row in 0..<48 {
            context.setFillColor(CGColor(red: CGFloat((row * 17) % 255) / 255,
                green: CGFloat((row * 29) % 255) / 255, blue: CGFloat((row * 43) % 255) / 255, alpha: 1))
            context.fill(CGRect(x: 100, y: 100 + row * 40, width: 120 + (row * 71) % 500, height: 28))
            let text = "SwiftShot controlled benchmark • row \(row) • native pixels, predictable export, local-only workflow"
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.15, alpha: 1)
            ]))
            context.textPosition = CGPoint(x: 800, y: 105 + row * 40)
            CTLineDraw(line, context)
        }
        return try XCTUnwrap(context.makeImage())
    }
}
