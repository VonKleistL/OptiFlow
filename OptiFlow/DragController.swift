// OptiFlow — VonKleistL
import AppKit

struct GestureOptions {
    var modifiers: CGEventFlags = [.maskCommand, .maskControl]
    var middleClickResize = false
    var resizeOnly = false
    var bringToFront = false
    var disabledApps: Set<String> = []
}

@MainActor final class DragController {
    typealias TargetFinder = @MainActor (CGPoint, Bool, Set<String>, Bool) -> (any WindowTarget)?
    private struct Gesture {
        let writer: DragWriter
        let pid: pid_t
        var cursor: CGPoint
        let identifier: UUID
    }
    private let queue = DispatchQueue(label: "org.VonKleistL.OptiFlow.accessibility", qos: .userInteractive)
    private let findTarget: TargetFinder
    private var gesture: Gesture?
    // Keep consuming a captured button through mouse-up after modifier release,
    // so the target never receives an orphan drag/up without its mouse-down.
    private var capturedButton: Int64?
    var options = GestureOptions()
    var refreshInterval: (CGPoint) -> TimeInterval = { _ in 1.0 / 60 }
    var mostRecentApp: ((pid_t) -> Void)?
    var onError: ((Error) -> Void)?
    var isDragging: Bool { gesture != nil }

    init(findTarget: @escaping TargetFinder = AXWindowTarget.find) { self.findTarget = findTarget }

    func handle(type: CGEventType, point: CGPoint, flags: CGEventFlags, button: Int64) -> Bool {
        let up = type == .leftMouseUp || type == .rightMouseUp || type == .otherMouseUp
        let down = type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown
        let dragged = type == .leftMouseDragged || type == .rightMouseDragged || type == .otherMouseDragged
        // Recover if the system swallowed an earlier mouse-up during a modal
        // transition. A new down for that button starts a fresh gesture.
        if down, capturedButton == button { cancel() }
        if up, capturedButton == button {
            gesture?.writer.finish(cursor: point)
            gesture = nil; capturedButton = nil
            return true
        }
        let relevant: CGEventFlags = [.maskShift, .maskCommand, .maskAlphaShift, .maskAlternate, .maskControl, .maskSecondaryFn]
        let matches = !options.modifiers.isEmpty && flags.intersection(relevant) == options.modifiers
        if !matches, let current = gesture {
            current.writer.finish(cursor: current.cursor); gesture = nil
        }
        if dragged, capturedButton == button {
            if var current = gesture {
                current.cursor = point; gesture = current
                current.writer.update(cursor: point, refreshInterval: refreshInterval(point))
            }
            return true
        }
        guard matches else { return false }
        let resize = options.middleClickResize ? type == .otherMouseDown && button == 2 : type == .rightMouseDown
        let move = type == .leftMouseDown && !options.resizeOnly
        guard (resize || move), capturedButton == nil,
              let target = findTarget(point, resize, options.disabledApps, options.bringToFront) else { return false }
        let identifier = UUID()
        let writer = DragWriter(target: target, geometry: DragGeometry(frame: target.initialFrame, cursor: point, resizing: resize), queue: queue) { [weak self] error in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.gesture?.identifier == identifier { self.gesture = nil }
                if let error { self.onError?(error) }
            }
        }
        gesture = Gesture(writer: writer, pid: target.processIdentifier, cursor: point, identifier: identifier)
        capturedButton = button
        mostRecentApp?(target.processIdentifier)
        return true
    }

    func cancel() {
        if let current = gesture { current.writer.finish(cursor: current.cursor) }
        gesture = nil; capturedButton = nil
    }

    func targetTerminated(_ pid: pid_t) { if gesture?.pid == pid { cancel() } }

    func shutdown(completion: @escaping @MainActor @Sendable () -> Void) {
        cancel(); capturedButton = nil
        queue.async { DispatchQueue.main.async(execute: completion) }
    }
}
