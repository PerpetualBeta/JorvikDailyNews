import AppKit

/// Cooperative Dock-visibility protocol used by Tugboat.
///
/// macOS 26 (Tahoe) gutted the LaunchServices SPI that previously let an
/// outside process toggle another app's `LSUIElement` flag at runtime. The
/// only mechanism that still works on Tahoe — for our own apps — is each
/// app calling `NSApp.setActivationPolicy(.accessory)` on itself. So
/// Tugboat becomes a remote control: it posts a `DistributedNotification`
/// targeted at a bundle ID, and the matching Jorvik app self-toggles via
/// this adopter.
///
/// **Adoption.** Add one line to your `applicationDidFinishLaunching`:
/// ```
/// JorvikDockVisibility.adopt()
/// ```
/// That's it. The adopter:
///  - reads the persisted hide state for this bundle from `UserDefaults`
///    and applies it immediately (so the Dock tile is hidden from launch
///    if the user previously asked for it),
///  - subscribes to Tugboat's notification and self-toggles on receipt,
///  - persists the new state so the choice survives relaunch.
///
/// **Safe to call from any Jorvik app**, including ones with
/// `LSUIElement=true` in their Info.plist — adoption no-ops for those,
/// because they are intrinsically dock-less.
public enum JorvikDockVisibility {

    /// Distributed notification posted by Tugboat. Payload:
    ///   - `bundleIdentifier`: target bundle ID (String)
    ///   - `hidden`: Bool — true to hide, false to restore
    public static let notificationName = Notification.Name("cc.jorviksoftware.Tugboat.SetDockVisibility")

    private static let payloadBundleIDKey = "bundleIdentifier"
    private static let payloadHiddenKey = "hidden"
    private static let defaultsPrefix = "JorvikDockVisibility.Hidden."

    /// Call once during `applicationDidFinishLaunching`. Idempotent — calling
    /// twice is harmless but pointless.
    public static func adopt() {
        guard let bid = Bundle.main.bundleIdentifier else { return }

        // Apps that are intrinsically dock-less (LSUIElement=true) have no
        // dock tile to hide. Adoption is a no-op so the helper can be added
        // unconditionally to every Jorvik app's bootstrap.
        let isAccessoryByPlist = (Bundle.main.object(forInfoDictionaryKey: "LSUIElement") as? Bool) == true
        if isAccessoryByPlist { return }

        // Apply persisted state immediately so the dock tile reflects the
        // last choice from the very first paint.
        let key = defaultsPrefix + bid
        let isHidden = UserDefaults.standard.bool(forKey: key)
        applyPolicy(hidden: isHidden)

        DistributedNotificationCenter.default().addObserver(
            forName: notificationName,
            object: nil,
            queue: .main
        ) { note in
            guard let info = note.userInfo,
                  let target = info[payloadBundleIDKey] as? String,
                  target == bid,
                  let hidden = info[payloadHiddenKey] as? Bool
            else { return }

            UserDefaults.standard.set(hidden, forKey: key)
            applyPolicy(hidden: hidden)
        }
    }

    private static func applyPolicy(hidden: Bool) {
        let policy: NSApplication.ActivationPolicy = hidden ? .accessory : .regular
        NSApp.setActivationPolicy(policy)
        // After a transition back to .regular, the Dock tile sometimes needs
        // a nudge to reappear; explicit activation is the documented cure.
        if !hidden {
            if #available(macOS 14.0, *) {
                NSApp.activate()
            } else {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}
