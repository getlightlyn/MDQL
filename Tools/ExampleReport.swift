import AppKit

/// 逐个文档报告：图片有没有排出来、图片那一行的行高是不是被撑高了。
@main @MainActor enum ExampleReport {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        NSApplication.shared.setActivationPolicy(.accessory)
        Task { @MainActor in
            for path in args {
                let url = URL(fileURLWithPath: path)
                guard let source = try? String(contentsOf: url, encoding: .utf8),
                      let document = MarkdownRenderer.render(contentsOf: url) else {
                    print("FAIL \(url.lastPathComponent) 渲染不出来"); continue
                }
                let pattern = try! NSRegularExpression(pattern: #"!\[[^\]]*\]\([^)]*\)"#)
                let written = pattern.numberOfMatches(in: source, range: NSRange(location: 0, length: (source as NSString).length))
                var attachments = 0, tallest = CGSize.zero
                document.enumerateAttribute(.attachment, in: NSRange(location: 0, length: document.length)) { value, _, _ in
                    guard let cell = (value as? NSTextAttachment)?.attachmentCell else { return }
                    attachments += 1
                    if cell.cellSize().height > tallest.height { tallest = cell.cellSize() }
                }
                // 把图片那一行真正排出来，看行片段比图片高多少
                let scroll = MarkdownScrollView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
                scroll.setDocument(document)
                scroll.layoutSubtreeIfNeeded()
                var inflation = "—"
                let views = sequence(first: [scroll as NSView]) { level in
                    let next = level.flatMap(\.subviews); return next.isEmpty ? nil : next
                }.flatMap { $0 }
                if tallest.height > 0, let text = views.compactMap({ $0 as? NSTextView }).first,
                   let layout = text.layoutManager, let container = text.textContainer {
                    layout.ensureLayout(for: container)
                    var lines: [String] = []
                    document.enumerateAttribute(.attachment, in: NSRange(location: 0, length: document.length)) { value, range, _ in
                        guard let cell = (value as? NSTextAttachment)?.attachmentCell, cell.cellSize().height > 40 else { return }
                        let glyph = layout.glyphIndexForCharacter(at: range.location)
                        let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                        // cellFrame 才是排版真正用的尺寸（按栏宽缩放过）
                        let drawn = cell.cellFrame(for: container, proposedLineFragment: fragment,
                                                   glyphPosition: .zero, characterIndex: range.location)
                        lines.append(String(format: "原图 %.0f → 画 %.0f，行片段 %.0f（空出 %.0fpt）",
                                            cell.cellSize().height, drawn.height, fragment.height,
                                            fragment.height - drawn.height))
                    }
                    inflation = lines.joined(separator: " | ")
                }
                print("\(url.lastPathComponent): 源码 \(written) 张图 → 排出 \(attachments) 个附件；\(inflation)")
                fflush(stdout)
            }
            exit(0)
        }
        NSApplication.shared.run()
    }
}
