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
/// **Adoption.** Add one line to your launch path. Either is fine:
///
///   - SwiftUI App struct: in `init()`
///   - AppDelegate: in `applicationDidFinishLaunching(_:)`
///
/// ```
/// JorvikDockVisibility.adopt()
/// ```
///
/// The adopter:
///  - reads the persisted hide state for this bundle from `UserDefaults`
///    and applies it as soon as `NSApp` is alive (so the Dock tile is
///    hidden from launch if the user previously asked for it),
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

    /// Call once at launch. Safe from a SwiftUI `App.init()` (where `NSApp`
    /// is still nil — the policy application is deferred to the
    /// `didFinishLaunching` notification) or from
    /// `applicationDidFinishLaunching(_:)` (where `NSApp` is alive — the
    /// policy is applied immediately). Idempotent and a no-op for apps
    /// with `LSUIElement=true`.
    public static func adopt() {
        guard let bid = Bundle.main.bundleIdentifier else { return }

        let isAccessoryByPlist = (Bundle.main.object(forInfoDictionaryKey: "LSUIElement") as? Bool) == true
        if isAccessoryByPlist { return }

        let key = defaultsPrefix + bid

        // Subscribing to the Tugboat notification touches no NSApp state,
        // so it's safe to do up-front regardless of launch phase.
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
            applyPolicyWhenReady(hidden: hidden)
        }

        // Apply persisted launch state. If we're already past
        // `didFinishLaunching`, this runs immediately on the main queue;
        // otherwise it waits for the notification.
        let isHidden = UserDefaults.standard.bool(forKey: key)
        applyPolicyWhenReady(hidden: isHidden)
    }

    /// Applies activation policy as soon as `NSApp` is alive. Calling
    /// `NSApp.setActivationPolicy(...)` from a SwiftUI `App.init()` crashes
    /// because `NSApp` is an implicitly-unwrapped optional that SwiftUI
    /// doesn't populate until later in the launch sequence.
    private static func applyPolicyWhenReady(hidden: Bool) {
        if NSApp != nil {
            applyPolicy(hidden: hidden)
            return
        }

        // didFinishLaunching fires exactly once per app lifetime, so the
        // observer is harmless after it fires — we don't bother
        // self-removing. (Self-removal needs a `var token` captured in its
        // own closure, which Swift 6's Sendable checker rejects.)
        NotificationCenter.default.addObserver(
            forName: NSApplication.didFinishLaunchingNotification,
            object: nil,
            queue: .main
        ) { _ in
            applyPolicy(hidden: hidden)
        }
    }

    private static func applyPolicy(hidden: Bool) {
        let policy: NSApplication.ActivationPolicy = hidden ? .accessory : .regular
        NSApp.setActivationPolicy(policy)
        // After a transition back to .regular, the Dock tile sometimes
        // needs a nudge to reappear; explicit activation is the
        // documented cure.
        if !hidden {
            if #available(macOS 14.0, *) {
                NSApp.activate()
            } else {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}
