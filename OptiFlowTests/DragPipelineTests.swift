import XCTest

private final class TestWindow: WindowTarget, @unchecked Sendable {
    let initialFrame = CGRect(x: 100, y: 100, width: 600, height: 400)
    let processIdentifier: pid_t = 123
    let lock = NSLock()
    var frames: [CGRect] = []
    var prepared = 0
    var restored = 0
    var failure: Error?
    var onApply: (() -> Void)?
    var onFinish: (() -> Void)?
    func prepare() throws { lock.lock(); prepared += 1; lock.unlock() }
    func apply(_ frame: CGRect, geometry: DragGeometry) throws {
        onApply?()
        lock.lock(); defer { lock.unlock() }
        if let failure { throw failure }
        frames.append(frame)
    }
    func finish() throws { lock.lock(); restored += 1; lock.unlock(); onFinish?() }
    var snapshot: [CGRect] { lock.lock(); defer { lock.unlock() }; return frames }
}

final class DragPipelineTests: XCTestCase {
    func testMoveUsesAbsoluteCursorAndPreservesFractionalAndNegativeCoordinates() {
        let geometry = DragGeometry(frame: CGRect(x: -1000, y: -300, width: 600, height: 400), cursor: CGPoint(x: -900, y: -200), resizing: false)
        XCTAssertEqual(geometry.frame(at: CGPoint(x: -700.5, y: -150.25)), CGRect(x: -800.5, y: -250.25, width: 600, height: 400))
    }
    func testAllNineResizeRegionsAndOppositeEdgeAnchoring() {
        let frame = CGRect(x: 100, y: 100, width: 600, height: 600)
        for row in 0..<3 { for column in 0..<3 {
            let cursor = CGPoint(x: 200 + column * 200, y: 200 + row * 200)
            let geometry = DragGeometry(frame: frame, cursor: cursor, resizing: true)
            let result = geometry.frame(at: CGPoint(x: cursor.x + 25, y: cursor.y + 30))
            XCTAssertEqual(result.minX, column == 0 ? 125 : 100)
            XCTAssertEqual(result.width, column == 0 ? 575 : column == 2 ? 625 : 600)
            XCTAssertEqual(result.minY, row == 0 ? 130 : 100)
            XCTAssertEqual(result.height, row == 0 ? 570 : row == 2 ? 630 : 600)
        }}
    }
    func testResizeCannotCrossOppositeEdge() {
        let geometry = DragGeometry(frame: CGRect(x: 100, y: 100, width: 600, height: 400), cursor: CGPoint(x: 110, y: 110), resizing: true)
        let frame = geometry.frame(at: CGPoint(x: 2000, y: 2000))
        XCTAssertEqual(frame.maxX, 700); XCTAssertEqual(frame.maxY, 500)
        XCTAssertEqual(frame.size, CGSize(width: 1, height: 1))
    }
    func testLatestPositionCoalescesAndFinalFlushDoesNotWaitForRefresh() {
        let queue = DispatchQueue(label: "test.writer", qos: .userInteractive)
        let window = TestWindow()
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let done = expectation(description: "restored")
        window.onApply = { entered.signal(); _ = release.wait(timeout: .now() + 2) }
        window.onFinish = { done.fulfill() }
        let geometry = DragGeometry(frame: window.initialFrame, cursor: .zero, resizing: false)
        let writer = DragWriter(target: window, geometry: geometry, queue: queue, completion: { _ in })
        writer.update(cursor: CGPoint(x: 1, y: 0), refreshInterval: 1.0 / 60)
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        let start = ProcessInfo.processInfo.systemUptime
        for i in 2...1000 { writer.update(cursor: CGPoint(x: i, y: 0), refreshInterval: 1.0 / 120) }
        let submitTime = ProcessInfo.processInfo.systemUptime - start
        XCTAssertLessThan(submitTime, 0.05, "Input must not wait for blocked accessibility writes")
        writer.finish(cursor: CGPoint(x: 1001.5, y: 0))
        release.signal(); release.signal()
        wait(for: [done], timeout: 3)
        XCTAssertEqual(window.snapshot.count, 2)
        XCTAssertEqual(window.snapshot.last?.minX, 1101.5)
        XCTAssertEqual(window.prepared, 1); XCTAssertEqual(window.restored, 1)
    }
    func testFailureStillRestoresAndStopsWriting() {
        let window = TestWindow(); window.failure = AXFailure(.invalidUIElement)
        let done = expectation(description: "error cleanup")
        window.onFinish = { done.fulfill() }
        let writer = DragWriter(target: window, geometry: DragGeometry(frame: window.initialFrame, cursor: .zero, resizing: false), queue: DispatchQueue(label: "test.error", qos: .userInteractive), completion: { _ in })
        writer.update(cursor: CGPoint(x: 10, y: 0), refreshInterval: 1.0 / 60)
        wait(for: [done], timeout: 2)
        writer.finish(cursor: nil)
        XCTAssertEqual(window.restored, 1); XCTAssertTrue(window.snapshot.isEmpty)
    }
    func testBackToBackGesturesRestoreBeforePreparingNextTarget() {
        let queue = DispatchQueue(label: "test.serial", qos: .userInteractive)
        let first = TestWindow(), second = TestWindow()
        let done = expectation(description: "second complete")
        second.onFinish = { done.fulfill() }
        let a = DragWriter(target: first, geometry: DragGeometry(frame: first.initialFrame, cursor: .zero, resizing: false), queue: queue, completion: { _ in })
        a.finish(cursor: CGPoint(x: 10, y: 0))
        queue.async { XCTAssertEqual(first.restored, 1) }
        let b = DragWriter(target: second, geometry: DragGeometry(frame: second.initialFrame, cursor: .zero, resizing: false), queue: queue, completion: { _ in })
        b.finish(cursor: CGPoint(x: 20, y: 0))
        wait(for: [done], timeout: 2)
        XCTAssertEqual(first.snapshot.last?.minX, 110)
        XCTAssertEqual(second.snapshot.last?.minX, 120)
    }
    @MainActor func testModifierReleaseFlushesAndConsumesOrphanDragAndMouseUp() {
        let window = TestWindow(); let done = expectation(description: "modifier cleanup")
        window.onFinish = { done.fulfill() }
        let controller = DragController(findTarget: { _, _, _, _ in window })
        let flags: CGEventFlags = [.maskCommand, .maskControl]
        XCTAssertTrue(controller.handle(type: .leftMouseDown, point: CGPoint(x: 110, y: 110), flags: flags, button: 0))
        XCTAssertTrue(controller.handle(type: .leftMouseDragged, point: CGPoint(x: 125, y: 120), flags: flags, button: 0))
        XCTAssertFalse(controller.handle(type: .flagsChanged, point: .zero, flags: [], button: 0))
        XCTAssertFalse(controller.isDragging)
        XCTAssertTrue(controller.handle(type: .leftMouseDragged, point: CGPoint(x: 150, y: 150), flags: [], button: 0))
        XCTAssertTrue(controller.handle(type: .leftMouseUp, point: CGPoint(x: 160, y: 160), flags: [], button: 0))
        wait(for: [done], timeout: 2)
        XCTAssertEqual(window.snapshot.last?.origin, CGPoint(x: 115, y: 110))
    }
    @MainActor func testMouseUpFlushesFinalCursorEvenAfterModifiersWereReleased() {
        let window = TestWindow(); let done = expectation(description: "mouse up")
        window.onFinish = { done.fulfill() }
        let controller = DragController(findTarget: { _, _, _, _ in window })
        XCTAssertTrue(controller.handle(type: .leftMouseDown, point: CGPoint(x: 110, y: 110), flags: [.maskCommand, .maskControl], button: 0))
        XCTAssertTrue(controller.handle(type: .leftMouseUp, point: CGPoint(x: 120.5, y: 130), flags: [], button: 0))
        wait(for: [done], timeout: 2)
        XCTAssertEqual(window.snapshot.last?.origin, CGPoint(x: 110.5, y: 120))
    }
    @MainActor func testResizeOnlyMiddleButtonExtraModifiersAndDisabledTarget() {
        let window = TestWindow(); let controller = DragController(findTarget: { _, _, _, _ in window })
        controller.options.resizeOnly = true
        let flags: CGEventFlags = [.maskCommand, .maskControl]
        XCTAssertFalse(controller.handle(type: .leftMouseDown, point: .zero, flags: flags, button: 0))
        controller.options.middleClickResize = true
        XCTAssertFalse(controller.handle(type: .rightMouseDown, point: .zero, flags: flags, button: 1))
        XCTAssertFalse(controller.handle(type: .otherMouseDown, point: .zero, flags: flags, button: 4))
        XCTAssertFalse(controller.handle(type: .otherMouseDown, point: .zero, flags: [.maskCommand, .maskControl, .maskAlternate], button: 2))
        XCTAssertTrue(controller.handle(type: .otherMouseDown, point: .zero, flags: flags, button: 2))
        controller.cancel()
        let disabled = DragController(findTarget: { _, _, _, _ in nil })
        XCTAssertFalse(disabled.handle(type: .leftMouseDown, point: .zero, flags: flags, button: 0))
    }
}

final class EnhancedUIOverrideTests: XCTestCase {
    func testAbsentFalseOrReadOnlyStateIsNeverChanged() throws {
        for (original, writable) in [(nil, true), (false, true), (true, false)] as [(Bool?, Bool)] {
            var state = EnhancedUIOverride(); var writes: [Bool] = []
            try state.begin(original: original, writable: writable) { writes.append($0); return .success }
            try state.finish { writes.append($0); return .success }
            XCTAssertTrue(writes.isEmpty)
        }
    }
    func testTrueStateIsRestoredEvenIfDisableReturnsAnError() throws {
        var state = EnhancedUIOverride(); var writes: [Bool] = []
        XCTAssertThrowsError(try state.begin(original: true, writable: true) { writes.append($0); return .cannotComplete })
        try state.finish { writes.append($0); return .success }
        try state.finish { writes.append($0); return .success }
        XCTAssertEqual(writes, [false, true])
    }
    func testRestoreRetriesAreBoundedAndErrorsAreReported() throws {
        var state = EnhancedUIOverride()
        try state.begin(original: true, writable: true) { _ in .success }
        var attempts = 0
        XCTAssertThrowsError(try state.finish { _ in attempts += 1; return .cannotComplete })
        XCTAssertEqual(attempts, 3)
        try state.finish { _ in .invalidUIElement }
    }
}

final class GestureLifecycleTests: XCTestCase {
    @MainActor func testInterruptedGestureAndTargetTerminationRestoreBeforeShutdown() {
        let target = TestWindow(); let finished = expectation(description: "queue drained")
        let controller = DragController(findTarget: { _, _, _, _ in target })
        let flags: CGEventFlags = [.maskCommand, .maskControl]
        _ = controller.handle(type: .leftMouseDown, point: CGPoint(x: 110, y: 110), flags: flags, button: 0)
        _ = controller.handle(type: .leftMouseDragged, point: CGPoint(x: 140, y: 150), flags: flags, button: 0)
        controller.targetTerminated(999)
        XCTAssertTrue(controller.isDragging)
        controller.targetTerminated(123)
        XCTAssertFalse(controller.isDragging)
        controller.shutdown { finished.fulfill() }
        wait(for: [finished], timeout: 3)
        XCTAssertEqual(target.restored, 1)
        XCTAssertEqual(target.snapshot.last?.origin, CGPoint(x: 130, y: 140))
    }
    @MainActor func testOriginalMenuNibLoadsWithSwiftDelegateAndAllActionsExist() throws {
        _ = NSApplication.shared
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let app = try XCTUnwrap(Bundle(url: products.appendingPathComponent("OptiFlow.app")))
        let nib = try XCTUnwrap(NSNib(nibNamed: "MainMenu", bundle: app))
        var objects: NSArray?
        XCTAssertTrue(nib.instantiate(withOwner: NSApplication.shared, topLevelObjects: &objects))
        let delegate = try XCTUnwrap(objects?.first(where: { $0 is OptiFlowAppDelegate }) as? OptiFlowAppDelegate)
        for action in ["modifierToggle:", "resetToDefaults:", "toggleDisabled:", "toggleBringWindowToFront:", "toggleMiddleClickResize:", "toggleResizeOnly:", "disableLastApp:", "enableDisabledApp:"] {
            XCTAssertTrue(delegate.responds(to: NSSelectorFromString(action)), action)
        }
        NSApplication.shared.delegate = nil
        withExtendedLifetime(objects) {}
    }
}
