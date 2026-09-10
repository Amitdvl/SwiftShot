import CoreGraphics

enum ScrollCapturePanelPlacement {
    static func frame(selected: CGRect, visible: CGRect, panelSize: CGSize) -> CGRect? {
        let safe = visible.insetBy(dx: 8, dy: 8)
        guard panelSize.width <= safe.width, panelSize.height <= safe.height else { return nil }
        let left = safe.minX
        let right = safe.maxX - panelSize.width
        let bottom = safe.minY
        let top = safe.maxY - panelSize.height
        let alignedX = min(max(selected.minX, left), right)
        let alignedY = min(max(selected.maxY - panelSize.height, bottom), top)
        let points = [
            CGPoint(x: alignedX, y: selected.minY - panelSize.height - 12),
            CGPoint(x: alignedX, y: selected.maxY + 12),
            CGPoint(x: selected.maxX + 12, y: alignedY),
            CGPoint(x: selected.minX - panelSize.width - 12, y: alignedY),
            CGPoint(x: left, y: bottom), CGPoint(x: right, y: bottom),
            CGPoint(x: left, y: top), CGPoint(x: right, y: top)
        ]
        let target = CGPoint(x: selected.midX, y: selected.midY)
        return points.map { CGRect(origin: $0, size: panelSize) }.first {
            safe.contains($0) && !$0.insetBy(dx: -16, dy: -16).contains(target)
        }
    }
}
