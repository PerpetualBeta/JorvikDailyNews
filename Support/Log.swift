import Foundation

// Diagnostic logging — off by default, enabled per-machine via:
//
//   defaults write cc.jorviksoftware.JorvikDailyNews debugLogging -bool YES
//   defaults delete cc.jorviksoftware.JorvikDailyNews debugLogging   # turn off
//
// When on, timestamped lines are appended to
//   ~/Library/Containers/cc.jorviksoftware.JorvikDailyNews/Data/
//     Library/Logs/Jorvik Daily News/jorvikdailynews.log
// and the lines before the last rotation are kept in jorvikdailynews.log.1.
//
// Inside the container, because `.libraryDirectory` is container-relative in a
// sandboxed app. It was ~/Library/Logs/Jorvik Daily News/ before 1.4.9.
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

private let jdnPreviousLogPath = jdnLogPath + ".1"

/// Rotate once the live log passes this many bytes, keeping one previous
/// generation, so the logs can never occupy more than twice this figure.
///
/// 4 MB by default, as in MenuTidy and Nomen. Until 1.9.0 the log grew for
/// ever and had reached 13.6 MB. A knob, because a long diagnostic session may
/// want more:
///
///     defaults write cc.jorviksoftware.JorvikDailyNews debugLogMaxBytes -int 20971520
private var jdnLogMaxBytes: Int {
    let stored = UserDefaults.standard.integer(forKey: "debugLogMaxBytes")
    return stored > 0 ? stored : 4 * 1024 * 1024
}

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
    let limit = jdnLogMaxBytes
    jdnLogQueue.async {
        var text = ""
        if !jdnHeaderWritten {
            jdnHeaderWritten = true
            text += "\(stamp)  \(jdnSessionHeader)\n"
        }
        text += "\(stamp)  \(message)\n"
        jdnAppend(text)
        // Only this process writes the log (the PDF service never calls jdnLog),
        // and only on this serial queue, so the size read here is the file just
        // written to, and nothing can rotate it in between.
        var info = stat()
        guard stat(jdnLogPath, &info) == 0, info.st_size >= limit else { return }
        unlink(jdnPreviousLogPath)
        guard rename(jdnLogPath, jdnPreviousLogPath) == 0 else { return }
        // The new file starts with the session header, so it still says which
        // build and OS wrote it.
        jdnAppend("\(stamp)  \(jdnSessionHeader)\n"
                  + "\(stamp)  log rotated at \(info.st_size) bytes; the lines before this are in jorvikdailynews.log.1\n")
    }
}

/// Appends text to the log. Runs on `jdnLogQueue` only.
private func jdnAppend(_ text: String) {
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
