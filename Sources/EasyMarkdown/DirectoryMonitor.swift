import Foundation

/// One kernel watcher per directory, regardless of the number of open files.
@MainActor final class DirectoryMonitor {
    static let shared = DirectoryMonitor()
    struct Subscription { let path: String; let id: UUID }

    private final class Entry {
        var callbacks: [UUID: () -> Void] = [:]
        var source: DispatchSourceFileSystemObject?
        var opening: Task<Void, Never>?
    }
    private var entries: [String: Entry] = [:]
    var directoryCount: Int { entries.count }
    func hasWatcher(_ subscription: Subscription) -> Bool { entries[subscription.path]?.source != nil }

    func subscribe(to url: URL, onChange: @escaping () -> Void) -> Subscription {
        let path = url.deletingLastPathComponent().path
        let entry = entries[path] ?? Entry()
        entries[path] = entry
        let subscription = Subscription(path: path, id: UUID())
        entry.callbacks[subscription.id] = onChange
        begin(path: path, entry: entry)
        return subscription
    }

    func unsubscribe(_ subscription: Subscription) {
        guard let entry = entries[subscription.path] else { return }
        entry.callbacks.removeValue(forKey: subscription.id)
        guard entry.callbacks.isEmpty else { return }
        entries.removeValue(forKey: subscription.path)
        entry.opening?.cancel()
        entry.source?.cancel()
    }

    func ensureWatching(_ subscription: Subscription) {
        guard let entry = entries[subscription.path] else { return }
        begin(path: subscription.path, entry: entry)
    }

    private func begin(path: String, entry: Entry) {
        guard entry.source == nil, entry.opening == nil else { return }
        entry.opening = Task { [weak self, weak entry] in
            let descriptor = await Task.detached(priority: .utility) { open(path, O_EVTONLY) }.value
            guard let self, let entry, !Task.isCancelled, self.entries[path] === entry,
                  descriptor >= 0 else {
                if descriptor >= 0 { close(descriptor) }
                entry?.opening = nil
                return
            }
            entry.opening = nil
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                eventMask: [.write, .rename, .delete, .attrib], queue: .main)
            source.setEventHandler { [weak entry, weak source] in
                guard let entry, let source else { return }
                for callback in Array(entry.callbacks.values) { callback() }
                if !source.data.intersection([.rename, .delete]).isEmpty {
                    source.cancel()
                    entry.source = nil
                }
            }
            source.setCancelHandler { close(descriptor) }
            entry.source = source
            source.resume()
        }
    }
}
