import Foundation

/// Boss Mode's gate on pictures, the part that stops downloads as well as
/// drawing. The views that hide pictures, video and PDF pages need a screen
/// and are checked by hand.
enum BossModeTests {
    static func run() {
        let defaults = UserDefaults.standard
        let savedBoss = defaults.object(forKey: BossMode.key)
        let savedPictures = defaults.object(forKey: ImageCache.picturesKey)
        defer {
            defaults.set(savedBoss, forKey: BossMode.key)
            defaults.set(savedPictures, forKey: ImageCache.picturesKey)
        }
        let url = URL(string: "https://example.com/picture.jpg")!

        T.suite("Boss Mode: pictures are off while it is on, and back when it is off") {
            defaults.removeObject(forKey: ImageCache.picturesKey)
            defaults.removeObject(forKey: BossMode.key)
            T.expect(ImageCache.picturesEnabled, "pictures are on by default")

            defaults.set(true, forKey: BossMode.key)
            T.expect(!ImageCache.picturesEnabled, "Boss Mode turns pictures off")
            T.expect(ImageCache.shared.isFailed(url),
                     "every picture reads as unusable, so the lead is picked from text")
            T.expect(ImageCache.shared.cachedImage(for: url, wideEnoughFor: nil) == nil,
                     "the width-checked cache read is gated too")

            defaults.set(false, forKey: BossMode.key)
            T.expect(ImageCache.picturesEnabled, "turning it off brings pictures back")
        }

        T.suite("Boss Mode: it does not overrule showPictures being off") {
            defaults.set(false, forKey: ImageCache.picturesKey)
            defaults.set(false, forKey: BossMode.key)
            T.expect(!ImageCache.picturesEnabled, "showPictures off still means off with Boss Mode off")
        }
    }
}
