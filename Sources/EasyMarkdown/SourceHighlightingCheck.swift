#if DEBUG
import AppKit
import EasyMarkdownCore

/// Checks the actual TextKit colors, including every UTF-16 unit in a token.
@MainActor enum SourceHighlightingCheck {
    private struct Fixture {
        let name: String
        let source: String
        let expected: [(String, NSColor?)]
        var lastExpected: [(String, NSColor?)] = []
    }

    @discardableResult static func run() throws -> Int {
        let fixtures: [Fixture] = [
            Fixture(name: "plain-values.yaml", source: "mode: rule\nlog-level: warning\ndns:\n  enhanced-mode: fake-ip\n  fake-ip-range: 198.18.0.1/16\n  default-nameserver: [192.0.2.1, 198.51.100.2]\n  alpn: [h3]\nproxies:\n  - name: example\n    type: hysteria2\n    server: 203.0.113.10\n    port: 443\n",
                expected: [("rule", .systemBlue), ("warning", .systemBlue), ("fake-ip-range", .systemGreen),
                           ("fake-ip", .systemBlue), ("198.18.0.1/16", .systemBlue), ("192.0.2.1", .systemBlue),
                           ("198.51.100.2", .systemBlue), ("h3", .systemBlue), ("hysteria2", .systemBlue),
                           ("203.0.113.10", .systemBlue), ("example", .systemBlue), ("443", .systemPurple)]),
            Fixture(name: "plain-text.yaml", source: "message: hello true 42 # actual comment\n网址: https://example.com:8443/dns-query?x=true#part\nipv6: 2001:db8::1\nrules:\n  - DOMAIN-SUFFIX,example.com,DIRECT\n  - MATCH,default\nflow: { name: example, items: [h3, fake-ip, -2.6e+10, false] }\n",
                expected: [("message", .systemGreen), ("hello true 42", .systemBlue), ("# actual comment", .secondaryLabelColor),
                           ("网址", .systemGreen), ("https://example.com:8443/dns-query?x=true#part", .systemBlue),
                           ("2001:db8::1", .systemBlue), ("DOMAIN-SUFFIX,example.com,DIRECT", .systemBlue),
                           ("MATCH,default", .systemBlue), ("name", .systemGreen), ("example", .systemBlue),
                           ("items", .systemGreen), ("h3", .systemBlue), ("fake-ip", .systemBlue), ("-2.6e+10", .systemPurple), ("false", .systemPurple)]),
            Fixture(name: "anchors.yaml", source: "defaults: &base\n  mode: rule\ncopy: *base\nmessage: a long line\n  with true 42 and key: value\nnext: !!str 123\n",
                expected: [("&base", .systemBlue), ("*base", .systemBlue), ("mode", .systemGreen), ("rule", .systemBlue),
                           ("a long line", .systemBlue), ("with true 42 and key: value", .systemBlue), ("!!str", .systemBlue), ("123", .systemBlue)]),
            Fixture(name: "continued.yaml", source: "message:\n  first line\n  # actual comment\n  true 42 and key: value\nnext: rule\nlist:\n  - item\n  - name: example\n    type: text\n",
                expected: [("first line", .systemBlue), ("# actual comment", .secondaryLabelColor), ("true 42 and key: value", .systemBlue), ("next", .systemGreen),
                           ("name", .systemGreen), ("type", .systemGreen), ("text", .systemBlue)]),
            Fixture(name: ".env.literal", source: "PATH='folder\\'\nNEXT=rule\n",
                expected: [("'folder\\'", .systemBlue), ("NEXT", .systemGreen), ("rule", .systemBlue)]),
            Fixture(name: "sequence-block.yaml", source: "list:\n  - script: |-\n      # not a comment\n      value: true 42\n    name: example\n  - >\n    next line\nend: rule\n",
                expected: [("script", .systemGreen), ("      # not a comment\n      value: true 42\n", .systemBlue),
                           ("name", .systemGreen), ("example", .systemBlue), ("    next line\n", .systemBlue), ("end", .systemGreen), ("rule", .systemBlue)]),
            Fixture(name: "plain.ini", source: "[app]\nmode = rule\nmessage = don't change true 42 ; comment\nurl = https://example.com:8443/#part\n",
                expected: [("mode", .systemGreen), ("rule", .systemBlue), ("don't change true 42", .systemBlue),
                           ("; comment", .secondaryLabelColor), ("https://example.com:8443/#part", .systemBlue)]),
            Fixture(name: "plain.conf", source: "name: example\nmode = rule\ncommand = echo true 42 # comment\nserver = 203.0.113.10\n",
                expected: [("name", .systemGreen), ("example", .systemBlue), ("rule", .systemBlue),
                           ("echo true 42", .systemBlue), ("# comment", .secondaryLabelColor), ("203.0.113.10", .systemBlue)]),
            Fixture(name: ".env.example", source: "export MODE=rule\nSERVER=203.0.113.10\nMESSAGE=hello true 42 # comment\nURL=https://example.com:8443/path\n",
                expected: [("export MODE", .systemGreen), ("rule", .systemBlue), ("203.0.113.10", .systemBlue),
                           ("hello true 42", .systemBlue), ("# comment", .secondaryLabelColor), ("https://example.com:8443/path", .systemBlue)]),
            Fixture(name: "plain.properties", source: "mode=rule\nserver=203.0.113.10\nurl=https://example.com:8443/#part\nfield\\ name: hello true 42\nmessage=first\\\n  # second true 42\n",
                expected: [("mode", .systemGreen), ("rule", .systemBlue), ("203.0.113.10", .systemBlue),
                           ("https://example.com:8443/#part", .systemBlue), ("field\\ name", .systemGreen),
                           ("hello true 42", .systemBlue), ("first\\\n  # second true 42", .systemBlue)]),
            Fixture(name: "dates.toml", source: "date = 2026-11-09T07:32:00Z\ncount = 0xff\nsize = 1_000\n",
                expected: [("date", .systemGreen), ("2026-11-09T07:32:00Z", .systemBlue), ("0xff", .systemPurple), ("1_000", .systemPurple)]),
            Fixture(name: "plain.xml", source: "<?xml version=\"1.0\"?><root mode=\"rule\"><name>中文📝 example</name><url>https://example.com:8443/?a=1&amp;b=2</url> mixed <b>text</b> tail<![CDATA[raw <tag> true 42]]><!-- comment --></root>",
                expected: [("<root", .systemGreen), ("mode", .systemGreen), ("\"rule\"", .systemBlue), ("中文📝 example", .systemBlue),
                           ("https://example.com:8443/?a=1&amp;b=2", .systemBlue), (" mixed ", .systemBlue), ("text", .systemBlue),
                           (" tail", .systemBlue), ("raw <tag> true 42", .systemBlue), ("<!-- comment -->", .secondaryLabelColor)]),
            Fixture(name: "strings.json", source: #"{"model":"gpt-image-2.6-sunburst","text":"中文📝 true false null 42","escaped":"a\" 2.6","count":-2.6e+10,"enabled":true}"#,
                expected: [(#""model""#, .systemGreen), (#""count""#, .systemGreen),
                           (#""gpt-image-2.6-sunburst""#, .systemBlue), (#""中文📝 true false null 42""#, .systemBlue),
                           (#""a\" 2.6""#, .systemBlue), ("-2.6e+10", .systemPurple), ("}", nil)]),
            Fixture(name: "fields.json", source: "{\"same\":\"same\",\"中文📝\"\r\n : \"text: true=2.6\",\"a\\\"b\":\"value\",\"list\":[\"array value\",{\"nested\":false}]}",
                expected: [("\"same\"", .systemGreen), ("\"中文📝\"", .systemGreen), ("\"a\\\"b\"", .systemGreen),
                           ("\"nested\"", .systemGreen), ("\"text: true=2.6\"", .systemBlue), ("\"array value\"", .systemBlue)],
                lastExpected: [("\"same\"", .systemBlue)]),
            Fixture(name: "literals.json", source: "[true,false,null,-2.6e+10,0,1E-3]",
                expected: [("true", .systemPurple), ("false", .systemPurple), ("null", .systemPurple),
                           ("-2.6e+10", .systemPurple), ("1E-3", .systemPurple), ("[", nil), ("]", nil)]),
            Fixture(name: "comments.jsonc", source: #"{"url":"https://example.com/a/* true */?v=2.6","value":true // "quoted" 2.6 false"# + "\n/* \"open\n true 42 */\n,\"next\":false}",
                expected: [(#""url""#, .systemGreen), (#""next""#, .systemGreen),
                           (#""https://example.com/a/* true */?v=2.6""#, .systemBlue), ("// \"quoted\" 2.6 false", .secondaryLabelColor),
                           ("/* \"open\n true 42 */", .secondaryLabelColor), ("}", nil)]),
            Fixture(name: "fields.jsonc", source: "{\"same\" /* : \"fake\" */ // field\r\n : \"same\",\"list\":[\"value: true\"],\"next\":42}",
                expected: [("\"same\"", .systemGreen), ("/* : \"fake\" */", .secondaryLabelColor),
                           ("// field", .secondaryLabelColor), ("\"list\"", .systemGreen), ("\"value: true\"", .systemBlue), ("\"next\"", .systemGreen)],
                lastExpected: [("\"same\"", .systemBlue)]),
            Fixture(name: "values.yaml", source: "model: \"gpt-image-2.6-sunburst # true\" # \"comment\" false 42\nname: 'it''s true 2.6'\ncount: -2.6e+10\nurl: https://example.com/#part\n",
                expected: [("model", .systemGreen), ("count", .systemGreen), ("\"gpt-image-2.6-sunburst # true\"", .systemBlue), ("# \"comment\" false 42", .secondaryLabelColor),
                           ("'it''s true 2.6'", .systemBlue), ("-2.6e+10", .systemPurple), ("#part", .systemBlue)]),
            Fixture(name: "fields.yaml", source: "\"same\": \"same\"\n'it''s a key': 'value: 2.6'\nlist:\n  - \"nested\": \"text: true\"\n  - name: \"list value\"\ninline: { enabled: false, \"ratio\": 1 }\n",
                expected: [("\"same\"", .systemGreen), ("'it''s a key'", .systemGreen), ("'value: 2.6'", .systemBlue),
                           ("\"nested\"", .systemGreen), ("\"text: true\"", .systemBlue), ("name", .systemGreen),
                           ("\"list value\"", .systemBlue), ("enabled", .systemGreen), ("false", .systemPurple), ("\"ratio\"", .systemGreen)],
                lastExpected: [("\"same\"", .systemBlue)]),
            Fixture(name: "values.toml", source: "[package]\nmodel = \"gpt-image-2.6-sunburst # true\" # \"comment\" false 42\nname = 'true 2.6'\ncount = -2.6e+10\n",
                expected: [("[package]", .systemGreen), ("model", .systemGreen), ("count", .systemGreen), ("\"gpt-image-2.6-sunburst # true\"", .systemBlue),
                           ("# \"comment\" false 42", .secondaryLabelColor), ("'true 2.6'", .systemBlue), ("-2.6e+10", .systemPurple)]),
            Fixture(name: "fields.toml", source: "\"same\" = \"same\"\n'field name'.child = 'value=2.6'\ninline = { \"nested\" = \"text=true\" }\n",
                expected: [("\"same\"", .systemGreen), ("'field name'.child", .systemGreen), ("'value=2.6'", .systemBlue),
                           ("\"nested\"", .systemGreen), ("\"text=true\"", .systemBlue)],
                lastExpected: [("\"same\"", .systemBlue)]),
            Fixture(name: "multiline.toml", source: "text = \"\"\"first\n# false 2.6 'text'\nlast\"\"\"\nother = '''first\n# true 42 \"text\"\nlast'''\nnext = false\n",
                expected: [("\"\"\"first\n# false 2.6 'text'\nlast\"\"\"", .systemBlue),
                           ("'''first\n# true 42 \"text\"\nlast'''", .systemBlue), ("next", .systemGreen)]),
            Fixture(name: "block.yaml", source: "outer:\n  text: |- # header\n    # not a comment: true 2.6\n    \"quoted\" [link](url)\n  next: false\n",
                expected: [("text", .systemGreen), ("# header", .secondaryLabelColor),
                           ("    # not a comment: true 2.6\n    \"quoted\" [link](url)\n", .systemBlue), ("next", .systemGreen)]),
            Fixture(name: "quoted-block.yaml", source: "'field name': |\n  text: true = 2.6\nnext: 42\n",
                expected: [("'field name'", .systemGreen), ("  text: true = 2.6\n", .systemBlue), ("next", .systemGreen), ("42", .systemPurple)]),
            Fixture(name: "apostrophe.yaml", source: "message: don't change this\nnext: false\n",
                expected: [("don't", .systemBlue), ("next", .systemGreen)]),
            Fixture(name: "values.ini", source: "[app]\nmodel = \"gpt-image-2.6-sunburst ; true\" ; \"comment\" false 42\noff = true\n",
                expected: [("[app]", .systemGreen), ("\"gpt-image-2.6-sunburst ; true\"", .systemBlue),
                           ("; \"comment\" false 42", .secondaryLabelColor), ("off", .systemGreen)]),
            Fixture(name: "values.conf", source: "model = \"gpt-image-2.6-sunburst # true\" # \"comment\" false 42\noff = true\n",
                expected: [("\"gpt-image-2.6-sunburst # true\"", .systemBlue), ("# \"comment\" false 42", .secondaryLabelColor), ("off", .systemGreen)]),
            Fixture(name: ".env", source: "export MODEL=\"gpt-image-2.6-sunburst # true\" # \"comment\" false 42\nURL='https://example.com/#part'\n",
                expected: [("export MODEL", .systemGreen), ("\"gpt-image-2.6-sunburst # true\"", .systemBlue),
                           ("# \"comment\" false 42", .secondaryLabelColor), ("'https://example.com/#part'", .systemBlue)]),
            Fixture(name: ".env.local", source: "MODEL=\"first\n# true 2.6\nlast\"\nNEXT=false\n",
                expected: [("\"first\n# true 2.6\nlast\"", .systemBlue), ("NEXT", .systemGreen)]),
            Fixture(name: "values.properties", source: "! \"comment\" false 42\nmodel=\"gpt-image-2.6-sunburst # true\"\nurl=https://example.com/#part\noff=true\n",
                expected: [("! \"comment\" false 42", .secondaryLabelColor), ("\"gpt-image-2.6-sunburst # true\"", .systemBlue),
                           ("#part", .systemBlue), ("off", .systemGreen)]),
            Fixture(name: "values.xml", source: "<root model=\"gpt-image-2.6-sunburst /> true\"><!-- \"comment\" <tag> 42 -->\n<![CDATA[\"text\" <tag> true 42]]></root>",
                expected: [("<root", .systemGreen), ("model", .systemGreen), ("\"gpt-image-2.6-sunburst /> true\"", .systemBlue),
                           ("<!-- \"comment\" <tag> 42 -->", .secondaryLabelColor), ("\"text\" <tag> true 42", .systemBlue)]),
            Fixture(name: "text.xml", source: "<?xml version=\"1.0\"?><root>don't change \"true 2.6\" <child value='2.6'/> text</root>",
                expected: [("<?xml", .systemGreen), ("version", .systemGreen), ("value", .systemGreen), ("\"1.0\"", .systemBlue), ("don't", .systemBlue),
                           ("\"true 2.6\"", .systemBlue), ("<child", .systemGreen), ("'2.6'", .systemBlue), ("/>", .systemGreen)]),
            Fixture(name: "attributes.xml", source: "<root first=\"true > 42\" second='false'><child value=\"text\"/></root>",
                expected: [("<root", .systemGreen), ("first", .systemGreen), ("\"true > 42\"", .systemBlue),
                           ("second", .systemGreen), ("'false'", .systemBlue), ("<child", .systemGreen),
                           ("value", .systemGreen), ("\"text\"", .systemBlue), ("/>", .systemGreen), ("</root>", .systemGreen)]),
            Fixture(name: "code.md", source: "# Heading `[中文📝](https://example.com/2.6)`\n\n[link](https://example.com)\n",
                expected: [("# Heading ", .systemBlue), ("`[中文📝](https://example.com/2.6)`", .systemOrange), ("[link](https://example.com)", .systemTeal)]),
            Fixture(name: "heading-links.md", source: "# 前文 [链接](https://example.com) 后文 `[代码](url)` <!-- [注释](url) -->\n",
                expected: [("# 前文 ", .systemBlue), ("[链接](https://example.com)", .systemTeal), (" 后文 ", .systemBlue),
                           ("`[代码](url)`", .systemOrange), ("<!-- [注释](url) -->", .secondaryLabelColor)]),
            Fixture(name: "fences.md", source: "````text\n# heading [link](url)\n```\n````\n\n~~~text\n[other](url)\n~~~\n\n<!-- [comment](url) -->\n",
                expected: [("````text\n# heading [link](url)\n```\n````", .systemOrange),
                           ("~~~text\n[other](url)\n~~~", .systemOrange), ("<!-- [comment](url) -->", .secondaryLabelColor)]),
            Fixture(name: "unfinished.json", source: "{\"model\":\"unfinished true 2.6\\",
                expected: [("\"unfinished true 2.6\\", .systemBlue)]),
            Fixture(name: "unfinished.jsonc", source: "{\"a\":true} /* \"unfinished false 2.6",
                expected: [("/* \"unfinished false 2.6", .secondaryLabelColor)]),
            Fixture(name: "long-line.jsonc", source: "/* " + String(repeating: "x", count: 5_000) + "\n\"false\" 2.6\n*/\n{\"after\":true}",
                expected: [(String(repeating: "x", count: 5_000), nil), ("\"false\" 2.6", .secondaryLabelColor), ("\"after\"", .systemGreen)]),
            Fixture(name: "plain.txt", source: "\"true 2.6\" # comment <tag> [link](url)", expected: [("\"true 2.6\" # comment <tag> [link](url)", nil)])
        ]
        for fixture in fixtures {
            try check(fixture)
            // The same lexer serves native reading and the split preview.
            try check(fixture, isSecondary: true)
            // 快照重放与即时着色接受同一组逐码元颜色断言，覆盖重叠样式的优先级。
            try check(fixture, useSnapshot: true)
        }
        return fixtures.count * 3 + (try clippedMultilineTokens()) + (try boundedWork()) + (try snapshotBounds())
    }

    private static func snapshotBounds() throws -> Int {
        for source in [String(repeating: "x", count: 200_000), String(repeating: "中", count: 66_667)] {
            guard SourceHighlighting.snapshot(in: source, kind: .json) == nil else {
                throw SmokeCheck.Failure(message: "达到字节上限的正文仍生成了高亮快照")
            }
        }
        let source = "{\"key\":true}"
        var emitted = false
        let completed = SourceHighlighting.enumerate(in: source, kind: .json,
            ranges: [NSRange(location: 0, length: source.utf16.count)], timeBudget: 0) { _, _ in
                emitted = true
            }
        guard !completed, !emitted else {
            throw SmokeCheck.Failure(message: "零预算的高亮扫描未及时停止或被误报为完成")
        }
        return 3
    }

    private static func clippedMultilineTokens() throws -> Int {
        let fixtures: [(String, String, String, SourceHighlighting.Style?)] = [
            ("sample.jsonc", "/* start\ntrue 2.6\nend */", "true 2.6", .comment),
            ("sample.xml", "<root value=\"first\ntrue 2.6\nlast\"/>", "true 2.6", .string),
            ("raw.xml", "<![CDATA[\ntrue 2.6\n]]>", "true 2.6", .string),
            ("sample.yaml", "value: |\n  true 2.6\nnext: false\n", "  true 2.6", .string),
            ("quoted.yaml", "value: 'first\ntrue 2.6\nlast'\n", "true 2.6", .string),
            ("sample.toml", "value = \"\"\"first\ntrue 2.6\nlast\"\"\"\n", "true 2.6", .string),
            (".env", "VALUE='first\ntrue 2.6\nlast'\n", "true 2.6", .string),
            ("sample.md", "```text\n[link](url)\n```\n", "[link](url)", .code)
        ]
        for (name, source, token, expected) in fixtures {
            let range = (source as NSString).range(of: token)
            var styles = [SourceHighlighting.Style?](repeating: nil, count: range.length)
            var escapedRange = false
            SourceHighlighting.enumerate(in: source, kind: DocumentKind(url: URL(fileURLWithPath: name)), ranges: [range]) { part, style in
                guard NSIntersectionRange(part, range) == part else { escapedRange = true; return }
                for index in part.location..<NSMaxRange(part) { styles[index - range.location] = style }
            }
            guard !escapedRange, styles.allSatisfy({ $0 == expected }) else {
                throw SmokeCheck.Failure(message: "滚动后的多行内容丢失语法上下文：\(name)")
            }
        }
        return fixtures.count
    }

    private static func boundedWork() throws -> Int {
        let fixtures: [(String, String)] = [
            ("long.jsonc", "/* " + String(repeating: "*\" true ", count: 12_000)),
            ("field.json", "{\"field\"\n" + String(repeating: " ", count: 100_000) + ": 0}"),
            ("field.jsonc", "{\"field\"\n/*" + String(repeating: " : \"ignored\" ", count: 8_000) + "*/\n: 0}"),
            ("long.xml", "<root " + String(repeating: "a='x\" ", count: 15_000)),
            ("long.yaml", "value: |\n  " + String(repeating: "[\" # true ", count: 12_000)),
            ("long.toml", "value = \"\"\"" + String(repeating: "\\\" # true ", count: 12_000)),
            (".env", "VALUE=\"" + String(repeating: "\\\" # true ", count: 12_000)),
            ("long.md", "text " + String(repeating: "````````````````x`[", count: 6_000))
        ]
        for (name, prefix) in fixtures {
            let source = (prefix + "\nnext = true\n") as NSString
            let ranges = SourceHighlighting.boundedLineRanges(in: source, range: NSRange(location: 0, length: source.length))
            let start = ProcessInfo.processInfo.systemUptime
            SourceHighlighting.enumerate(in: source as String, kind: DocumentKind(url: URL(fileURLWithPath: name)), ranges: ranges) { _, _ in }
            guard ProcessInfo.processInfo.systemUptime - start < 0.5 else {
                throw SmokeCheck.Failure(message: "未闭合的长内容阻塞高亮：\(name)")
            }
        }
        return fixtures.count
    }

    static func capture(directory: URL) async throws {
        let defaults = UserDefaults.standard
        let savedAppearance = defaults.object(forKey: "appearance")
        let savedAppAppearance = NSApp.appearance
        defer {
            if let savedAppearance { defaults.set(savedAppearance, forKey: "appearance") }
            else { defaults.removeObject(forKey: "appearance") }
            NSApp.appearance = savedAppAppearance
        }
        let samples: [(String, String, CGFloat)] = [
            ("json", "{\n  \"model\": \"gpt-image-2.6-sunburst\",\n  \"text\": \"中文📝 true false null 42\",\n  \"url\": \"https://example.com/#part\",\n  \"count\": -2.6e+10,\n  \"enabled\": true\n}\n", 390),
            ("yaml", "# 配置高亮示例：仅使用专用测试数据\nmixed-port: 7890\nallow-lan: false\nmode: rule\nlog-level: warning\ndns:\n  enable: true\n  enhanced-mode: fake-ip\n  fake-ip-range: 198.18.0.1/16\n  default-nameserver: [192.0.2.1, 198.51.100.2]\n  nameserver: [\"https://example.com/dns-query\"]\nproxies:\n  - name: 示例节点\n    type: hysteria2\n    server: 203.0.113.10\n    port: 443\n    alpn: [h3]\nrules:\n  - DOMAIN-SUFFIX,example.com,DIRECT\n", 650),
            ("xml", "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!-- 配置高亮示例 -->\n<configuration mode=\"rule\">\n  <name>示例配置</name>\n  <server>203.0.113.10</server>\n  <url>https://example.com/?a=1&amp;b=2</url>\n  <message>普通正文与 \"带引号的文字\"</message>\n  <data><![CDATA[原始文本 <tag> true 42]]></data>\n</configuration>\n", 430)
        ]
        for (kind, source, height) in samples {
            let file = directory.appendingPathComponent("highlighting.\(kind)")
            try Data(source.utf8).write(to: file)
            let document = MarkdownDocument(snapshot: try FileSnapshot(data: Data(source.utf8)), url: file)
            document.session.mode = kind == "json" ? .edit : .read
            document.makeWindowControllers(); document.showWindows()
            defer { document.close() }
            guard let window = document.windowControllers.first?.window else { throw CocoaError(.coderInvalidValue) }
            window.setContentSize(NSSize(width: 940, height: height))
            window.center()
            for (appearance, name) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                defaults.set(name, forKey: "appearance")
                NSApp.appearance = NSAppearance(named: appearance)
                window.appearance = NSAppearance(named: appearance)
                try await Task.sleep(for: .milliseconds(250))
                guard window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == appearance else {
                    throw SmokeCheck.Failure(message: "高亮截图未应用指定外观：\(name)")
                }
                let suffix = kind == "json" ? name : "\(kind)-\(name)"
                try await ScreenshotCapture.capture(window, to: directory.appendingPathComponent("highlighting-\(suffix).png"))
            }
        }
    }

    private static func check(_ fixture: Fixture, isSecondary: Bool = false, useSnapshot: Bool = false) throws {
        let document = MarkdownDocument(snapshot: try FileSnapshot(data: Data(fixture.source.utf8)),
            url: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(fixture.name))
        defer { document.close() }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        let text = NSTextView(frame: scroll.bounds)
        text.isRichText = false
        text.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        text.textContainer?.containerSize = NSSize(width: 900, height: CGFloat.greatestFiniteMagnitude)
        text.string = fixture.source
        scroll.documentView = text
        let coordinator = SourceEditor.Coordinator(session: document.session, isSecondary: isSecondary)
        defer { coordinator.invalidateHighlighting() }
        coordinator.textView = text
        text.layoutManager?.ensureLayout(for: text.textContainer!)
        let original = NSAttributedString(attributedString: text.textStorage!)
        if useSnapshot {
            guard let snapshot = SourceHighlighting.snapshot(in: fixture.source, kind: document.session.kind) else {
                throw SmokeCheck.Failure(message: "短文档未能生成完整高亮快照：\(fixture.name)")
            }
            let entire = NSRange(location: 0, length: text.textStorage!.length)
            for token in snapshot {
                guard token.range.length > 0, NSIntersectionRange(token.range, entire) == token.range else {
                    throw SmokeCheck.Failure(message: "高亮快照包含越界或空范围：\(fixture.name)")
                }
                let color: NSColor
                switch token.style {
                case .key: color = .systemGreen
                case .string, .heading: color = .systemBlue
                case .literal: color = .systemPurple
                case .comment: color = .secondaryLabelColor
                case .code: color = .systemOrange
                case .link: color = .systemTeal
                }
                text.layoutManager?.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: token.range)
            }
        } else {
            coordinator.highlight()
        }
        func checkToken(_ token: String, _ expected: NSColor?, options: NSString.CompareOptions = []) throws {
            let range = (text.string as NSString).range(of: token, options: options)
            guard range.location != NSNotFound else { throw SmokeCheck.Failure(message: "高亮测试缺少样例：\(fixture.name) \(token)") }
            for index in range.location..<NSMaxRange(range) {
                let actual = text.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: index, effectiveRange: nil) as? NSColor
                guard actual == expected else {
                    throw SmokeCheck.Failure(message: "\(useSnapshot ? "快照" : "即时")高亮颜色不符：\(fixture.name)，\(token)，位置 \(index)，实际 \(String(describing: actual))，预期 \(String(describing: expected))")
                }
            }
        }
        for (token, expected) in fixture.expected { try checkToken(token, expected) }
        for (token, expected) in fixture.lastExpected { try checkToken(token, expected, options: .backwards) }
        guard text.string == fixture.source, !document.session.state.isDirty,
              text.textStorage?.isEqual(to: original) == true else {
            throw SmokeCheck.Failure(message: "高亮修改了正文、保存状态或持久文字属性：\(fixture.name)")
        }
    }
}
#endif
