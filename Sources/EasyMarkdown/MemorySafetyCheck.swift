#if DEBUG
import AppKit
import EasyMarkdownCore

/// Deterministic lifetime checks: hold the file actors instead of depending on
/// a cloud provider or network volume happening to stall during a test.
@MainActor enum MemorySafetyCheck {
    private final class WeakSession {
        weak var value: DocumentSession?
        init(_ value: DocumentSession) { self.value = value }
    }

    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    static func run(directory: URL) async throws {
        try await blockedReload(directory: directory)
        try await blockedDraft(directory: directory)
        try boundedUndo(directory: directory)
    }

    private static func waitFor(_ description: String, _ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw Failure("Timed out: " + description)
    }

    private static func blockedReload(directory: URL) async throws {
        let url = directory.appendingPathComponent("blocked-reload.md")
        let data = Data("# Blocked reload\n".utf8)
        try data.write(to: url)
        var doc: MarkdownDocument? = MarkdownDocument(snapshot: try FileSnapshot(data: data), url: url)
        let store = doc!.session.store
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let blocker = Task.detached { await store.blockForMemoryCheck(entered: entered, release: release) }
        defer { release.signal() }
        try await waitFor("file actor held") { entered.wait(timeout: .now()) == .success }
        doc!.session.start()
        try await Task.sleep(for: .milliseconds(200))
        let reference = WeakSession(doc!.session)
        doc!.close()
        doc = nil
        try await waitFor("closed session released while reload still waits") { reference.value == nil }
        release.signal()
        await blocker.value
    }

    private static func blockedDraft(directory: URL) async throws {
        let url = directory.appendingPathComponent("blocked-draft.md")
        let data = Data("# Blocked draft\n".utf8)
        try data.write(to: url)
        var doc: MarkdownDocument? = MarkdownDocument(snapshot: try FileSnapshot(data: data), url: url)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let blocker = Task.detached { await DraftStore.shared.blockForMemoryCheck(entered: entered, release: release) }
        defer { release.signal() }
        try await waitFor("draft actor held") { entered.wait(timeout: .now()) == .success }
        doc!.session.edit("# Unsaved draft\n")
        try await Task.sleep(for: .milliseconds(700))
        let reference = WeakSession(doc!.session)
        doc!.updateChangeCount(.changeCleared)
        doc!.close()
        doc = nil
        try await waitFor("closed session released while draft still waits") { reference.value == nil }
        release.signal()
        await blocker.value
        guard try await DraftStore.shared.load(url) == nil else {
            throw Failure("Cancelled draft was written after close")
        }
    }

    private final class UndoCounter: NSObject { var count = 0 }

    private static func boundedUndo(directory: URL) throws {
        let doc = MarkdownDocument(snapshot: try FileSnapshot(data: Data("small".utf8)),
            url: directory.appendingPathComponent("undo-budget.md"))
        defer { doc.updateChangeCount(.changeCleared); doc.close() }
        guard let undo = doc.undoManager, undo.levelsOfUndo == 100 else {
            throw Failure("Small-document undo depth is not capped")
        }
        undo.groupsByEvent = false
        let counter = UndoCounter()
        func exercise(groups: Int, expected: Int) throws {
            counter.count = 0
            for _ in 0..<groups {
                undo.beginUndoGrouping()
                undo.registerUndo(withTarget: counter) { $0.count += 1 }
                undo.endUndoGrouping()
            }
            while undo.canUndo { undo.undo() }
            guard counter.count == expected else { throw Failure("Old undo groups were not evicted") }
        }
        try exercise(groups: 125, expected: 100)
        doc.session.edit(String(repeating: "x", count: 2 * 1024 * 1024))
        guard undo.levelsOfUndo == 16 else { throw Failure("Large-document undo budget did not shrink") }
        try exercise(groups: 40, expected: 16)
    }
}

private extension FileStore {
    func blockForMemoryCheck(entered: DispatchSemaphore, release: DispatchSemaphore) {
        entered.signal()
        release.wait()
    }
}

private extension DraftStore {
    func blockForMemoryCheck(entered: DispatchSemaphore, release: DispatchSemaphore) {
        entered.signal()
        release.wait()
    }
}
#endif
