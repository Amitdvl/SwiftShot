import SwiftUI
import Observation

@MainActor @Observable
final class ScrollCapturePanelModel {
    var status = "Capturing the first frame…"
    var frameCount = 0
    var width = 0
    var height = 0
    var busy = true
    var automatic = false
    var acquisitionDisabled = false
    var automaticDisabled = false
    var warnings: [String] = []
}

struct ScrollCapturePanelView: View {
    let model: ScrollCapturePanelModel
    let addFrame: () -> Void
    let startAutomatic: () -> Void
    let stop: () -> Void
    let finish: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Scrolling Capture", systemImage: "rectangle.portrait.and.arrow.down")
                    .font(.headline)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
            }
            Text(model.frameCount == 0 ? "First frame" : "\(model.frameCount) frames · \(model.width) × \(model.height) pixels")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Text(model.status).font(.callout).fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Capture status: \(model.status)")
            if !model.warnings.isEmpty {
                Label("Review required — the result may be incomplete", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .help(model.warnings.joined(separator: "\n"))
            }
            HStack {
                Button("Add Frame", action: addFrame)
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(model.busy || model.acquisitionDisabled)
                    .help("Use this fallback for targets that cannot be scrolled automatically.")
                if model.automatic {
                    Button("Stop Auto", action: stop).keyboardShortcut(".", modifiers: .command)
                } else {
                    Button("Auto", action: startAutomatic)
                        .disabled(model.busy || model.frameCount == 0 || model.acquisitionDisabled || model.automaticDisabled)
                        .help("Start automatic scrolling. Requires Accessibility permission; keep the target unchanged.")
                }
                Spacer()
                Button("Finish", action: finish)
                    .keyboardShortcut("f", modifiers: .command)
                    .disabled(model.busy || model.frameCount == 0)
            }
            HStack {
                Text("Auto finishes after a verified end · local processing only")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.escape, modifiers: [])
            }
        }
        .buttonStyle(CaptureButtonStyle())
        .padding(20)
        .frame(width: 352)

    }
}
