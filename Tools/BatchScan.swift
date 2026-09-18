import AppKit

/// 批量扫真实文档。
///
/// 不崩、不返回 nil 只是底线。真正要抓的是**渲染不干净的痕迹**：
/// 排完之后正文里还剩 `<tag>`、`[^1]`、`:smile:`、`$...$`、`\command`，
/// 就说明那条语法我们没接住，只是没报错而已——这种失败不会自己喊出来。
@main @MainActor enum BatchScan {
    struct Leftover {
        let label: String
        let pattern: NSRegularExpression
        /// 源码里本来就有才算数，避免把「文档里根本没这语法」当成通过
        let source: NSRegularExpression
    }

    static func rx(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }

    static let checks: [Leftover] = [
        .init(label: "HTML 标签", pattern: rx(#"</?[a-zA-Z][a-zA-Z0-9]*(\s[^<>\n]{0,80})?/?>"#),
              source: rx(#"</?[a-zA-Z][a-zA-Z0-9]*(\s[^<>\n]{0,80})?/?>"#)),
        .init(label: "脚注引用", pattern: rx(#"\[\^[^\]\s]+\]"#), source: rx(#"\[\^[^\]\s]+\]"#)),
        .init(label: "emoji 短码", pattern: rx(#":[a-z0-9_+-]{2,30}:"#), source: rx(#":[a-z0-9_+-]{2,30}:"#)),
        .init(label: "未渲染公式", pattern: rx(#"\$\$?[^$\n]{2,}\$\$?"#), source: rx(#"\$\$?[^$\n]{2,}\$\$?"#)),
        .init(label: "裸 LaTeX 命令", pattern: rx(#"\\(frac|sum|int|alpha|beta|operatorname|mathrm|left|right)\b"#),
              source: rx(#"\\(frac|sum|int|alpha|beta|operatorname|mathrm|left|right)\b"#)),
        .init(label: "Markdown 图片语法", pattern: rx(#"!\[[^\]]*\]\([^)]+\)"#), source: rx(#"!\[[^\]]*\]\([^)]+\)"#)),
        .init(label: "Markdown 链接语法", pattern: rx(#"(?<!!)\[[^\]\n]+\]\([^)\s]+\)"#),
              source: rx(#"(?<!!)\[[^\]\n]+\]\([^)\s]+\)"#)),
    ]

    /// String(format:) 的 %s 是 C 字符串占位符，喂 Swift String 会静默出事，
    /// 所以列宽自己补空格
    static func pad(_ text: String, _ width: Int) -> String {
        let visible = text.count
        return visible >= width ? text : text + String(repeating: " ", count: width - visible)
    }

    static func count(_ regex: NSRegularExpression, _ text: String) -> Int {
        regex.numberOfMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    }

    /// 排完之后仍然匹配、**且不在代码里**的次数。
    /// 代码块和行内代码里的 `$VAR`、`<div>`、`:key:` 本来就该原样保留，
    /// 把它们算成残留的话，真正的问题会被淹在误报里。
    /// 判据是字体：渲染器给代码用的是 monospacedSystemFont。
    static func countOutsideCode(_ regex: NSRegularExpression, in document: NSAttributedString) -> Int {
        let text = document.string
        var hits = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) {
            guard match.range.location < document.length else { continue }
            let font = document.attribute(.font, at: match.range.location, effectiveRange: nil) as? NSFont
            if font?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true { continue }
            hits += 1
        }
        return hits
    }

    static func main() {
        let inputs = Array(CommandLine.arguments.dropFirst())
        NSApplication.shared.setActivationPolicy(.accessory)
        Task { @MainActor in
            var failures = 0, dirty = 0, slowest: (String, Double) = ("", 0)
            var total = 0.0
            let scroll = MarkdownScrollView(frame: NSRect(x: 0, y: 0, width: 900, height: 800))
            print(pad("文件", 36) + pad("KB", 8) + pad("ms", 9) + pad("附件", 6) + "残留")
            for path in inputs {
                let url = URL(fileURLWithPath: path)
                let name = url.lastPathComponent
                let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                guard let source = try? String(contentsOf: url, encoding: .utf8) else {
                    print("\(name): 读不出来"); failures += 1; continue
                }
                let started = CFAbsoluteTimeGetCurrent()
                guard let document = MarkdownRenderer.render(contentsOf: url) else {
                    print(pad(name, 36) + pad(String(bytes / 1024), 8) + "渲染返回 nil（超过 512KiB 闸？）")
                    failures += 1; continue
                }
                // 排一屏，把排版阶段的崩溃也覆盖进来
                scroll.setDocument(document)
                scroll.layoutSubtreeIfNeeded()
                let elapsed = (CFAbsoluteTimeGetCurrent() - started) * 1000
                total += elapsed
                if elapsed > slowest.1 { slowest = (name, elapsed) }

                var attachments = 0
                document.enumerateAttribute(.attachment, in: NSRange(location: 0, length: document.length)) { value, _, _ in
                    if value != nil { attachments += 1 }
                }
                var notes: [String] = []
                for check in checks {
                    let before = count(check.source, source)
                    let after = countOutsideCode(check.pattern, in: document)
                    if before > 0, after > 0 { notes.append("\(check.label)×\(after)") }
                }
                if !notes.isEmpty { dirty += 1 }
                print(pad(name, 36) + pad(String(bytes / 1024), 8)
                      + pad(String(format: "%.1f", elapsed), 9) + pad(String(attachments), 6)
                      + (notes.isEmpty ? "—" : notes.joined(separator: " ")))
                fflush(stdout)
            }
            print("")
            print("共 \(inputs.count) 份：渲染失败 \(failures)，有残留 \(dirty)")
            print(String(format: "合计 %.0fms，平均 %.1fms，最慢 %@ %.1fms",
                         total, total / Double(max(inputs.count - failures, 1)), slowest.0, slowest.1))
            exit(failures == 0 ? 0 : 1)
        }
        NSApplication.shared.run()
    }
}
