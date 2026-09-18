import AppKit

/// 空单元格会不会把整列挤掉。
@main @MainActor enum TableProbe2 {
    static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        Task { @MainActor in
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mdql-table-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let cases: [(String, String)] = [
                ("表头首格为空", "| | A | B |\n|---|---|---|\n| 行 | 1 | 2 |\n"),
                ("表头末格为空", "| A | B | |\n|---|---|---|\n| 1 | 2 | 行 |\n"),
                ("正文中间为空", "| A | B | C |\n|---|---|---|\n| 1 | | 3 |\n"),
                ("正文首格为空", "| A | B | C |\n|---|---|---|\n| | 2 | 3 |\n"),
                ("全满", "| A | B | C |\n|---|---|---|\n| 1 | 2 | 3 |\n"),
            ]
            for (label, markdown) in cases {
                let url = dir.appendingPathComponent("\(label).md")
                try? markdown.write(to: url, atomically: true, encoding: .utf8)
                guard let document = MarkdownRenderer.render(contentsOf: url) else { print("\(label): 渲染失败"); continue }
                // 统计每一行实际排出了几个单元格
                var rows: [Int: [Int]] = [:]
                document.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: document.length)) { value, _, _ in
                    guard let style = value as? NSParagraphStyle,
                          let block = style.textBlocks.last as? NSTextTableBlock else { return }
                    rows[block.startingRow, default: []].append(block.startingColumn)
                }
                let shape = rows.sorted { $0.key < $1.key }
                    .map { "行\($0.key)=\($0.value.sorted().map(String.init).joined(separator: ","))" }
                print("\(label): \(shape.joined(separator: "  "))")
            }
            try? FileManager.default.removeItem(at: dir)
            exit(0)
        }
        NSApplication.shared.run()
    }
}
