import AppKit

extension NSAttributedString.Key {
    /// 脚注正文的锚点，点上标时用来定位
    static let footnoteIndex = NSAttributedString.Key("LightlynFootnoteIndex")
}

/// 脚注（`正文[^1]。` + `[^1]: 脚注内容。`）。
///
/// CommonMark 没有脚注，Foundation 也没有——更麻烦的是它**不会原样留着**：
/// `[^1]` 碰上同名的定义行会被当成链接引用，渲染成一个指向「脚注正文」这串字的链接，
/// 定义行本身则整个消失。读者看到的是一个点不动的 `^1`，正文不知去向。
///
/// 所以在交给解析器之前先把脚注摘出来：定义行从原位置删掉、引用换成记号，
/// 正文改写成文末的一条分隔线加一个有序列表——**让解析器用它本来就会的语法去排**，
/// 我们只负责把记号还原成上标序号。编号按**首次引用**的先后，和 GitHub 一致。
enum MarkdownFootnotes {
    struct Note {
        let identifier: String
        var lines: [String]
    }

    struct Prepared {
        let markdown: String
        let reference: NSRegularExpression?
        let definition: NSRegularExpression?

        /// 把记号换成上标序号 / 给正文打上锚点
        func restore(in text: NSMutableAttributedString, codeBlock: Bool) {
            guard let reference, let definition else { return }
            let whole = { NSRange(location: 0, length: text.length) }
            for match in definition.matches(in: text.string, range: whole()).reversed() {
                guard let index = Int((text.string as NSString).substring(with: match.range(at: 1))) else { continue }
                text.replaceCharacters(in: match.range, with: "")
                // 锚点落在正文第一个字上；空正文时退到段末，至少还能定位到这一段
                let anchor = min(match.range.location, max(0, text.length - 1))
                if text.length > 0 {
                    text.addAttribute(.footnoteIndex, value: index, range: NSRange(location: anchor, length: 1))
                }
            }
            guard !codeBlock else { return }
            for match in reference.matches(in: text.string, range: whole()).reversed() {
                let source = text.string as NSString
                guard let index = Int(source.substring(with: match.range(at: 1))) else { continue }
                var attributes = text.attributes(at: match.range.location, effectiveRange: nil)
                let intent = (attributes[.inlinePresentationIntent] as? UInt).map(InlinePresentationIntent.init(rawValue:))
                guard intent?.contains(.code) != true else { continue }
                let font = (attributes[.font] as? NSFont) ?? .systemFont(ofSize: 16)
                attributes[.font] = NSFont(descriptor: font.fontDescriptor, size: font.pointSize * 0.72) ?? font
                attributes[.baselineOffset] = font.pointSize * 0.34
                attributes[.foregroundColor] = NSColor.linkColor
                attributes[.link] = URL(string: "\(MarkdownFootnotes.scheme):\(index)")
                text.replaceCharacters(in: match.range,
                                       with: NSAttributedString(string: String(index), attributes: attributes))
            }
        }
    }

    /// 上标点击用的自定义 scheme；不走系统打开，由预览视图自己拦下来滚动
    static let scheme = "lightlyn-footnote"

    private static let definitionLine = try! NSRegularExpression(
        pattern: #"^ {0,3}\[\^([^\]\s]+)\]:[ \t]*(.*)$"#)
    private static let referenceToken = try! NSRegularExpression(pattern: #"\[\^([^\]\s]+)\]"#)

    static func prepare(_ source: String) -> Prepared {
        let prefix = "LMFootnote" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        // NSString 的查找走 CFStringFind，比 Swift String 的字素簇比较便宜得多
        guard (source as NSString).range(of: "[^").location != NSNotFound else {
            return Prepared(markdown: source, reference: nil, definition: nil)
        }

        // ---- 一、逐行扫出定义，顺手把定义行从正文里摘掉 ----
        var body: [String] = []
        var notes: [String: Note] = [:]
        var order: [String] = []
        var fence: (marker: Character, count: Int)?
        var collecting: String?

        for line in source.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // 围栏代码块里的一切原样保留
            if let open = fence {
                body.append(line)
                if trimmed.first == open.marker, trimmed.count >= open.count,
                   trimmed.allSatisfy({ $0 == open.marker }) { fence = nil }
                continue
            }
            if let first = trimmed.first, first == "`" || first == "~" {
                let run = trimmed.prefix { $0 == first }.count
                if run >= 3 { fence = (first, run); body.append(line); collecting = nil; continue }
            }
            let range = NSRange(location: 0, length: (line as NSString).length)
            if let match = definitionLine.firstMatch(in: line, range: range) {
                let text = line as NSString
                let identifier = text.substring(with: match.range(at: 1))
                let first = text.substring(with: match.range(at: 2))
                if notes[identifier] == nil {
                    notes[identifier] = Note(identifier: identifier, lines: [first])
                    order.append(identifier)
                }
                collecting = identifier
                continue
            }
            // 缩进的续行属于上一条定义；空行先记着，后面还有缩进行才算数
            if let current = collecting {
                if trimmed.isEmpty {
                    notes[current]?.lines.append("")
                    continue
                }
                if line.hasPrefix("    ") || line.hasPrefix("\t") {
                    notes[current]?.lines.append(trimmed)
                    continue
                }
                // 定义结束；前面暂记的空行还给正文
                while notes[current]?.lines.last == "" { notes[current]?.lines.removeLast() }
                collecting = nil
            }
            body.append(line)
        }
        if let current = collecting {
            while notes[current]?.lines.last == "" { notes[current]?.lines.removeLast() }
        }
        guard !notes.isEmpty else {
            return Prepared(markdown: source, reference: nil, definition: nil)
        }

        // ---- 二、引用换成记号，编号按首次引用 ----
        var numbers: [String: Int] = [:]
        var referenced: [String] = []
        var rewritten: [String] = []
        fence = nil
        for line in body {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let open = fence {
                rewritten.append(line)
                if trimmed.first == open.marker, trimmed.count >= open.count,
                   trimmed.allSatisfy({ $0 == open.marker }) { fence = nil }
                continue
            }
            if let first = trimmed.first, first == "`" || first == "~" {
                let run = trimmed.prefix { $0 == first }.count
                if run >= 3 { fence = (first, run); rewritten.append(line); continue }
            }
            let text = line as NSString
            var result = line
            for match in referenceToken.matches(in: line, range: NSRange(location: 0, length: text.length)).reversed() {
                let identifier = text.substring(with: match.range(at: 1))
                guard notes[identifier] != nil, !inlineCode(line, at: match.range.location) else { continue }
                let number: Int
                if let existing = numbers[identifier] { number = existing }
                else {
                    number = numbers.count + 1
                    numbers[identifier] = number
                    referenced.append(identifier)
                }
                result = (result as NSString).replacingCharacters(in: match.range, with: "\(prefix)R\(number)Z")
            }
            rewritten.append(result)
        }

        // 只定义没引用的也列出来，排在被引用的后面；不静默丢掉作者写下的内容
        var listed = referenced
        for identifier in order where numbers[identifier] == nil {
            numbers[identifier] = numbers.count + 1
            listed.append(identifier)
        }
        guard !listed.isEmpty else {
            return Prepared(markdown: source, reference: nil, definition: nil)
        }

        // ---- 三、把定义接到文末，用解析器本来就认的有序列表排 ----
        var tail = ["", "---", ""]
        for identifier in listed {
            guard let note = notes[identifier], let number = numbers[identifier] else { continue }
            let lines = note.lines
            let head = lines.first ?? ""
            tail.append("\(number). \(prefix)D\(number)Z\(head)")
            // 续行缩进四格，仍然属于同一个列表项
            for line in lines.dropFirst() { tail.append(line.isEmpty ? "" : "    " + line) }
            tail.append("")
        }

        return Prepared(markdown: (rewritten + tail).joined(separator: "\n"),
                        reference: try? NSRegularExpression(pattern: prefix + #"R([0-9]+)Z"#),
                        definition: try? NSRegularExpression(pattern: prefix + #"D([0-9]+)Z"#))
    }

    /// 行内 `code` 里的 `[^1]` 是内容，不是引用。按 UTF-16 数反引号，和 NSRange 同坐标。
    private static func inlineCode(_ line: String, at offset: Int) -> Bool {
        let text = line as NSString
        var ticks = 0, index = 0
        while index < offset, index < text.length {
            if text.character(at: index) == 0x60 { ticks += 1 }
            index += 1
        }
        return ticks % 2 == 1
    }
}
