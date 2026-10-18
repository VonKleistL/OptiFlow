// OptiFlow — VonKleistL
import AppKit
import ApplicationServices

struct AXFailure: Error, CustomStringConvertible {
    let code: AXError
    init(_ code: AXError) { self.code = code }
    var description: String { "Accessibility operation failed (\(code.rawValue))" }
}

struct EnhancedUIOverride {
    private var needsRestore = false

    mutating func begin(original: Bool?, writable: Bool, write: (Bool) -> AXError) throws {
        guard original == true, writable else { return }
        needsRestore = true
        let result = write(false)
        if result != .success { throw AXFailure(result) }
    }

    mutating func finish(write: (Bool) -> AXError) throws {
        guard needsRestore else { return }
        var result = AXError.success
        for _ in 0..<3 {
            result = write(true)
            if result == .success || result == .invalidUIElement { needsRestore = false; return }
            if result != .cannotComplete { break }
        }
        throw AXFailure(result)
    }
}

/// The AX references and restoration state belong exclusively to DragController's
/// serial AX queue after find returns. Only immutable frame/pid metadata is read
/// by the event tap. CF references are retained automatically by Swift ARC.
final class AXWindowTarget: WindowTarget, @unchecked Sendable {
    let initialFrame: CGRect
    let processIdentifier: pid_t
    private let window: AXUIElement
    private let application: AXUIElement
    private let raise: Bool
    private var enhancedOverride = EnhancedUIOverride()
    private static var enhancedUI: CFString { "AXEnhancedUserInterface" as CFString }

    init(window: AXUIElement, application: AXUIElement, pid: pid_t, frame: CGRect, raise: Bool) {
        self.window = window; self.application = application
        processIdentifier = pid; initialFrame = frame; self.raise = raise
    }

    /// One-time hit testing must finish before suppressing mouse-down, so clicks
    /// on disabled apps, the desktop and unsupported targets still pass through.
    /// No AX lookup or write runs in the drag/flags/up callback.
    @MainActor static func find(at point: CGPoint, resizing: Bool, disabledApps: Set<String>, raise: Bool) -> (any WindowTarget)? {
        let system = AXUIElementCreateSystemWide()
        // This sets the AX timeout for our process only, never system settings.
        AXUIElementSetMessagingTimeout(system, 0.05)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success,
              let hit else { return nil }
        AXUIElementSetMessagingTimeout(hit, 0.05)
        let window: AXUIElement
        if let role = copy(hit, kAXRoleAttribute) as? String, role == (kAXWindowRole as String) { window = hit }
        else {
            guard let value = copy(hit, kAXWindowAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            window = (value as! AXUIElement)
        }
        AXUIElementSetMessagingTimeout(window, 0.05)
        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success,
              let app = NSRunningApplication(processIdentifier: pid),
              app.bundleIdentifier.map({ !disabledApps.contains($0) }) ?? true else { return nil }
        var settable = DarwinBoolean(false)
        let attribute = resizing ? kAXSizeAttribute : kAXPositionAttribute
        guard AXUIElementIsAttributeSettable(window, attribute as CFString, &settable) == .success, settable.boolValue,
              let position = pointValue(window),
              let size = resizing ? sizeValue(window) : CGSize(width: 0, height: 0) else { return nil }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(window, 0.1)
        AXUIElementSetMessagingTimeout(application, 0.1)
        return AXWindowTarget(window: window, application: application, pid: pid,
                              frame: CGRect(origin: position, size: size), raise: raise)
    }

    func prepare() throws {
        if raise {
            DispatchQueue.main.async { [processIdentifier] in
                NSRunningApplication(processIdentifier: processIdentifier)?.activate(options: [])
            }
            // Some valid windows don't support raising; preserve movement.
            _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
        // Undocumented and optional: don't touch absent, false or read-only values.
        // Remember restoration BEFORE setting false: a timed-out IPC may succeed.
        if let value = Self.copy(application, Self.enhancedUI), CFGetTypeID(value) == CFBooleanGetTypeID(),
           CFBooleanGetValue((value as! CFBoolean)) {
            var settable = DarwinBoolean(false)
            if AXUIElementIsAttributeSettable(application, Self.enhancedUI, &settable) == .success, settable.boolValue {
                try enhancedOverride.begin(original: true, writable: true) {
                    AXUIElementSetAttributeValue(application, Self.enhancedUI, $0 ? kCFBooleanTrue : kCFBooleanFalse)
                }
            }
        }
    }

    func apply(_ frame: CGRect, geometry: DragGeometry) throws {
        var position = frame.origin
        if geometry.resizing {
            if geometry.left || geometry.right || geometry.top || geometry.bottom {
                var size = frame.size
                let value = AXValueCreate(.cgSize, &size)!
                try Self.check(AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value))
                // Apps enforce their own minimum sizes. Read back only when the
                // opposite edge must stay fixed, then anchor to the accepted size.
                if geometry.left || geometry.top {
                    guard let accepted = Self.sizeValue(window) else { throw AXFailure(.cannotComplete) }
                    if geometry.left { position.x = geometry.initialFrame.maxX - accepted.width }
                    if geometry.top { position.y = geometry.initialFrame.maxY - accepted.height }
                }
            } else { return } // Center third in both axes intentionally does nothing.
            if !geometry.left && !geometry.top { return }
        }
        let value = AXValueCreate(.cgPoint, &position)!
        try Self.check(AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value))
    }

    func finish() throws {
        // Bounded retries only during teardown. A dead application has no state
        // left to restore. Never leave an idle retry timer or background service.
        try enhancedOverride.finish {
            AXUIElementSetAttributeValue(application, Self.enhancedUI, $0 ? kCFBooleanTrue : kCFBooleanFalse)
        }
    }

    private static func check(_ result: AXError) throws { if result != .success { throw AXFailure(result) } }
    private static func copy(_ element: AXUIElement, _ attribute: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute, &value) == .success ? value : nil
    }
    private static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? { copy(element, attribute as CFString) }
    private static func pointValue(_ element: AXUIElement) -> CGPoint? {
        guard let value = copy(element, kAXPositionAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }
    private static func sizeValue(_ element: AXUIElement) -> CGSize? {
        guard let value = copy(element, kAXSizeAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
    }
}
