import Foundation

public enum DocumentKind: String, Sendable {
    case markdown, text, json, xml, yaml, toml, ini, configuration, environment, properties, jsonc

    public init(url: URL?) {
        let name = url?.lastPathComponent.lowercased() ?? ""
        if name == ".env" || name.hasPrefix(".env.") { self = .environment; return }
        switch url?.pathExtension.lowercased() {
        case "md", "markdown", "mdown", "mkd": self = .markdown
        case "json": self = .json
        case "xml", "svg", "plist": self = .xml
        case "yaml", "yml": self = .yaml
        case "toml": self = .toml
        case "ini": self = .ini
        case "conf", "cfg", "cnf": self = .configuration
        case "env": self = .environment
        case "properties": self = .properties
        case "jsonc": self = .jsonc
        default: self = .text
        }
    }
}
