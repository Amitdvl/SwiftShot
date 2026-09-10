import Foundation

enum CaptureWorkflow: String, Codable, CaseIterable, Sendable {
    case region, window, fullscreen, ocr, quickCopy, scroll, combine
    var label: String {
        switch self {
        case .region: "Region Editing"
        case .window: "Window Editing"
        case .fullscreen: "Fullscreen Editing"
        case .ocr: "Text Recognition"
        case .quickCopy: "Quick Copy"
        case .scroll: "Scrolling Capture"
        case .combine: "Combined Captures"
        }
    }
}

struct CaptureStylePreset: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var style: CaptureStyle
}
