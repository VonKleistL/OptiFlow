// OptiFlow — VonKleistL
import AppKit
import ApplicationServices

private func optiFlowEventCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, context: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let context else { return .passUnretained(event) }
    let delegate = Unmanaged<OptiFlowAppDelegate>.fromOpaque(context).takeUnretainedValue()
    let interrupted = type == .tapDisabledByTimeout || type == .tapDisabledByUserInput
    let point = interrupted ? CGPoint.zero : event.location
    let flags = interrupted ? CGEventFlags() : event.flags
    let button = interrupted ? 0 : event.getIntegerValueField(.mouseEventButtonNumber)
    // The tap's run-loop source is installed exclusively on the main run loop.
    let handled = MainActor.assumeIsolated {
        delegate.handle(type: type, point: point, flags: flags, button: button)
    }
    return handled ? nil : .passUnretained(event)
}

@objc(OptiFlowAppDelegate) @MainActor final class OptiFlowAppDelegate: NSObject, NSApplicationDelegate {
    @IBOutlet private var statusMenu: NSMenu!
    @IBOutlet private var altMenu: NSMenuItem!
    @IBOutlet private var cmdMenu: NSMenuItem!
    @IBOutlet private var ctrlMenu: NSMenuItem!
    @IBOutlet private var shiftMenu: NSMenuItem!
    @IBOutlet private var fnMenu: NSMenuItem!
    @IBOutlet private var disabledMenu: NSMenuItem!
    @IBOutlet private var bringWindowFrontMenu: NSMenuItem!
    @IBOutlet private var middleClickResizeMenu: NSMenuItem!
    @IBOutlet private var resizeOnlyMenu: NSMenuItem!
    @IBOutlet private var disabledAppsMenu: NSMenuItem!
    @IBOutlet private var lastAppMenu: NSMenuItem!
    private var statusItem: NSStatusItem!
    // Keep the original suite and keys so existing local preferences survive.
    private let preferences = Preferences(defaults: UserDefaults(suiteName: "userPrefs")!)
    private let controller = DragController()
    private var eventTap: CFMachPort?
    private var source: CFRunLoopSource?
    private var sessionActive = true
    private var sleeping = false
    private var disabled = false
    private var lastApp: NSRunningApplication?
    private var displayIntervals: [(CGRect, TimeInterval)] = []

    override func awakeFromNib() {
        super.awakeFromNib()
        MainActor.assumeIsolated { setupStatusItem() }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(named: "MenuIcon")
        statusItem.button?.toolTip = "OptiFlow"
        statusItem.menu = statusMenu
        statusMenu.autoenablesItems = false
        statusMenu.items.first?.isEnabled = false
        syncMenus()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Public AX dictionary key; the SDK imports the C pointer as a mutable global.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else { NSApp.terminate(nil); return }
        syncOptions(); updateDisplays()
        controller.refreshInterval = { [weak self] point in
            self?.displayIntervals.first(where: { $0.0.contains(point) })?.1 ?? 1.0 / 60
        }
        controller.mostRecentApp = { [weak self] pid in
            guard let self, let app = NSRunningApplication(processIdentifier: pid) else { return }
            self.lastApp = app
            self.lastAppMenu.title = "Disable for \(app.localizedName ?? app.bundleIdentifier ?? "Application")"
            self.lastAppMenu.isEnabled = app.bundleIdentifier != nil
        }
        controller.onError = { [weak self] error in
            self?.statusItem.button?.toolTip = "OptiFlow: \(error)"
            NSLog("OptiFlow: %@", String(describing: error))
        }
        let types: [CGEventType] = [.leftMouseDown, .rightMouseDown, .otherMouseDown,
                                    .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                                    .leftMouseUp, .rightMouseUp, .otherMouseUp, .flagsChanged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
                                         options: .defaultTap, eventsOfInterest: mask,
                                         callback: optiFlowEventCallback,
                                         userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            NSLog("OptiFlow: could not create event tap")
            NSApp.terminate(nil); return
        }
        eventTap = tap; self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(becameActive), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(becameInactive), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(targetTerminated(_:)), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(goingToSleep), name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(wokeFromSleep), name: NSWorkspace.didWakeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updateDisplays), name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    fileprivate func handle(type: CGEventType, point: CGPoint, flags: CGEventFlags, button: Int64) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            controller.cancel()
            if sessionActive && !sleeping && !disabled, let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return false
        }
        guard sessionActive && !sleeping && !disabled else { return false }
        return controller.handle(type: type, point: point, flags: flags, button: button)
    }

    @objc private func becameActive() { sessionActive = true; enableTap() }
    @objc private func becameInactive() { sessionActive = false; controller.cancel(); enableTap() }
    @objc private func goingToSleep() { sleeping = true; controller.cancel(); enableTap() }
    @objc private func wokeFromSleep() { sleeping = false; enableTap() }
    @objc private func targetTerminated(_ notification: Notification) {
        if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            controller.targetTerminated(app.processIdentifier)
        }
    }
    @objc private func updateDisplays() {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        displayIntervals = NSScreen.screens.map { screen in
            let interval = screen.minimumRefreshInterval
            let fallback = 1.0 / Double(max(1, screen.maximumFramesPerSecond))
            return (CGRect(x: screen.frame.minX, y: top - screen.frame.maxY, width: screen.frame.width, height: screen.frame.height), interval.isFinite && interval > 0 ? interval : fallback)
        }
    }
    private func enableTap() { if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: sessionActive && !sleeping && !disabled) } }
    private func syncOptions() { controller.options = preferences.options }
    private func syncMenus() {
        for (name, item) in [("ALT", altMenu), ("CMD", cmdMenu), ("CTRL", ctrlMenu), ("SHIFT", shiftMenu), ("FN", fnMenu)] {
            item?.state = preferences.flagNames.contains(name) ? .on : .off
            item?.isEnabled = !disabled
        }
        disabledMenu.state = disabled ? .on : .off
        bringWindowFrontMenu.state = preferences.bringToFront ? .on : .off
        middleClickResizeMenu.state = preferences.middleClickResize ? .on : .off
        resizeOnlyMenu.state = preferences.resizeOnly ? .on : .off
        for item in [bringWindowFrontMenu, middleClickResizeMenu, resizeOnlyMenu] { item?.isEnabled = !disabled }
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for (bundle, name) in preferences.disabledApps.sorted(by: { $0.value < $1.value }) {
            let item = submenu.addItem(withTitle: name, action: #selector(enableDisabledApp(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = bundle
        }
        disabledAppsMenu.submenu = submenu; disabledAppsMenu.isEnabled = !preferences.disabledApps.isEmpty
    }
    @IBAction private func modifierToggle(_ sender: NSMenuItem) {
        controller.cancel(); preferences.setModifier(sender.title, enabled: sender.state != .on); syncOptions(); syncMenus()
    }
    @IBAction private func resetToDefaults(_ sender: Any?) {
        controller.cancel(); preferences.reset(); disabled = false; syncOptions(); syncMenus(); enableTap()
    }
    @IBAction private func toggleDisabled(_ sender: Any?) {
        controller.cancel(); disabled.toggle(); syncMenus(); enableTap()
    }
    @IBAction private func toggleBringWindowToFront(_ sender: Any?) {
        preferences.bringToFront.toggle(); syncOptions(); syncMenus()
    }
    @IBAction private func toggleMiddleClickResize(_ sender: Any?) {
        controller.cancel(); preferences.middleClickResize.toggle(); syncOptions(); syncMenus()
    }
    @IBAction private func toggleResizeOnly(_ sender: Any?) {
        controller.cancel(); preferences.resizeOnly.toggle(); syncOptions(); syncMenus()
    }
    @IBAction private func disableLastApp(_ sender: Any?) {
        guard let lastApp, let bundle = lastApp.bundleIdentifier else { return }
        preferences.setDisabled(bundle, name: lastApp.localizedName, disabled: true)
        lastAppMenu.isEnabled = false; syncOptions(); syncMenus()
    }
    @IBAction private func enableDisabledApp(_ sender: NSMenuItem) {
        guard let bundle = sender.representedObject as? String else { return }
        preferences.setDisabled(bundle, name: nil, disabled: false)
        if lastApp?.bundleIdentifier == bundle { lastAppMenu.isEnabled = true }
        syncOptions(); syncMenus()
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        controller.shutdown { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        if let eventTap { CFMachPortInvalidate(eventTap) }
        source = nil; eventTap = nil
    }
}
