import AppKit
import Foundation

// MARK: - Sound Player

final class SoundPlayer: Sendable {
    static let shared = SoundPlayer()

    private init() {}

    /// Play the macOS screenshot capture sound
    func playScreenshotSound() {
        // The system screenshot sound lives at this path
        let soundPaths = [
            "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aiff",
            "/System/Library/Sounds/Grab.aiff"
        ]

        for path in soundPaths {
            if FileManager.default.fileExists(atPath: path) {
                NSSound(contentsOfFile: path, byReference: true)?.play()
                return
            }
        }
    }
}
