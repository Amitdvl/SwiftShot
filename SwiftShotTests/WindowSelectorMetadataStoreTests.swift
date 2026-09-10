import XCTest
import CoreGraphics
@testable import SwiftShot

@MainActor
final class WindowSelectorMetadataStoreTests: XCTestCase {
    private typealias Store = WindowSelectorMetadataStore<MetadataValue, MetadataValue>
    private let layout = [
        CaptureDisplayLayout(id: 10, frame: CGRect(x: 0, y: 0, width: 100, height: 100), scale: 2),
        CaptureDisplayLayout(id: 20, frame: CGRect(x: 200, y: 0, width: 100, height: 100), scale: 1)
    ]

    // Reusing a metadata reference must not replace the identity copied when the selector was produced.
    func testLookupPreservesCopiedIdentityAndOriginalMetadataReferences() throws {
        let store = Store(), owner = UUID()
        let window = MetadataValue(), display = MetadataValue()
        store.begin(owner: owner, layout: layout)
        try store.publish(owner: owner, windows: [entry(value: window)], displays: [displayEntry(value: display)])
        window.frame = CGRect(x: 70, y: 80, width: 12, height: 15)
        window.ownerPID = 99
        window.layer = 9
        let result = try XCTUnwrap(store.lookup(owner: owner, windowID: 7, displayID: 10, layout: Array(layout.reversed())))

        XCTAssertTrue(result.window.value === window)
        XCTAssertTrue(result.display.value === display)
        XCTAssertEqual(result.window.id, 7)
        XCTAssertEqual(result.window.frame, CGRect(x: 10, y: 10, width: 40, height: 30))
        XCTAssertEqual(result.window.ownerPID, 42)
        XCTAssertEqual(result.window.layer, 0)
        XCTAssertEqual(result.display.frame, CGRect(x: 0, y: 0, width: 100, height: 100))
    }

    func testUnknownWindowFallsBackOnlyUnderValidOwnerAndDisplay() throws {
        let store = Store(), owner = UUID()
        store.begin(owner: owner, layout: layout)
        try store.publish(owner: owner, windows: [entry()], displays: [displayEntry()])
        XCTAssertNil(try store.lookup(owner: owner, windowID: 99, displayID: 10, layout: layout))
        XCTAssertThrowsError(try store.lookup(owner: owner, windowID: 99, displayID: 99, layout: layout))
        XCTAssertThrowsError(try store.lookup(owner: UUID(), windowID: 99, displayID: 10, layout: layout))
    }

    func testKnownWindowCannotBeResolvedOnNonintersectingOrUnavailableDisplay() throws {
        let store = Store(), owner = UUID()
        store.begin(owner: owner, layout: layout)
        try store.publish(owner: owner, windows: [entry()], displays: [displayEntry(), displayEntry(id: 20, frame: layout[1].frame)])
        XCTAssertThrowsError(try store.lookup(owner: owner, windowID: 7, displayID: 20, layout: layout))
        XCTAssertThrowsError(try store.lookup(owner: owner, windowID: 7, displayID: 99, layout: layout))
        XCTAssertNotNil(try store.lookup(owner: owner, windowID: 7, displayID: 10, layout: layout))
    }

    func testSubTwoPointIntersectionIsRejectedButSpanningWindowRemainsEligible() throws {
        let store = Store(), owner = UUID()
        store.begin(owner: owner, layout: layout)
        try store.publish(owner: owner, windows: [entry(frame: CGRect(x: 99, y: 10, width: 140, height: 30))],
                          displays: [displayEntry(), displayEntry(id: 20, frame: layout[1].frame)])
        XCTAssertThrowsError(try store.lookup(owner: owner, windowID: 7, displayID: 10, layout: layout))
        let result = try XCTUnwrap(store.lookup(owner: owner, windowID: 7, displayID: 20, layout: layout))
        XCTAssertEqual(result.window.frame, CGRect(x: 99, y: 10, width: 140, height: 30))
    }

    func testReplacedOwnerRejectsOldPublicationWithoutChangingNewSnapshot() throws {
        let store = Store(), first = UUID(), second = UUID()
        let oldValue = MetadataValue(), currentValue = MetadataValue()
        store.begin(owner: first, layout: layout)
        store.begin(owner: second, layout: layout)
        try store.publish(owner: second, windows: [entry(value: currentValue)], displays: [displayEntry()])
        XCTAssertThrowsError(try store.publish(owner: first, windows: [entry(value: oldValue)], displays: [displayEntry()]))
        XCTAssertThrowsError(try store.lookup(owner: first, windowID: 7, displayID: 10, layout: layout))
        let result = try XCTUnwrap(store.lookup(owner: second, windowID: 7, displayID: 10, layout: layout))
        XCTAssertTrue(result.window.value === currentValue)
    }

    func testOldConditionalInvalidationCannotEvictNewOwner() throws {
        let store = Store(), first = UUID(), second = UUID()
        let currentValue = MetadataValue()
        store.begin(owner: first, layout: layout)
        store.begin(owner: second, layout: layout)
        try store.publish(owner: second, windows: [entry(value: currentValue)], displays: [displayEntry()])
        store.invalidate(owner: first)
        let result = try XCTUnwrap(store.lookup(owner: second, windowID: 7, displayID: 10, layout: layout))
        XCTAssertTrue(result.window.value === currentValue)
        store.invalidate(owner: second)
        XCTAssertThrowsError(try store.requireOwner(owner: second, layout: layout))
        XCTAssertThrowsError(try store.publish(owner: second, windows: [entry()], displays: [displayEntry()]))
    }

    func testLifecycleInvalidationRevokesPendingPublicationAndFallbackOwnership() throws {
        let store = Store(windowLimit: 1), owner = UUID()
        store.begin(owner: owner, layout: layout)
        store.invalidate()
        XCTAssertThrowsError(try store.publish(owner: owner, windows: [entry()], displays: [displayEntry()]))
        XCTAssertThrowsError(try store.requireOwner(owner: owner, layout: layout))

        let fallbackOwner = UUID()
        store.begin(owner: fallbackOwner, layout: layout)
        try store.publish(owner: fallbackOwner, windows: [entry(), entry(id: 8)], displays: [displayEntry()])
        XCTAssertNil(try store.lookup(owner: fallbackOwner, windowID: 7, displayID: 10, layout: layout))
        store.invalidate()
        XCTAssertThrowsError(try store.lookup(owner: fallbackOwner, windowID: 7, displayID: 10, layout: layout))
    }

    func testScaleMovedRemovedAndInvalidLayoutsFailClosed() throws {
        let store = Store(), owner = UUID()
        store.begin(owner: owner, layout: layout)
        try store.publish(owner: owner, windows: [entry()], displays: [displayEntry()])
        var changedScale = layout
        changedScale[0].scale = 1
        let moved = [CaptureDisplayLayout(id: 10, frame: CGRect(x: 1, y: 0, width: 100, height: 100), scale: 2), layout[1]]
        let invalid = [CaptureDisplayLayout(id: 10, frame: layout[0].frame, scale: .nan), layout[1]]
        for candidate in [changedScale, moved, [layout[0]], [layout[0], layout[0]], invalid, []] {
            XCTAssertThrowsError(try store.requireOwner(owner: owner, layout: candidate))
            XCTAssertThrowsError(try store.lookup(owner: owner, windowID: 7, displayID: 10, layout: candidate))
        }
        XCTAssertNoThrow(try store.requireOwner(owner: owner, layout: Array(layout.reversed())))
        let invalidOwner = UUID()
        store.begin(owner: invalidOwner, layout: invalid)
        XCTAssertThrowsError(try store.publish(owner: invalidOwner, windows: [entry()], displays: [displayEntry()]))
    }

    func testWindowOverCapacityRetainsOwnerButReleasesAllMetadataReferences() throws {
        let store = Store(windowLimit: 1), owner = UUID()
        weak var weakWindow: MetadataValue?
        weak var weakDisplay: MetadataValue?
        store.begin(owner: owner, layout: layout)
        do {
            let window = MetadataValue(), display = MetadataValue()
            weakWindow = window; weakDisplay = display
            try store.publish(owner: owner, windows: [entry(value: window), entry(id: 8, value: window)],
                              displays: [displayEntry(value: display)])
        }
        XCTAssertNil(weakWindow)
        XCTAssertNil(weakDisplay)
        XCTAssertNoThrow(try store.requireOwner(owner: owner, layout: layout))
        XCTAssertNil(try store.lookup(owner: owner, windowID: 7, displayID: 10, layout: layout))
        XCTAssertThrowsError(try store.lookup(owner: owner, windowID: 7, displayID: 99, layout: layout))
    }

    func testDisplayOverCapacityFallsBackWithoutRetainingWindowOrDisplayValues() throws {
        let store = Store(displayLimit: 1), owner = UUID()
        weak var weakWindow: MetadataValue?
        weak var weakDisplay: MetadataValue?
        store.begin(owner: owner, layout: layout)
        do {
            let window = MetadataValue(), display = MetadataValue()
            weakWindow = window; weakDisplay = display
            try store.publish(owner: owner, windows: [entry(value: window)],
                              displays: [displayEntry(value: display), displayEntry(id: 20, frame: layout[1].frame, value: display)])
        }
        XCTAssertNil(weakWindow)
        XCTAssertNil(weakDisplay)
        XCTAssertNoThrow(try store.requireOwner(owner: owner, layout: layout))
        XCTAssertNil(try store.lookup(owner: owner, windowID: 7, displayID: 20, layout: layout))
    }

    func testExactCapacityCanBeUsedButCallerCannotRaiseHardLimits() throws {
        let exact = Store(windowLimit: 2, displayLimit: 2), owner = UUID()
        exact.begin(owner: owner, layout: layout)
        try exact.publish(owner: owner, windows: [entry(), entry(id: 8)],
                          displays: [displayEntry(), displayEntry(id: 20, frame: layout[1].frame)])
        XCTAssertNotNil(try exact.lookup(owner: owner, windowID: 8, displayID: 10, layout: layout))

        let bounded = Store(windowLimit: 10_000, displayLimit: 10_000)
        bounded.begin(owner: owner, layout: layout)
        try bounded.publish(owner: owner, windows: (1...257).map { entry(id: UInt32($0)) }, displays: [displayEntry()])
        XCTAssertNil(try bounded.lookup(owner: owner, windowID: 7, displayID: 10, layout: layout))
        try bounded.publish(owner: owner, windows: [entry()],
                            displays: (10...26).map { displayEntry(id: UInt32($0)) })
        XCTAssertNil(try bounded.lookup(owner: owner, windowID: 7, displayID: 10, layout: layout))
    }

    func testBeginningNewSelectorAndInvalidatingReleasePriorMetadata() throws {
        let store = Store(), first = UUID(), second = UUID()
        weak var weakWindow: MetadataValue?
        store.begin(owner: first, layout: layout)
        do {
            let value = MetadataValue()
            weakWindow = value
            try store.publish(owner: first, windows: [entry(value: value)], displays: [displayEntry()])
        }
        XCTAssertNotNil(weakWindow)
        store.begin(owner: second, layout: layout)
        XCTAssertNil(weakWindow)
        do {
            let value = MetadataValue()
            weakWindow = value
            try store.publish(owner: second, windows: [entry(value: value)], displays: [displayEntry()])
        }
        XCTAssertNotNil(weakWindow)
        store.invalidate()
        XCTAssertNil(weakWindow)
    }

    func testDuplicateOrInvalidMetadataCannotReplaceValidSnapshot() throws {
        let store = Store(), owner = UUID(), original = MetadataValue()
        store.begin(owner: owner, layout: layout)
        try store.publish(owner: owner, windows: [entry(value: original)], displays: [displayEntry()])
        XCTAssertThrowsError(try store.publish(owner: owner, windows: [entry(), entry()], displays: [displayEntry()]))
        XCTAssertThrowsError(try store.publish(owner: owner, windows: [entry()], displays: [displayEntry(), displayEntry()]))
        XCTAssertThrowsError(try store.publish(owner: owner, windows: [entry(frame: .null)], displays: [displayEntry()]))
        let result = try XCTUnwrap(store.lookup(owner: owner, windowID: 7, displayID: 10, layout: layout))
        XCTAssertTrue(result.window.value === original)
    }

    private func entry(id: UInt32 = 7, frame: CGRect = CGRect(x: 10, y: 10, width: 40, height: 30),
                       value: MetadataValue = MetadataValue()) -> Store.WindowEntry {
        Store.WindowEntry(id: id, frame: frame, ownerPID: 42, layer: 0, value: value)
    }

    private func displayEntry(id: UInt32 = 10, frame: CGRect = CGRect(x: 0, y: 0, width: 100, height: 100),
                              value: MetadataValue = MetadataValue()) -> Store.DisplayEntry {
        Store.DisplayEntry(id: id, frame: frame, value: value)
    }
}

private final class MetadataValue {
    var frame = CGRect(x: 10, y: 10, width: 40, height: 30)
    var ownerPID: Int32 = 42
    var layer = 0
}
