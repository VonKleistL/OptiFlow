// Local diagnostic executable; not linked into OptiFlow.app.
// Build with the production Swift files except AppDelegate.swift and main.swift.
import AppKit
import ApplicationServices

private final class MeasuredWindow: WindowTarget, @unchecked Sendable {
    let initialFrame: CGRect
    let processIdentifier: pid_t
    let base: (any WindowTarget)?
    let delay: TimeInterval
    private let lock = NSLock()
    private var starts: [Double] = []
    private var durations: [Double] = []
    init(base: (any WindowTarget)?, frame: CGRect, delay: TimeInterval) {
        self.base = base; initialFrame = frame; self.delay = delay
        processIdentifier = base?.processIdentifier ?? 1
    }
    func prepare() throws { try base?.prepare() }
    func apply(_ frame: CGRect, geometry: DragGeometry) throws {
        let start = ProcessInfo.processInfo.systemUptime
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        try base?.apply(frame, geometry: geometry)
        lock.lock(); starts.append(start); durations.append(ProcessInfo.processInfo.systemUptime - start); lock.unlock()
    }
    func finish() throws { try base?.finish() }
    var metrics: (starts: [Double], durations: [Double]) {
        lock.lock(); defer { lock.unlock() }; return (starts, durations)
    }
}

@main struct DragBenchmark {
    static func percentile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted(); return sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] * 1000
    }
    @MainActor static func main() async throws {
        let real = CommandLine.arguments.contains("--real")
        let resizing = CommandLine.arguments.contains("--resize")
        let hz = CommandLine.arguments.contains("--120") ? 120.0 : 60.0
        let delay = CommandLine.arguments.contains("--slow") ? 0.012 : 0
        var window: AXUIElement?
        var application: AXUIElement?
        var originalPosition: CFTypeRef?, originalSize: CFTypeRef?
        var frame = CGRect(x: 100, y: 100, width: 800, height: 600)
        var pid: pid_t = 1
        if real {
            guard AXIsProcessTrusted(), let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == "ChatGPT" || $0.bundleIdentifier == "com.openai.chat" }) else {
                print("No trusted ChatGPT target"); return
            }
            pid = app.processIdentifier; application = AXUIElementCreateApplication(pid)
            var windows: CFTypeRef?
            guard AXUIElementCopyAttributeValue(application!, kAXWindowsAttribute as CFString, &windows) == .success,
                  let list = windows as? [AXUIElement], let first = list.first else { print("No ChatGPT window"); return }
            window = first
            guard AXUIElementCopyAttributeValue(first, kAXPositionAttribute as CFString, &originalPosition) == .success,
                  AXUIElementCopyAttributeValue(first, kAXSizeAttribute as CFString, &originalSize) == .success else { print("No window geometry"); return }
            var point = CGPoint.zero, size = CGSize.zero
            guard AXValueGetValue(originalPosition as! AXValue, .cgPoint, &point), AXValueGetValue(originalSize as! AXValue, .cgSize, &size) else { return }
            frame = CGRect(origin: point, size: size)
            print("Target name=\(app.localizedName ?? "?") bundle=\(app.bundleIdentifier ?? "?") resize=\(resizing)")
        }
        defer {
            if let window, let originalSize, resizing { _ = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, originalSize) }
            if let window, let originalPosition { _ = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, originalPosition) }
        }
        let base: (any WindowTarget)? = window.map { AXWindowTarget(window: $0, application: application!, pid: pid, frame: frame, raise: false) }
        let measured = MeasuredWindow(base: base, frame: frame, delay: delay)
        let controller = DragController(findTarget: { _, _, _, _ in measured })
        var failure: String?
        controller.onError = { failure = String(describing: $0) }
        controller.refreshInterval = { _ in 1 / hz }
        let anchor = CGPoint(x: resizing ? frame.maxX - 20 : frame.midX, y: resizing ? frame.maxY - 20 : frame.midY)
        let down: CGEventType = resizing ? .rightMouseDown : .leftMouseDown
        let drag: CGEventType = resizing ? .rightMouseDragged : .leftMouseDragged
        let up: CGEventType = resizing ? .rightMouseUp : .leftMouseUp
        let button: Int64 = resizing ? 1 : 0
        let flags: CGEventFlags = [.maskCommand, .maskControl]
        _ = controller.handle(type: down, point: anchor, flags: flags, button: button)
        var callbacks: [Double] = []
        let start = ProcessInfo.processInfo.systemUptime
        var lastOffset = 0.0, lastPoint = anchor
        while ProcessInfo.processInfo.systemUptime - start < 2 {
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            let offset = 20 * sin(elapsed * .pi * 2)
            let point = CGPoint(x: anchor.x + offset, y: anchor.y)
            let before = ProcessInfo.processInfo.systemUptime
            // Match the original harness's synthetic event construction overhead.
            let event = CGEvent(source: nil)!
            event.type = drag; event.location = point; event.flags = flags
            event.setDoubleValueField(.mouseEventDeltaX, value: offset - lastOffset)
            event.setDoubleValueField(.mouseEventDeltaY, value: 0)
            _ = controller.handle(type: event.type, point: event.location, flags: event.flags, button: button)
            callbacks.append(ProcessInfo.processInfo.systemUptime - before)
            lastOffset = offset; lastPoint = point
            // The producer models a ~1 kHz mouse. The AX writer has its own queue.
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        _ = controller.handle(type: up, point: lastPoint, flags: [], button: button)
        await withCheckedContinuation { continuation in controller.shutdown { continuation.resume() } }
        if let failure { print("AX ERROR: \(failure)") }
        if let window {
            var position: CFTypeRef?, size: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position) == .success,
               AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size) == .success {
                var actualPoint = CGPoint.zero, actualSize = CGSize.zero
                if AXValueGetValue(position as! AXValue, .cgPoint, &actualPoint), AXValueGetValue(size as! AXValue, .cgSize, &actualSize) {
                    let expected = DragGeometry(frame: frame, cursor: anchor, resizing: resizing).frame(at: lastPoint)
                    let positionError = hypot(actualPoint.x - expected.minX, actualPoint.y - expected.minY)
                    let sizeError = hypot(actualSize.width - expected.width, actualSize.height - expected.height)
                    print(String(format: "Final geometry error points: position=%.3f size=%.3f (before original geometry restoration)", positionError, sizeError))
                }
            }
        }
        let metrics = measured.metrics
        let intervals = zip(metrics.starts.dropFirst(), metrics.starts).map(-)
        let mean = metrics.durations.isEmpty ? 0 : metrics.durations.reduce(0,+) / Double(metrics.durations.count) * 1000
        print(String(format: "SWIFT %@ nominalHz=%.0f injectedAX_ms=%.0f callbacks=%d writes=%d input_ms_p50=%.3f p95=%.3f max=%.3f AX_mean_ms=%.3f write_interval_ms_p50=%.3f p95=%.3f", real ? "REAL" : "SYNTHETIC", hz, delay*1000, callbacks.count, metrics.starts.count, percentile(callbacks,0.5),percentile(callbacks,0.95),percentile(callbacks,1),mean,percentile(intervals,0.5),percentile(intervals,0.95)))
    }
}
