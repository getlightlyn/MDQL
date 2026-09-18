import AppKit

@main @MainActor enum EmojiProbe {
    static func main() {
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        NSApplication.shared.setActivationPolicy(.accessory)
        Task { @MainActor in
            guard let document = MarkdownRenderer.render(contentsOf: url) else { print("FAIL"); exit(1) }
            let source = document.string as NSString
            var seen = Set<String>()
            document.enumerateAttribute(.font, in: NSRange(location: 0, length: document.length)) { value, range, _ in
                let text = source.substring(with: range)
                guard text.unicodeScalars.contains(where: { $0.properties.isEmoji && $0.value > 0x238C }) else { return }
                let font = (value as? NSFont)
                let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty, seen.insert(key).inserted else { return }
                print("emoji \(key)  字体=\(font?.fontName ?? "nil")  字号=\(font?.pointSize ?? -1)")
            }
            // 正文字号做参照
            if let body = document.attribute(.font, at: 0, effectiveRange: nil) as? NSFont {
                print("首字符字体=\(body.fontName) 字号=\(body.pointSize)")
            }
            var bodySize: CGFloat = 0
            document.enumerateAttribute(.font, in: NSRange(location: 0, length: document.length)) { value, range, _ in
                if let font = value as? NSFont, range.length > 8, bodySize == 0 { bodySize = font.pointSize }
            }
            print("正文字号参照=\(bodySize)")
            exit(0)
        }
        NSApplication.shared.run()
    }
}
