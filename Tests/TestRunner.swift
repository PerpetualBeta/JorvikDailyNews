import Foundation

/// A test harness small enough to read in one sitting.
///
/// Not XCTest: that wants a host bundle and a test runner, and this app is a
/// single `swiftc` binary with no Xcode project. QuitProtect's `swift test`
/// needs `release.mk`'s framework flags to work at all, which is a dependency
/// worth not acquiring. This is an executable that asserts and exits non-zero,
/// which is everything CI or a human needs from it.
enum T {
    nonisolated(unsafe) private static var checks = 0
    nonisolated(unsafe) private static var failures: [String] = []
    nonisolated(unsafe) private static var currentSuite = ""
    nonisolated(unsafe) private static var suites = 0

    static func suite(_ name: String, _ body: () throws -> Void) {
        currentSuite = name
        suites += 1
        let before = failures.count
        do {
            try body()
        } catch {
            failures.append("\(name): threw \(error)")
        }
        let failed = failures.count - before
        let mark = failed == 0 ? "ok  " : "FAIL"
        print("  \(mark) \(name)\(failed == 0 ? "" : "  (\(failed) failed)")")
    }

    static func expect(_ condition: Bool, _ what: String,
                       file: String = #fileID, line: Int = #line) {
        checks += 1
        guard !condition else { return }
        failures.append("\(currentSuite): \(what)  [\(file):\(line)]")
    }

    static func equal<V: Equatable>(_ got: V, _ want: V, _ what: String,
                                    file: String = #fileID, line: Int = #line) {
        checks += 1
        guard got != want else { return }
        failures.append("\(currentSuite): \(what) — expected \(want), got \(got)  [\(file):\(line)]")
    }

    /// Fixture bytes, resolved relative to this file so the tests run from any
    /// working directory.
    static func fixture(_ name: String, file: String = #filePath) -> Data {
        let dir = URL(fileURLWithPath: file).deletingLastPathComponent()
        let url = dir.appendingPathComponent("Fixtures").appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else {
            failures.append("fixture missing: \(name) (looked in \(url.path))")
            return Data()
        }
        return data
    }

    /// The build page quotes the size of this suite. A number written by hand in
    /// prose goes stale the moment anyone adds a test, and nothing would say so,
    /// so the suite checks its own documentation instead of anyone remembering to.
    ///
    /// Silent when the page is absent — a copy of the binary without the repo
    /// around it is not a failure.
    private static func documentedSizeMismatch(file: String = #filePath) -> String? {
        let root = URL(fileURLWithPath: file)
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // the repository
        let page = root.appendingPathComponent("Documentation/building.md")
        guard let text = try? String(contentsOf: page, encoding: .utf8) else { return nil }

        let pattern = #"\*\*(\d+) checks across (\d+) suites\*\*"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let c = Range(m.range(at: 1), in: text).flatMap({ Int(text[$0]) }),
              let u = Range(m.range(at: 2), in: text).flatMap({ Int(text[$0]) })
        else {
            return "Documentation/building.md no longer states the suite size in the form "
                 + "**N checks across M suites**, so it cannot be kept honest. Restore that "
                 + "phrase, or delete this check along with it."
        }

        guard c != checks || u != suites else { return nil }
        return "Documentation/building.md says \(c) checks across \(u) suites; this run was "
             + "\(checks) across \(suites). Correct the page."
    }

    static func report() -> Int32 {
        print("")
        let drift = documentedSizeMismatch()
        if failures.isEmpty && drift == nil {
            print("\(checks) checks across \(suites) suites passed")
            return 0
        }
        if let drift {
            print("documentation out of date:")
            print("  - \(drift)")
        }
        if !failures.isEmpty {
            print("\(failures.count) failure(s) of \(checks) checks:")
            for f in failures { print("  - \(f)") }
        }
        return 1
    }
}
