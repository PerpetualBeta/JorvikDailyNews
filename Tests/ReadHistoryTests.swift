import Foundation

/// Today's read marks, in order, for Undo.
enum ReadHistoryTests {
    private static func scratch() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jdn-history-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func run() {
        MainActor.assumeIsolated { runOnMain() }
    }

    @MainActor
    private static func runOnMain() {
        T.suite("Read history: Undo takes back the newest first") {
            let dir = scratch()
            defer { try? FileManager.default.removeItem(at: dir) }
            let history = ReadHistory(directory: dir)
            history.record("a", wasLead: true)
            history.record("b", wasLead: false)
            T.equal(history.popLatest()?.itemId, "b", "the last read comes back first")
            let a = history.popLatest()
            T.equal(a?.itemId, "a", "then the one before it")
            T.expect(a?.wasLead == true, "remembering it was the lead")
            T.expect(history.popLatest() == nil, "and then there is nothing left")
            T.expect(history.isEmpty, "which it says")
        }

        T.suite("Read history: survives a relaunch, but only for today") {
            let dir = scratch()
            defer { try? FileManager.default.removeItem(at: dir) }
            var clock = Date()
            let first = ReadHistory(directory: dir, now: { clock })
            first.record("today", wasLead: false)
            T.equal(ReadHistory(directory: dir, now: { clock }).popLatest()?.itemId, "today",
                    "a relaunch the same day still has it")
            first.record("yesterday", wasLead: false)
            clock = clock.addingTimeInterval(86_400)
            let next = ReadHistory(directory: dir, now: { clock })
            T.expect(next.isEmpty, "the next day starts with nothing to undo")
            T.expect(next.popLatest() == nil, "and Undo finds nothing")
        }
    }
}
