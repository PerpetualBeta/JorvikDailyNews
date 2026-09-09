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

    static func suite(_ name: String, _ body: () throws -> Void) {
        currentSuite = name
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

    static func report() -> Int32 {
        print("")
        if failures.isEmpty {
            print("\(checks) checks passed")
            return 0
        }
        print("\(failures.count) failure(s) of \(checks) checks:")
        for f in failures { print("  - \(f)") }
        return 1
    }
}
