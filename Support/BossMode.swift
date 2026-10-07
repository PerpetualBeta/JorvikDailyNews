import AppKit
import Observation

/// Boss Mode: no pictures, no video, nothing but text, anywhere in the app.
///
/// Turned on and off by F6, or by View ▸ Boss Mode, an item that is only in
/// the menu while option is held. Nothing on screen says it is on: the paper
/// is simply a text paper, which is the point.
///
/// What it does, place by place:
///
/// - **Pictures** on the paper, the lead and in articles are not drawn and not
///   downloaded. `ImageCache.picturesEnabled` answers false, the same gate the
///   `showPictures` knob uses, so lead selection falls through to a text lead
///   exactly as it does with that knob off. `OptionalImage` collapses at once
///   rather than at its next load, because it observes this.
/// - **Inline SVG** in an article is not drawn, and an image's caption goes
///   with its image.
/// - **Video** links show a notice with Open in Browser instead of a player.
/// - **PDFs** show the document's text, page by page, from the same sandboxed
///   helper that draws the pages, instead of the page images.
/// - **The live page** loads with images, media and SVG documents blocked by a
///   content rule list, and is loaded again when Boss Mode changes.
///
/// The extracted-HTML WebKit renderer needs nothing: its rule list already
/// blocks every subresource.
@MainActor
@Observable
final class BossMode {
    static let shared = BossMode()

    /// The UserDefaults key, read directly by code that is not on the main
    /// actor (`ImageCache`).
    nonisolated static let key = "bossMode"

    /// Whether Boss Mode is on, read without the main actor.
    nonisolated static var isOnNow: Bool { UserDefaults.standard.bool(forKey: key) }

    var isOn: Bool = UserDefaults.standard.bool(forKey: BossMode.key) {
        didSet {
            guard oldValue != isOn else { return }
            UserDefaults.standard.set(isOn, forKey: Self.key)
            jdnLog("boss mode: \(isOn ? "on" : "off")")
            onChange()
        }
    }

    /// Told after every change, so the paper can be laid out again without
    /// the pictures it was measured with. Set by `AppStore`.
    @ObservationIgnored var onChange: () -> Void = { }

    func toggle() { isOn.toggle() }
}

/// The View menu item, hidden unless option is held, and its F6 shortcut.
///
/// **AppKit, because SwiftUI has no hidden menu items.** `Commands` can add a
/// button to the View menu but cannot hide it, and an `NSMenuItem` alternate
/// needs a visible item with the same key equivalent to stand in for. So the
/// item is added to the View menu SwiftUI builds and kept hidden, with
/// `allowsKeyEquivalentWhenHidden` so F6 still works. While a menu is open, a
/// timer in the menu's own run-loop mode shows it whenever option is down,
/// and hides it again when option is let go, the way the system's own
/// option-only items behave.
///
/// SwiftUI rebuilds its menus when commands change, which can drop an item it
/// did not make, so the item is put back whenever the menus are about to open.
@MainActor
final class BossModeMenu: NSObject {
    static let shared = BossModeMenu()

    private let item: NSMenuItem = {
        let f6 = String(UnicodeScalar(UInt16(NSF6FunctionKey))!)
        let item = NSMenuItem(title: "Boss Mode", action: #selector(toggle(_:)), keyEquivalent: f6)
        item.keyEquivalentModifierMask = []
        item.isHidden = true
        item.allowsKeyEquivalentWhenHidden = true
        return item
    }()

    private var optionTimer: Timer?
    private var installed = false

    func install() {
        guard !installed else { return }
        installed = true
        item.target = self
        let centre = NotificationCenter.default
        centre.addObserver(self, selector: #selector(menusWillOpen(_:)),
                           name: NSMenu.didBeginTrackingNotification, object: nil)
        centre.addObserver(self, selector: #selector(menusDidClose(_:)),
                           name: NSMenu.didEndTrackingNotification, object: nil)
        // And whenever any menu loses or gains an item, so that F6 keeps
        // working after a rebuild without waiting for a menu to be opened.
        for name in [NSMenu.didRemoveItemNotification, NSMenu.didAddItemNotification] {
            centre.addObserver(self, selector: #selector(menusChanged(_:)), name: name, object: nil)
        }
        attach()
        jdnLog("boss mode: \(item.menu == nil ? "NOT in" : "in") the \(item.menu?.title ?? "View") menu, "
               + "\(BossMode.shared.isOn ? "on" : "off")")
    }

    @objc private func menusChanged(_ note: Notification) {
        // Later, not inside the notification: the menu is mid-change.
        DispatchQueue.main.async { MainActor.assumeIsolated { self.attach() } }
    }

    /// The menu with Enter Full Screen in it, which is the View menu in any
    /// language; by its title only if that item is missing.
    private func viewMenu() -> NSMenu? {
        guard let main = NSApp.mainMenu else { return nil }
        let menus = main.items.compactMap(\.submenu)
        let fullScreen = #selector(NSWindow.toggleFullScreen(_:))
        return menus.first { $0.items.contains { $0.action == fullScreen } }
            ?? menus.first { $0.title == "View" }
    }

    private func attach() {
        guard let menu = viewMenu() else {
            jdnLog("boss mode: no View menu to add the item to; F6 is unavailable")
            return
        }
        guard item.menu !== menu else { return }
        item.menu?.removeItem(item)
        menu.addItem(item)
    }

    @objc private func toggle(_ sender: Any?) {
        BossMode.shared.toggle()
    }

    @objc private func menusWillOpen(_ note: Notification) {
        attach()
        item.state = BossMode.shared.isOn ? .on : .off
        reveal()
        guard optionTimer == nil else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated { BossModeMenu.shared.reveal() }
        }
        RunLoop.main.add(timer, forMode: .eventTracking)
        optionTimer = timer
    }

    @objc private func menusDidClose(_ note: Notification) {
        optionTimer?.invalidate()
        optionTimer = nil
        item.isHidden = true
    }

    private func reveal() {
        let hidden = !NSEvent.modifierFlags.contains(.option)
        if item.isHidden != hidden { item.isHidden = hidden }
    }
}
