import AppKit
import Foundation

// MARK: - Background Info

struct BackgroundInfo: Identifiable, Sendable {
    let name: String       // filename without extension (used as settings key)
    let displayName: String
    let url: URL

    var id: String { name }

    func loadThumbnail(height: CGFloat = 60) -> NSImage? {
        guard let image = NSImage(contentsOf: url) else { return nil }
        let aspect = image.size.width / image.size.height
        let thumbW = height * aspect
        let thumb = NSImage(size: NSSize(width: thumbW, height: height))
        thumb.lockFocus()
        image.draw(in: NSRect(x: 0, y: 0, width: thumbW, height: height))
        thumb.unlockFocus()
        return thumb
    }
}

// MARK: - Background Compositor

/// Composites a screenshot onto a background image with rounded corners, padding, and shadow.
enum BackgroundCompositor {

    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp"]

    /// Discover all background images bundled in Resources/Backgrounds.
    static func availableBackgrounds() -> [BackgroundInfo] {
        guard let bgFolderURL = Bundle.main.url(forResource: "Backgrounds", withExtension: nil) else {
            return []
        }
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: bgFolderURL, includingPropertiesForKeys: nil
        ) else { return [] }

        return contents
            .filter { imageExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { url in
                let name = url.deletingPathExtension().lastPathComponent
                let display = name
                    .replacingOccurrences(of: "-", with: " ")
                    .replacingOccurrences(of: "_", with: " ")
                    .localizedCapitalized
                return BackgroundInfo(name: name, displayName: display, url: url)
            }
    }

    /// Composite screenshot onto the named background.
    /// Returns PNG data of the final image, or nil on failure.
    static func composite(screenshot: NSImage, backgroundName: String) -> Data? {
        autoreleasepool {
            guard let bgImage = loadBackground(named: backgroundName) else { return nil }

            let padding: CGFloat = 7.5
            let cornerRadius: CGFloat = 12
            let outW: CGFloat = 1920
            let outH: CGFloat = 1080
            let outSize = CGSize(width: outW, height: outH)

            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(
                      data: nil,
                      width: Int(outW),
                      height: Int(outH),
                      bitsPerComponent: 8,
                      bytesPerRow: 0,
                      space: colorSpace,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return nil }

            // 1. Draw background — scale-to-fill and center-crop
            if let bgCG = bgImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                let bgW = CGFloat(bgCG.width)
                let bgH = CGFloat(bgCG.height)
                let bgAspect = bgW / bgH
                let outAspect = outW / outH

                let drawRect: CGRect
                if bgAspect > outAspect {
                    let scaledW = outH * bgAspect
                    drawRect = CGRect(x: (outW - scaledW) / 2, y: 0, width: scaledW, height: outH)
                } else {
                    let scaledH = outW / bgAspect
                    drawRect = CGRect(x: 0, y: (outH - scaledH) / 2, width: outW, height: scaledH)
                }
                ctx.draw(bgCG, in: drawRect)
            }

            // 2. Scale screenshot to fit within canvas minus padding, centered
            let ssSize = screenshot.size
            let maxW = outW - padding * 2
            let maxH = outH - padding * 2
            let scale = min(maxW / ssSize.width, maxH / ssSize.height)
            let scaledW = ssSize.width * scale
            let scaledH = ssSize.height * scale
            let ssRect = CGRect(
                x: (outW - scaledW) / 2,
                y: (outH - scaledH) / 2,
                width: scaledW,
                height: scaledH
            )
            if let ssCG = screenshot.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                ctx.saveGState()
                let clipPath = CGPath(roundedRect: ssRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
                ctx.addPath(clipPath)
                ctx.clip()
                ctx.draw(ssCG, in: ssRect)
                ctx.restoreGState()
            }

            // 4. Extract and encode as PNG
            guard let resultImage = ctx.makeImage() else { return nil }
            let rep = NSBitmapImageRep(cgImage: resultImage)
            rep.size = outSize
            return rep.representation(using: .png, properties: [:])
        }
    }

    private static func loadBackground(named name: String) -> NSImage? {
        let backgrounds = availableBackgrounds()
        guard let info = backgrounds.first(where: { $0.name == name }) else { return nil }
        return NSImage(contentsOf: info.url)
    }
}
