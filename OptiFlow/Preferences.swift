// OptiFlow — VonKleistL
import AppKit

@MainActor final class Preferences {
    private let defaults: UserDefaults
    private static let flagValues: [String: CGEventFlags] = ["CTRL": .maskControl, "SHIFT": .maskShift, "CAPS": .maskAlphaShift, "ALT": .maskAlternate, "CMD": .maskCommand, "FN": .maskSecondaryFn]
    init(defaults: UserDefaults) {
        self.defaults = defaults
        if defaults.string(forKey: "ModifierFlags") == nil { reset() }
        if defaults.dictionary(forKey: "DisabledApps") == nil { defaults.set([String: String](), forKey: "DisabledApps") }
    }
    var flagNames: Set<String> {
        Set((defaults.string(forKey: "ModifierFlags") ?? "CTRL,CMD").replacingOccurrences(of: " ", with: "").uppercased().split(separator: ",").map(String.init))
    }
    func setModifier(_ name: String, enabled: Bool) {
        var flags = flagNames
        if enabled { flags.insert(name.uppercased()) } else { flags.remove(name.uppercased()) }
        defaults.set(flags.sorted().joined(separator: ","), forKey: "ModifierFlags")
    }
    var bringToFront: Bool { get { defaults.bool(forKey: "BringToFront") } set { defaults.set(newValue, forKey: "BringToFront") } }
    var middleClickResize: Bool { get { defaults.bool(forKey: "MiddleClickResize") } set { defaults.set(newValue, forKey: "MiddleClickResize") } }
    var resizeOnly: Bool { get { defaults.bool(forKey: "ResizeOnly") } set { defaults.set(newValue, forKey: "ResizeOnly") } }
    var disabledApps: [String: String] { defaults.dictionary(forKey: "DisabledApps") as? [String: String] ?? [:] }
    func setDisabled(_ bundle: String, name: String?, disabled: Bool) {
        var apps = disabledApps
        if disabled { apps[bundle] = name ?? bundle } else { apps.removeValue(forKey: bundle) }
        defaults.set(apps, forKey: "DisabledApps")
    }
    var options: GestureOptions {
        var options = GestureOptions()
        options.modifiers = flagNames.reduce(into: CGEventFlags()) { result, name in result.formUnion(Self.flagValues[name] ?? []) }
        options.bringToFront = bringToFront; options.middleClickResize = middleClickResize
        options.resizeOnly = resizeOnly; options.disabledApps = Set(disabledApps.keys)
        return options
    }
    func reset() {
        defaults.set("CMD,CTRL", forKey: "ModifierFlags")
        defaults.set(false, forKey: "BringToFront"); defaults.set(false, forKey: "MiddleClickResize")
        defaults.set(false, forKey: "ResizeOnly"); defaults.set([String: String](), forKey: "DisabledApps")
    }
}
