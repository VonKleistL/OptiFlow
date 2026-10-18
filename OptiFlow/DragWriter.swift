// OptiFlow — VonKleistL
import Foundation

protocol WindowTarget: AnyObject, Sendable {
    var initialFrame: CGRect { get }
    var processIdentifier: pid_t { get }
    func prepare() throws
    func apply(_ frame: CGRect, geometry: DragGeometry) throws
    func finish() throws
}

/// Synchronous AX IPC stays on one serial queue. Only the constant-size mailbox is
/// shared with the event tap; NSLock protects it. No lock is held during AX calls.
/// The timer retains this session until finish/error cleanup removes its handler.
final class DragWriter: @unchecked Sendable {
    private struct Update { let frame: CGRect; let interval: TimeInterval }
    private let target: WindowTarget
    private let geometry: DragGeometry
    private let queue: DispatchQueue
    private let timer: DispatchSourceTimer
    private let completion: @Sendable (Error?) -> Void
    private let lock = NSLock()
    // Mailbox, protected by lock.
    private var latest: Update?
    private var ending = false
    private var ended = false
    private var armed = false
    private var nextAllowed: TimeInterval = 0
    // Accessed only on queue.
    private var lastFrame: CGRect
    private var latency: TimeInterval = 0
    private var cleanedUp = false

    init(target: WindowTarget, geometry: DragGeometry, queue: DispatchQueue,
         completion: @escaping @Sendable (Error?) -> Void) {
        self.target = target; self.geometry = geometry; self.queue = queue
        self.completion = completion; lastFrame = target.initialFrame
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { [self] in pump() }
        timer.schedule(deadline: .distantFuture)
        timer.activate()
        queue.async { [self] in
            do { try target.prepare() }
            catch { cleanup(error) }
        }
    }

    func update(cursor: CGPoint, refreshInterval: TimeInterval) {
        let update = Update(frame: geometry.frame(at: cursor), interval: refreshInterval)
        lock.lock(); defer { lock.unlock() }
        guard !ending && !ended else { return }
        latest = update
        if !armed {
            armed = true
            timer.schedule(deadline: .now() + max(0, nextAllowed - Self.now), leeway: .microseconds(100))
        }
    }

    /// Enqueue directly on the AX queue, bypassing pacing. This also orders
    /// restoration before the next gesture's prepare, including rapid clicks.
    func finish(cursor: CGPoint?) {
        lock.lock()
        guard !ending && !ended else { lock.unlock(); return }
        if let cursor { latest = Update(frame: geometry.frame(at: cursor), interval: 0) }
        ending = true
        timer.cancel()
        lock.unlock()
        queue.async { [self] in
            guard !cleanedUp else { return }
            lock.lock(); let final = latest; latest = nil; lock.unlock()
            do {
                if let final { try apply(final.frame) }
                cleanup(nil)
            } catch { cleanup(error) }
        }
    }

    private func pump() {
        lock.lock()
        guard !ending && !ended, let update = latest else { lock.unlock(); return }
        latest = nil
        lock.unlock()
        let start = Self.now
        do { try apply(update.frame) }
        catch { cleanup(error); return }
        let elapsed = Self.now - start
        // Start-to-start pacing: slow IPC consumes the frame budget instead of
        // adding an entire refresh interval after the blocking call returns.
        latency = latency == 0 ? elapsed : latency * 0.75 + elapsed * 0.25
        lock.lock(); defer { lock.unlock() }
        nextAllowed = start + max(update.interval, latency)
        guard !ending && !ended else { return }
        if latest != nil {
            timer.schedule(deadline: .now() + max(0, nextAllowed - Self.now), leeway: .microseconds(100))
        } else { armed = false }
    }

    private func apply(_ frame: CGRect) throws {
        guard frame != lastFrame else { return }
        try target.apply(frame, geometry: geometry)
        lastFrame = frame
    }

    private func cleanup(_ failure: Error?) {
        guard !cleanedUp else { return }
        cleanedUp = true
        lock.lock(); ended = true; latest = nil; timer.cancel(); lock.unlock()
        timer.setEventHandler {}
        var result = failure
        do { try target.finish() } catch { result = error }
        completion(result)
    }

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
}
