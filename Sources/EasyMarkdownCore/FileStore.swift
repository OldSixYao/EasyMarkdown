import Foundation

public actor FileStore {
    public init() {}

    public func read(_ url: URL) throws -> FileSnapshot {
        try coordinatedRead(url)
    }

    public func signature(_ url: URL) throws -> String {
        // URL resource values may be cached; poll fresh filesystem attributes instead.
        let values = try FileManager.default.attributesOfItem(atPath: url.path)
        return "\((values[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0):\(values[.size] ?? 0):\(values[.systemFileNumber] ?? 0)"
    }

    public func save(_ text: String, to url: URL, baseline: FileSnapshot,
                     requireUnchanged: Bool) throws -> FileSnapshot {
        let snapshot = try baseline.replacingText(text)
        var coordinationError: NSError?
        var result: Result<Void, Error>?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing,
                                        error: &coordinationError) { coordinatedURL in
            result = Result {
                if requireUnchanged {
                    guard FileManager.default.fileExists(atPath: coordinatedURL.path) else {
                        throw DocumentError.missingFile
                    }
                    let current = try Data(contentsOf: coordinatedURL)
                    guard current == baseline.data else { throw DocumentError.externalChange }
                }
                try snapshot.data.write(to: coordinatedURL, options: .atomic)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileWriteUnknown) }
        try result.get()
        return snapshot
    }

    private func coordinatedRead(_ url: URL) throws -> FileSnapshot {
        var coordinationError: NSError?
        var result: Result<FileSnapshot, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { target in
            result = Result {
                let size = try target.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= FileSnapshot.maximumBytes else { throw DocumentError.tooLarge }
                return try FileSnapshot(data: Data(contentsOf: target))
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return try result.get()
    }
}
