import AppKit
import XCTest
@testable import SwiftShot

@MainActor
final class FolderNavigationTests: XCTestCase {
    func testFolderNavigationCannotOpenPickerAfterShutdownBegins() async throws {
        let fixture = try FolderNavigationFixture()
        defer { fixture.cleanUp() }
        let picker = FolderNavigationPicker(result: fixture.root.appendingPathComponent("new-save-directory"))
        let app = fixture.state(picker: picker)
        let originalDirectory = app.appSettings.saveDirectory
        let quit = await app.prepareToQuit()
        XCTAssertTrue(quit)

        app.chooseSaveDirectory()

        XCTAssertEqual(picker.invocations, 0)
        XCTAssertEqual(app.appSettings.saveDirectory, originalDirectory)
        XCTAssertEqual(app.phase, .idle)
    }

    func testIdleFolderNavigationStillAcceptsChosenDirectory() async throws {
        let fixture = try FolderNavigationFixture()
        defer { fixture.cleanUp() }
        let chosen = fixture.root.appendingPathComponent("chosen-save-directory")
        let picker = FolderNavigationPicker(result: chosen)
        let app = fixture.state(picker: picker)
        app.chooseSaveDirectory()
        XCTAssertEqual(picker.invocations, 1)
        XCTAssertEqual(app.appSettings.saveDirectory, chosen.path)
        let quit = await app.prepareToQuit()
        XCTAssertTrue(quit)
    }
}

@MainActor
private struct FolderNavigationFixture {
    let root: URL
    let image: CGImage
    let defaults: UserDefaults
    let suiteName: String

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftShotFolderNavigation-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suiteName = "SwiftShotFolderNavigation.\(UUID())"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let context = try XCTUnwrap(CGContext(data: nil, width: 120, height: 80, bitsPerComponent: 8,
            bytesPerRow: 480, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
        image = try XCTUnwrap(context.makeImage())
    }

    func state(picker: FolderNavigationPicker,
               presenter: FolderNavigationCapturePresenter = FolderNavigationCapturePresenter()) -> AppState {
        AppState(defaults: defaults, recovery: RecoveryStore(root: root.appendingPathComponent("recovery")),
            backgrounds: BackgroundLibrary(rootURL: root.appendingPathComponent("backgrounds")), presentsUI: false,
            persistUnsavedCaptures: true,
            captureService: FolderNavigationCaptureService(image: image), overlay: presenter, directoryPicker: picker)
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private final class FolderNavigationPicker: CaptureDirectoryPicking {
    let result: URL?
    private(set) var invocations = 0
    init(result: URL?) { self.result = result }
    func chooseDirectory() -> URL? { invocations += 1; return result }
}

@MainActor
private struct FolderNavigationCaptureService: ScreenCaptureProviding {
    let image: CGImage
    func freeze(mode: CaptureMode) async throws -> [FrozenScreen] {
        [FrozenScreen(id: 7, frame: CGRect(x: 0, y: 0, width: 120, height: 80), image: image, windows: [])]
    }
}

@MainActor
private final class FolderNavigationCapturePresenter: CapturePresenting {
    private var actions = CaptureActions()
    private var screen: FrozenScreen?
    private(set) var activeDocument: CaptureDocument?
    private(set) var dismissals = 0
    func configure(actions: CaptureActions) { self.actions = actions }
    func selectRegion() throws {
        let screen = try XCTUnwrap(screen)
        actions.selectedRegion(screen, CGRect(x: 10, y: 12, width: 60, height: 48))
    }
    func present(screens: [FrozenScreen], mode: CaptureMode, style: CaptureStyle,
                 library: BackgroundLibrary, onDocument: @escaping (CaptureDocument) -> Void,
                 onCopy: @escaping (CaptureDocument) -> Void, onSave: @escaping (CaptureDocument) -> Void,
                 onOCR: @escaping (CaptureDocument) -> Void, onCancel: @escaping () -> Void,
                 onDiscard: @escaping (CaptureDocument) -> Void) { screen = screens.first }
    func reopen(document: CaptureDocument, library: BackgroundLibrary,
                onCopy: @escaping (CaptureDocument) -> Void, onSave: @escaping (CaptureDocument) -> Void,
                onCancel: @escaping () -> Void, onDocument: @escaping (CaptureDocument) -> Void,
                onDiscard: @escaping (CaptureDocument) -> Void) { activeDocument = document }
    func dismiss() { dismissals += 1; activeDocument = nil }
    func showStatus(_ message: String, isError: Bool) {}
}
