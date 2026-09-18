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
        // 必须含反斜杠命令才算公式：shell 的 `$HOME`、JSON 的 `$ref` 一行里也有两个 $，
        // 不加这条判据的话它们会永远报假阳，把真问题淹掉
        .init(label: "未渲染公式", pattern: rx(#"\$\$?[^$\n]*\\[a-zA-Z]+[^$\n]*\$\$?"#),
              source: rx(#"\$\$?[^$\n]*\\[a-zA-Z]+[^$\n]*\$\$?"#)),
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
        var inputs = Array(CommandLine.arguments.dropFirst())
        // 几万份文件塞不进 argv，也不该逐份刷屏。给一个清单文件走安静模式：
        // 只报问题和最慢的几份，其余只累计。
        var quiet = false
        if inputs.first == "--list", inputs.count > 1,
           let listing = try? String(contentsOfFile: inputs[1], encoding: .utf8) {
            inputs = listing.split(separator: "\n").map(String.init)
            quiet = true
        }
        NSApplication.shared.setActivationPolicy(.accessory)
        Task { @MainActor in
            var failures = 0, dirty = 0, unreadable = 0, gated = 0
            var total = 0.0
            var timings: [(String, Double)] = []
            var started = CFAbsoluteTimeGetCurrent()
            let scroll = MarkdownScrollView(frame: NSRect(x: 0, y: 0, width: 900, height: 800))
            if !quiet { print(pad("文件", 36) + pad("KB", 8) + pad("ms", 9) + pad("附件", 6) + "残留") }
            for path in inputs {
                let url = URL(fileURLWithPath: path)
                let name = url.lastPathComponent
                let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                guard let source = try? String(contentsOf: url, encoding: .utf8) else {
                    // UTF-8 解不开的多半根本不是 Markdown（二进制、别的编码），不算渲染失败
                    unreadable += 1; continue
                }
                let began = CFAbsoluteTimeGetCurrent()
                guard let document = MarkdownRenderer.render(contentsOf: url) else {
                    // 超过 512KiB 的尺寸闸是设计行为，退回纯文本；不是失败
                    if bytes > MarkdownRenderer.sourceLimit { gated += 1 } else {
                        print("渲染返回 nil: \(url.path)"); failures += 1
                    }
                    continue
                }
                // 排一屏，把排版阶段的崩溃也覆盖进来
                scroll.setDocument(document)
                scroll.layoutSubtreeIfNeeded()
                let elapsed = (CFAbsoluteTimeGetCurrent() - began) * 1000
                total += elapsed
                timings.append((url.path, elapsed))

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
                if !notes.isEmpty {
                    dirty += 1
                    print("残留 \(notes.joined(separator: " ")): \(url.path)")
                    fflush(stdout)
                }
                if !quiet {
                    print(pad(name, 36) + pad(String(bytes / 1024), 8)
                          + pad(String(format: "%.1f", elapsed), 9) + pad(String(attachments), 6)
                          + (notes.isEmpty ? "—" : notes.joined(separator: " ")))
                    fflush(stdout)
                } else if timings.count % 5000 == 0 {
                    let wall = CFAbsoluteTimeGetCurrent() - started
                    print(String(format: "  …已扫 %d 份，用时 %.0fs", timings.count, wall))
                    fflush(stdout)
                }
            }
            print("")
            print("共 \(inputs.count) 份：渲染 \(timings.count)，失败 \(failures)，"
                  + "有残留 \(dirty)，超尺寸闸 \(gated)，非 UTF-8 \(unreadable)")
            print(String(format: "合计 %.1fs，平均 %.1fms", total / 1000, total / Double(max(timings.count, 1))))
            let ranked = timings.sorted { $0.1 > $1.1 }
            print("最慢 10 份：")
            for (path, ms) in ranked.prefix(10) { print(String(format: "  %8.1fms  %@", ms, path)) }
            if timings.count > 20 {
                let sorted = timings.map(\.1).sorted()
                print(String(format: "分位：中位 %.1fms  p90 %.1fms  p99 %.1fms",
                             sorted[sorted.count / 2], sorted[Int(Double(sorted.count) * 0.9)],
                             sorted[Int(Double(sorted.count) * 0.99)]))
            }
            exit(failures == 0 ? 0 : 1)
        }
        NSApplication.shared.run()
    }
}
