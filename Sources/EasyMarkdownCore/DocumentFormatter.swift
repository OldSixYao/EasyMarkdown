import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public enum DocumentFormatter {
    public static func format(_ text: String, kind: DocumentKind) throws -> String {
        switch kind {
        case .json:
            do {
                let object = try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
                let data = try JSONSerialization.data(withJSONObject: object,
                    options: [.prettyPrinted, .fragmentsAllowed, .withoutEscapingSlashes])
                return String(decoding: data, as: UTF8.self) + "\n"
            } catch {
                throw DocumentError.invalidFormat("JSON 格式无效：\(error.localizedDescription)")
            }
        case .xml:
            // A DTD can change meaning and expand entities; don't rewrite such documents.
            guard !text.localizedCaseInsensitiveContains("<!DOCTYPE"),
                  !text.localizedCaseInsensitiveContains("<!ENTITY") else {
                throw DocumentError.invalidFormat("包含 DTD 或实体声明的 XML 暂不支持格式化，原文已保留。")
            }
            do {
                let document = try XMLDocument(xmlString: text, options: [.nodePreserveAll, .nodeLoadExternalEntitiesNever])
                return document.xmlString(options: [.nodePrettyPrint]) + "\n"
            } catch {
                throw DocumentError.invalidFormat("XML 格式无效：\(error.localizedDescription)")
            }
        default: return text
        }
    }
}
