import Foundation
import CryptoKit
import EasyMarkdownCore

struct RecoveryDraft: Codable, Sendable {
    let baseline: Data
    let text: String
    let savedAt: Date
    var baselineID: UUID? = nil
}

actor DraftStore {
    static let shared = DraftStore()
    private let directory: URL?
    private var baselineKeys: [String: (UUID, String)] = [:]

    init(directory: URL? = nil) { self.directory = directory }

    private struct Manifest: Codable {
        let version: Int
        let baseline: String
        let text: String
        let savedAt: Date
    }

    private func root() throws -> URL {
        let folder = try directory ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true).appendingPathComponent("EasyMarkdown/Drafts", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func key(_ url: URL) -> String {
        SHA256.hash(data: Data(url.standardizedFileURL.path.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    func load(_ url: URL) throws -> RecoveryDraft? {
        try Task.checkCancellation()
        let folder = try root().appendingPathComponent(key(url), isDirectory: true)
        let manifestURL = folder.appendingPathComponent("manifest.plist")
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            let metadata = try boundedData(manifestURL, maximum: 16_384)
            let manifest = try PropertyListDecoder().decode(Manifest.self, from: metadata)
            guard manifest.version == 1, isSafeName(manifest.baseline, prefix: "baseline-", suffix: ".bin"),
                  isSafeName(manifest.text, prefix: "text-", suffix: ".utf8") else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let baseline = try boundedData(folder.appendingPathComponent(manifest.baseline), maximum: FileSnapshot.maximumBytes)
            let data = try boundedData(folder.appendingPathComponent(manifest.text), maximum: 128 * 1024 * 1024)
            guard let text = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadCorruptFile) }
            return RecoveryDraft(baseline: baseline, text: text, savedAt: manifest.savedAt)
        }
        let legacy = try root().appendingPathComponent(key(url) + ".json")
        guard FileManager.default.fileExists(atPath: legacy.path) else { return nil }
        let draft = try JSONDecoder().decode(RecoveryDraft.self,
            from: boundedData(legacy, maximum: 256 * 1024 * 1024))
        // A failed migration must not prevent recovery from the intact old file.
        try? save(draft, for: url)
        return draft
    }

    func save(_ draft: RecoveryDraft, for url: URL) throws {
        try Task.checkCancellation()
        let key = key(url)
        let root = try root()
        let folder = root.appendingPathComponent(key, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let digest: String
        if let identity = draft.baselineID, let cached = baselineKeys[key], cached.0 == identity {
            digest = cached.1
        } else {
            digest = SHA256.hash(data: draft.baseline).map { String(format: "%02x", $0) }.joined()
            if let identity = draft.baselineID {
                if baselineKeys.count >= 200 { baselineKeys.removeAll(keepingCapacity: true) }
                baselineKeys[key] = (identity, digest)
            }
        }
        let baselineName = "baseline-" + digest + ".bin"
        let baselineURL = folder.appendingPathComponent(baselineName)
        if !FileManager.default.fileExists(atPath: baselineURL.path) {
            try draft.baseline.write(to: baselineURL, options: [.atomic, .completeFileProtectionUnlessOpen])
        }
        try Task.checkCancellation()
        let textName = "text-" + UUID().uuidString + ".utf8"
        let textURL = folder.appendingPathComponent(textName)
        try autoreleasepool {
            try Data(draft.text.utf8).write(to: textURL, options: [.atomic, .completeFileProtectionUnlessOpen])
        }
        do {
            try Task.checkCancellation()
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            let manifest = Manifest(version: 1, baseline: baselineName, text: textName, savedAt: draft.savedAt)
            // The manifest is the commit point. A crash/cancel before it leaves
            // the previous complete draft readable; no shared baseline is lost.
            try encoder.encode(manifest).write(to: folder.appendingPathComponent("manifest.plist"),
                options: [.atomic, .completeFileProtectionUnlessOpen])
        } catch {
            try? FileManager.default.removeItem(at: textURL)
            throw error
        }
        let keep: Set<String> = ["manifest.plist", baselineName, textName]
        for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            where !keep.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
        let legacy = root.appendingPathComponent(key + ".json")
        if FileManager.default.fileExists(atPath: legacy.path) { try? FileManager.default.removeItem(at: legacy) }
    }

    func remove(_ url: URL) throws {
        try Task.checkCancellation()
        let key = key(url)
        let root = try root()
        for file in [root.appendingPathComponent(key), root.appendingPathComponent(key + ".json")] {
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        }
        baselineKeys.removeValue(forKey: key)
    }

    private func boundedData(_ url: URL, maximum: Int) throws -> Data {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= maximum else { throw CocoaError(.fileReadTooLarge) }
        let data = try Data(contentsOf: url)
        guard data.count <= maximum else { throw CocoaError(.fileReadTooLarge) }
        return data
    }

    private func isSafeName(_ value: String, prefix: String, suffix: String) -> Bool {
        value.hasPrefix(prefix) && value.hasSuffix(suffix) && !value.contains("/") &&
            !value.contains("\\") && !value.contains("..") && value.count < 100
    }
}
