import Foundation

// Diagnostic logging — off by default, enabled per-machine via:
//
//   defaults write cc.jorviksoftware.JorvikDailyNews debugLogging -bool YES
//   defaults delete cc.jorviksoftware.JorvikDailyNews debugLogging   # turn off
//
// When on, timestamped lines are appended to
//   ~/Library/Logs/Jorvik Daily News/jorvikdailynews.log
// (per-user, owner-only directory — not /private/tmp, where a predictable
// filename invites a symlink-target-overwrite by any same-user process.) The
// flag is read once per call, so toggling it takes effect on the next line
// without a relaunch.
//
// The first line of each run records the app and OS versions, so a log pasted
// into an issue identifies itself without anyone having to ask.

private let jdnLogPath: String = {
    let logs = FileManager.default
        .urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs", isDirectory: true)
        .appendingPathComponent("Jorvik Daily News", isDirectory: true)
    try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
    return logs.appendingPathComponent("jorvikdailynews.log").path
}()

private let jdnLogQueue = DispatchQueue(label: "cc.jorviksoftware.JorvikDailyNews.log")

private let jdnLogFmt: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    return f
}()

private let jdnSessionHeader: String = {
    let info = Bundle.main.infoDictionary
    let short = info?["CFBundleShortVersionString"] as? String ?? "?"
    let build = info?["CFBundleVersion"] as? String ?? "?"
    let os = ProcessInfo.processInfo.operatingSystemVersionString
    return "=== Jorvik Daily News \(short) (\(build)) — \(os) ==="
}()

private var jdnHeaderWritten = false

func jdnLog(_ message: String) {
    guard UserDefaults.standard.bool(forKey: "debugLogging") else { return }
    let stamp = jdnLogFmt.string(from: Date())
    jdnLogQueue.async {
        var text = ""
        if !jdnHeaderWritten {
            jdnHeaderWritten = true
            text += "\(stamp)  \(jdnSessionHeader)\n"
        }
        text += "\(stamp)  \(message)\n"
        guard let data = text.data(using: .utf8) else { return }
        // O_NOFOLLOW: refuse to follow a symlink at this path. Combined with the
        // 0700 parent directory created above, this closes the symlink-attack
        // vector entirely.
        let fd = open(jdnLogPath, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        data.withUnsafeBytes { buf in
            _ = write(fd, buf.baseAddress, buf.count)
        }
    }
}
