import Foundation

/// Moves the app's data into its sandbox container, once.
///
/// Turning on `com.apple.security.app-sandbox` relocates
/// `applicationSupportDirectory` from
///
///     ~/Library/Application Support/JorvikDailyNews
///
/// to
///
///     ~/Library/Containers/cc.jorviksoftware.JorvikDailyNews/Data/
///         Library/Application Support/JorvikDailyNews
///
/// and makes the first one unreadable. Measured with a signed sandboxed probe
/// before this existed: the container path did not exist and `feeds.json` at
/// the old path returned nothing at all. On the developer's own machine that
/// was **247 subscriptions, 3,037 read marks and 954,798 bytes of classifier
/// training**, and it would have gone silently on first launch, for every
/// user, with no way back.
///
/// So the entitlements carry a read-only exception for the old path and this
/// copies across it. The exception should be deleted a release after everyone
/// has upgraded; nothing else in the app reads outside the container.
enum StoreMigration {

    /// Files worth carrying. Named rather than copied wholesale so a stray
    /// file in the old directory cannot ride along, and so the log can say
    /// what actually moved.
    ///
    /// `editions/` is deliberately absent. The paper is day-scoped and is
    /// rebuilt from the feeds within a minute of launch, so copying up to
    /// seven days of editions would move megabytes to no purpose.
    static let files = ["feeds.json", "read.json", "classifier.json",
                        "picture-signatures.json"]

    /// Written into the container once the copy has been attempted, so a
    /// second launch does not re-copy over newer data. Its presence, not the
    /// presence of the data, is the test: a user with no old store still gets
    /// a marker and is never asked again.
    private static let markerName = ".migrated-into-container"

    /// The user's real home directory, not the container's.
    ///
    /// `NSHomeDirectory()` is container-relative inside a sandbox — measured,
    /// it returns `~/Library/Containers/cc.jorviksoftware.JorvikDailyNews/Data`
    /// — so building the legacy path from it produced the container path
    /// itself. The same-path guard below then fired and the migration
    /// silently did nothing, which is the exact failure it exists to prevent
    /// and would have shipped as "it lost my feeds".
    ///
    /// `getpwuid` reads the passwd database and is unaffected by the
    /// container, which is why it is worth the three lines of C.
    private static var realHome: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir))
        }
        return URL(fileURLWithPath: NSHomeDirectory())
    }

    static func runIfNeeded() {
        let container = FileManager.default.urls(for: .applicationSupportDirectory,
                                                 in: .userDomainMask)[0]
            .appendingPathComponent("JorvikDailyNews", isDirectory: true)
        let marker = container.appendingPathComponent(markerName)
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }

        // Only meaningful inside a container. Unsandboxed, the two paths are
        // the same directory and copying it onto itself is at best a no-op.
        let legacy = realHome
            .appendingPathComponent("Library/Application Support/JorvikDailyNews",
                                    isDirectory: true)
        guard legacy.path != container.path else {
            jdnLog("migration: not sandboxed — the store is already where it belongs")
            try? Data().write(to: marker, options: .atomic)
            return
        }

        try? FileManager.default.createDirectory(at: container,
                                                 withIntermediateDirectories: true)

        var copied: [String] = []
        var failed: [String] = []
        for name in files {
            let from = legacy.appendingPathComponent(name)
            let to = container.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: from.path) else { continue }
            // Never overwrite. If a file is already in the container the user
            // has run this build before the marker was written — a crash
            // mid-migration — and the container's copy is the newer one.
            guard !FileManager.default.fileExists(atPath: to.path) else { continue }
            do {
                try FileManager.default.copyItem(at: from, to: to)
                copied.append(name)
            } catch {
                failed.append("\(name): \(error.localizedDescription)")
            }
        }

        // The marker goes down even when nothing was copied, so a fresh
        // install does not look for the old store on every launch.
        try? Data().write(to: marker, options: .atomic)

        if copied.isEmpty && failed.isEmpty {
            jdnLog("migration: nothing to bring into the container — a fresh install")
        } else {
            jdnLog("migration: brought \(copied.count) file(s) into the container"
                   + (copied.isEmpty ? "" : " — \(copied.joined(separator: ", "))"))
        }
        for problem in failed {
            jdnLog("migration: could NOT copy \(problem)")
        }
    }
}
