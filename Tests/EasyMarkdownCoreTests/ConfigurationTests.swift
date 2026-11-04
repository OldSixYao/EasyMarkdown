import Foundation
#if !STANDALONE_CHECKS
import XCTest
@testable import EasyMarkdownCore
#endif

final class ConfigurationTests: XCTestCase {
    func testConfigurationNamesAndAliases() {
        let names: [(String, DocumentKind)] = [
            ("compose.yaml", .yaml), ("ci.YML", .yaml), ("Cargo.toml", .toml),
            ("settings.ini", .ini), ("nginx.conf", .configuration), ("settings.cfg", .configuration),
            ("my.cnf", .configuration), (".env", .environment), (".env.local", .environment),
            (".ENV.production", .environment), ("sample.env", .environment),
            ("app.properties", .properties), ("settings.jsonc", .jsonc),
            ("a.json", .json), ("a.xml", .xml), ("a.plist", .xml), ("README.md", .markdown),
            ("environment.local", .text), (".envrc", .text)
        ]
        for (name, expected) in names {
            XCTAssertEqual(DocumentKind(url: URL(fileURLWithPath: "/tmp/" + name)), expected)
        }
        XCTAssertEqual(DocumentKind(url: nil), .text)
    }

    func testConfigurationFormattingPreservesCommentsAndWhitespace() throws {
        let source = "# 原文 📝\r\nkey: 'yes' # comment\r\n  list: [1, 2,]\r\n\tvalue = ${HOME}\r\n"
        for kind: DocumentKind in [.yaml, .toml, .ini, .configuration, .environment, .properties, .jsonc] {
            XCTAssertEqual(try DocumentFormatter.format(source, kind: kind), source)
        }
    }

    func testConfigurationFileRoundTripPreservesBOMAndCRLF() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileStore()
        for name in ["compose.yaml", "pyproject.toml", "settings.ini", "app.conf", ".env", "app.properties", "settings.jsonc"] {
            let file = root.appendingPathComponent(name)
            let source = "# 注释 📝\r\nkey = old\r\n"
            let original = Data([0xEF, 0xBB, 0xBF]) + Data(source.utf8)
            try original.write(to: file)
            let snapshot = try await store.read(file)
            XCTAssertEqual(try snapshot.replacingText(snapshot.text).data, original)
            _ = try await store.save(source.replacingOccurrences(of: "old", with: "new"), to: file,
                baseline: snapshot, requireUnchanged: true)
            XCTAssertEqual(try Data(contentsOf: file), Data([0xEF, 0xBB, 0xBF]) + Data(source.replacingOccurrences(of: "old", with: "new").utf8))
        }
    }
}
