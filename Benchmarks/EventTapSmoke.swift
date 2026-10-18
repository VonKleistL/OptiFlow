// Local full-path smoke test. Never linked into the shipping application.
import AppKit
import ApplicationServices

@main struct EventTapSmoke {
    @MainActor static func main() async throws {
        guard AXIsProcessTrusted() else { print("SKIP: no AX permission"); return }
        let apps = NSWorkspace.shared.runningApplications
        guard !apps.contains(where: { $0.localizedName == "OptiFlow" }) else { print("SKIP: OptiFlow already running"); return }
        let skipEvents = apps.contains(where: { $0.localizedName == "Easy Move+Resize" })
        guard let app = apps.first(where: { $0.localizedName == "ChatGPT" }),
              let path = CommandLine.arguments.dropFirst().first else { print("SKIP: no target/path"); return }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        var list: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &list) == .success,
              let windows = list as? [AXUIElement], let window = windows.first else { print("SKIP: no window"); return }
        var originalPosition: CFTypeRef?, originalSize: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &originalPosition) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &originalSize) == .success else { return }
        var origin = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(originalPosition as! AXValue, .cgPoint, &origin), AXValueGetValue(originalSize as! AXValue, .cgSize, &size) else { return }
        let cursor = CGEvent(source: nil)!.location
        defer {
            _ = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, originalSize!)
            _ = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, originalPosition!)
            CGWarpMouseCursorPosition(cursor)
        }
        let preferences = Preferences(defaults: UserDefaults(suiteName: "userPrefs")!)
        let options = preferences.options
        guard !options.modifiers.isEmpty, !options.disabledApps.contains(app.bundleIdentifier ?? "") else {
            print("SKIP: target disabled by existing preferences"); return
        }
        let anchor = CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
        if !skipEvents {
            guard AXWindowTarget.find(at: anchor, resizing: false, disabledApps: options.disabledApps, raise: false)?.processIdentifier == app.processIdentifier else {
                print("SKIP: target is obscured; don't move another app"); return
            }
        }
        let process = Process(); process.executableURL = URL(fileURLWithPath: path)
        let output = Pipe(); process.standardOutput = output; process.standardError = output
        try process.run()
        try await Task.sleep(nanoseconds: 700_000_000)
        guard process.isRunning else { print("FAIL: OptiFlow exited during startup"); return }
        func post(_ type: CGEventType, _ point: CGPoint, _ flags: CGEventFlags, _ button: CGMouseButton) {
            let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)!
            event.flags = flags; event.post(tap: .cghidEventTap)
        }
        if skipEvents { print("SKIP event injection: installed utility running; verify local launch/teardown only") }
        if !options.resizeOnly && !skipEvents {
            post(.leftMouseDown, anchor, options.modifiers, .left)
            for i in 1...20 {
                try await Task.sleep(nanoseconds: 5_000_000)
                post(.leftMouseDragged, CGPoint(x: anchor.x + Double(i), y: anchor.y + 10), options.modifiers, .left)
            }
            post(.leftMouseUp, CGPoint(x: anchor.x + 20, y: anchor.y + 10), [], .left)
            try await Task.sleep(nanoseconds: 300_000_000)
            var value: CFTypeRef?, actual = CGPoint.zero
            if AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &value) == .success,
               AXValueGetValue(value as! AXValue, .cgPoint, &actual) {
                let error = hypot(actual.x - origin.x - 20, actual.y - origin.y - 10)
                print(String(format: "EVENT TAP MOVE %@ final_error_points=%.3f", error < 1.1 ? "PASS" : "FAIL", error))
            }
        }
        if let running = NSRunningApplication(processIdentifier: process.processIdentifier) { _ = running.terminate() }
        try await Task.sleep(nanoseconds: 300_000_000)
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        print("OptiFlow launch/teardown exit=\(process.terminationStatus)")
        let logs = output.fileHandleForReading.readDataToEndOfFile()
        if let text = String(data: logs, encoding: .utf8), !text.isEmpty { print(text) }
    }
}
