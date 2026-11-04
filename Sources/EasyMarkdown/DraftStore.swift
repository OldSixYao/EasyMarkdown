import Foundation
import CryptoKit

struct RecoveryDraft: Codable, Sendable {
    let baseline: Data
    let text: String
    let savedAt: Date
}

actor DraftStore {
    static let shared = DraftStore()

    private func location(_ url: URL) throws -> URL {
        let folder = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                appropriateFor: nil, create: true)
            .appendingPathComponent("EasyMarkdown/Drafts", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let key = SHA256.hash(data: Data(url.standardizedFileURL.path.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent(key + ".json")
    }

    func load(_ url: URL) throws -> RecoveryDraft? {
        try Task.checkCancellation()
        let file = try location(url)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try JSONDecoder().decode(RecoveryDraft.self, from: Data(contentsOf: file))
    }

    func save(_ draft: RecoveryDraft, for url: URL) throws {
        try Task.checkCancellation()
        try JSONEncoder().encode(draft).write(to: location(url), options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    func remove(_ url: URL) throws {
        try Task.checkCancellation()
        let file = try location(url)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
}
