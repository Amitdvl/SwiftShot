import CoreGraphics

/// Last-region coordinates never fall back to a different display or scale.
struct CaptureRegionReference: Codable, Sendable {
    let displayID: UInt32
    let displayFrame: CGRect
    let rect: CGRect
    let nativeSize: CGSize
    let isPrivate: Bool

    init?(screen: FrozenScreen, crop: CGRect, isPrivate: Bool) {
        guard !screen.isLive, crop.width >= 2, crop.height >= 2,
              screen.scaleX > 0, screen.scaleY > 0 else { return nil }
        displayID = screen.id
        displayFrame = screen.frame
        rect = CGRect(x: crop.minX / screen.scaleX, y: crop.minY / screen.scaleY,
            width: crop.width / screen.scaleX, height: crop.height / screen.scaleY)
        nativeSize = crop.size
        self.isPrivate = isPrivate
    }

    func matches(frame: CGRect, image: CGImage) -> Bool {
        isValid && displayFrame == frame && image.width == Int(nativeSize.width) && image.height == Int(nativeSize.height)
    }

    /// Recapturing publicly stored geometry privately upgrades its in-memory
    /// lineage. A later preference change must never downgrade that lineage.
    func applyingPrivacy(_ privateCapture: Bool) -> CaptureRegionReference {
        CaptureRegionReference(displayID: displayID, displayFrame: displayFrame,
            rect: rect, nativeSize: nativeSize, isPrivate: isPrivate || privateCapture)
    }

    /// The selection editor owns a full-display original; recapture owns only
    /// this region's native pixels. Always pass the immutable source reference
    /// for the edited image, not the result of its previous crop adjustment.
    func applyingCrop(_ crop: CGRect, relativeToCapturedRegion: Bool = false) -> CaptureRegionReference? {
        guard isValid, [crop.minX, crop.minY, crop.width, crop.height].allSatisfy(\.isFinite),
              crop.width >= 2, crop.height >= 2 else { return nil }
        let sx = nativeSize.width / rect.width, sy = nativeSize.height / rect.height
        let sourceSize = relativeToCapturedRegion ? nativeSize :
            CGSize(width: displayFrame.width * sx, height: displayFrame.height * sy)
        guard sourceSize.width.isFinite, sourceSize.height.isFinite,
              CGRect(origin: .zero, size: sourceSize).contains(crop) else { return nil }
        let origin = relativeToCapturedRegion ? rect.origin : .zero
        let next = CaptureRegionReference(displayID: displayID, displayFrame: displayFrame,
            rect: CGRect(x: origin.x + crop.minX / sx, y: origin.y + crop.minY / sy,
                width: crop.width / sx, height: crop.height / sy),
            nativeSize: crop.size, isPrivate: isPrivate)
        return next.isValid ? next : nil
    }

    private init(displayID: UInt32, displayFrame: CGRect, rect: CGRect, nativeSize: CGSize, isPrivate: Bool) {
        self.displayID = displayID; self.displayFrame = displayFrame; self.rect = rect
        self.nativeSize = nativeSize; self.isPrivate = isPrivate
    }

    var isValid: Bool {
        displayID != 0 && [displayFrame.minX, displayFrame.minY, displayFrame.width, displayFrame.height,
            rect.minX, rect.minY, rect.width, rect.height, nativeSize.width, nativeSize.height].allSatisfy(\.isFinite) &&
            displayFrame.width > 0 && displayFrame.height > 0 && rect.width >= 1 && rect.height >= 1 &&
            CGRect(origin: .zero, size: displayFrame.size).contains(rect) &&
            nativeSize.width >= 2 && nativeSize.height >= 2 && nativeSize.width <= 32_768 && nativeSize.height <= 32_768 &&
            nativeSize.width * nativeSize.height <= 64_000_000 && nativeSize.width.rounded() == nativeSize.width && nativeSize.height.rounded() == nativeSize.height
    }
}
