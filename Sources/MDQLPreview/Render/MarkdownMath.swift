import AppKit
import SwiftMath

extension NSAttributedString.Key {
    static let formulaSource = NSAttributedString.Key("LightlynFormulaSource")
}

/// Math is an opaque inline/block extension of the shared Markdown renderer.
/// Protect TeX before CommonMark can consume its backslashes, underscores or stars.
enum MarkdownMath {
    struct Formula {
        let source: String
        let latex: String
        let display: Bool
    }
    struct Prepared {
        let markdown: String
        let formulas: [Formula]
        let marker: NSRegularExpression

        func restore(in text: NSMutableAttributedString, codeBlock: Bool) {
            guard !formulas.isEmpty else { return }
            for match in marker.matches(in: text.string, range: NSRange(location: 0, length: text.length)).reversed() {
                guard let index = Int((text.string as NSString).substring(with: match.range(at: 1))), formulas.indices.contains(index) else { continue }
                let formula = formulas[index], attributes = text.attributes(at: match.range.location, effectiveRange: nil)
                let inline = (attributes[.inlinePresentationIntent] as? UInt).map(InlinePresentationIntent.init(rawValue:))
                let fontSize = (attributes[.font] as? NSFont)?.pointSize ?? 16
                guard !codeBlock, inline?.contains(.code) != true, attributes[.link] == nil,
                      let rendered = MarkdownMath.image(formula, size: fontSize), let image = rendered.image else {
                    text.replaceCharacters(in: match.range, with: NSAttributedString(string: formula.source, attributes: attributes)); continue
                }
                let attachment = NSTextAttachment()
                let cell = MarkdownRenderer.MarkdownImageCell(imageCell: image)
                cell.baseline = rendered.descent
                cell.setAccessibilityLabel(formula.latex)
                attachment.attachmentCell = cell
                let replacement = NSMutableAttributedString(attachment: attachment)
                replacement.addAttributes(attributes, range: NSRange(location: 0, length: 1))
                replacement.addAttribute(.formulaSource, value: formula.source, range: NSRange(location: 0, length: 1))
                if formula.display {
                    let source = text.string as NSString
                    let afterMarker = source.substring(to: match.range.location)
                        .range(of: #"^(?:\d+\.|[●○▪☐☑])\t$"#, options: .regularExpression) != nil
                    let paragraph = (attributes[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
                    if !afterMarker {
                        paragraph.alignment = .center
                        paragraph.firstLineHeadIndent = paragraph.headIndent
                    }
                    replacement.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: 1))
                    if NSMaxRange(match.range) < source.length, source.character(at: NSMaxRange(match.range)) != 10 {
                        replacement.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: paragraph]))
                    }
                    if !afterMarker, match.range.location > 0, source.character(at: match.range.location - 1) != 10 {
                        replacement.insert(NSAttributedString(string: "\n", attributes: attributes), at: 0)
                    }
                }
                text.replaceCharacters(in: match.range, with: replacement)
            }
        }
    }

    static func prepare(_ source: String) -> Prepared {
        let text = source as NSString, units = Array(source.utf16)
        let prefix = "LMFormula" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var formulas: [Formula] = [], replacements: [(NSRange, String)] = []
        var position = 0
        func escaped(_ offset: Int) -> Bool {
            var start = offset
            while start > 0, units[start - 1] == 92 { start -= 1 }
            return (offset - start) % 2 == 1
        }
        func linePrefix(_ offset: Int) -> String {
            let start = text.lineRange(for: NSRange(location: offset, length: 0)).location
            return text.substring(with: NSRange(location: start, length: offset - start))
        }
        func runLength(_ offset: Int) -> Int {
            var end = offset + 1
            while end < units.count, units[end] == units[offset] { end += 1 }
            return end - offset
        }
        while position < units.count, formulas.count < 256 {
            let char = units[position]
            // Fenced and inline code retain their exact original source.
            if char == 96 || char == 126 {
                let count = runLength(position)
                let fence = count >= 3 && linePrefix(position).allSatisfy { $0.isWhitespace || $0 == ">" }
                if char == 96 || fence {
                    var end = position + count, found = false
                    while end < units.count {
                        if units[end] == char {
                            let length = runLength(end)
                            if (fence ? length >= count : length == count), !fence || linePrefix(end).allSatisfy({ $0.isWhitespace || $0 == ">" }) {
                                position = end + length; found = true; break
                            }
                            end += length
                        } else { end += 1 }
                    }
                    if found { continue }
                    if fence { break }
                }
                position += count; continue
            }
            // Do not rewrite file names or URLs inside a Markdown link destination.
            if char == 93, position + 1 < units.count, units[position + 1] == 40 {
                var end = position + 2, depth = 1
                while end < units.count, depth > 0 {
                    if units[end] == 92 { end += 2; continue }
                    if units[end] == 40 { depth += 1 }
                    if units[end] == 41 { depth -= 1 }
                    end += 1
                }
                position = end; continue
            }
            let opener: Int, closer: [UInt16], display: Bool
            if char == 36, !escaped(position) {
                display = position + 1 < units.count && units[position + 1] == 36
                opener = display ? 2 : 1; closer = display ? [36, 36] : [36]
            } else if char == 92, position + 1 < units.count, [40, 91].contains(units[position + 1]), !escaped(position) {
                display = units[position + 1] == 91
                opener = 2; closer = [92, display ? 93 : 41]
            } else { position += char == 92 ? 2 : 1; continue }
            var end = position + opener
            let limit = min(units.count, end + 8192)
            var closing: Int?
            while end + closer.count <= limit {
                if !display, units[end] == 10 { break }
                if units[end] == closer[0], closer.count == 1 || units[end + 1] == closer[1], !escaped(end) {
                    closing = end; break
                }
                end += 1
            }
            guard let closing else {
                if display || char == 92 {
                    let stop = display ? units.count : min(text.lineRange(for: NSRange(location: position, length: 0)).upperBound, units.count)
                    let range = NSRange(location: position, length: stop - position)
                    let token = prefix + String(formulas.count) + "Z"
                    formulas.append(Formula(source: text.substring(with: range), latex: "", display: false))
                    replacements.append((range, token)); position = stop
                } else { position += opener }
                continue
            }
            let after = closing + closer.count
            // A pair of prices such as "$5 and $10" is not a math span.
            if !display, char == 36, after < units.count, (48...57).contains(units[after]) {
                position = after; continue
            }
            let range = NSRange(location: position, length: after - position)
            let latex = text.substring(with: NSRange(location: position + opener, length: closing - position - opener))
            if !latex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let token = prefix + String(formulas.count) + "Z"
                formulas.append(Formula(source: text.substring(with: range), latex: latex, display: display))
                replacements.append((range, token))
            }
            position = after
        }
        let result = NSMutableString(string: source)
        for (range, token) in replacements.reversed() { result.replaceCharacters(in: range, with: token) }
        return Prepared(markdown: result as String, formulas: formulas,
                        marker: try! NSRegularExpression(pattern: prefix + "([0-9]+)Z"))
    }

    private final class Rendered {
        let image: NSImage?
        let descent: CGFloat
        init(image: NSImage?, descent: CGFloat = 0) { self.image = image; self.descent = descent }
    }
    private static let cache: NSCache<NSString, Rendered> = {
        let cache = NSCache<NSString, Rendered>(); cache.countLimit = 256; cache.totalCostLimit = 16 * 1024 * 1024
        return cache
    }()
    /// SwiftMath 认的是 iosMath 那一套命令，比真 LaTeX 窄不少——
    /// «实测» 79 个常见命令里有 23 个不认，而 `\operatorname` 在真实笔记里几乎必现
    /// （`\operatorname{median}` 这种）。不处理的话整条公式退回源码，读者看到一片 `\left(\left|`。
    ///
    /// 所以在交给它之前做一层等价改写：能一一对应的换名字，换不了的**脱掉外壳保内容**——
    /// `\underbrace{x}_{n}` 至少还能读到 x，比整行 TeX 强；丢掉的只是装饰语义。
    /// 认不出的命令原样放行，让 SwiftMath 自己判断。
    private static let renames: [String: String] = [
        "operatorname": #"\mathrm"#, "mathop": #"\mathrm"#,
        "dfrac": #"\frac"#, "tfrac": #"\frac"#,
        "boldsymbol": #"\mathbf"#,
        "lVert": #"\|"#, "rVert": #"\|"#, "lvert": "|", "rvert": "|",
        "argmax": #"\mathrm{arg\,max}"#, "argmin": #"\mathrm{arg\,min}"#,
        "xrightarrow": #"\rightarrow"#, "xleftarrow": #"\leftarrow"#,
    ]

    /// 命令名 → (要读几个花括号组, 保留第几个；nil 表示整条丢掉)
    private static let unwraps: [String: (count: Int, keep: Int?)] = [
        "overbrace": (1, 0), "underbrace": (1, 0),
        "overset": (2, 1), "underset": (2, 1), "stackrel": (2, 1),
        "substack": (1, 0), "href": (2, 1),
        "phantom": (1, nil), "hphantom": (1, nil), "vphantom": (1, nil),
        "rule": (2, nil), "DeclareMathOperator": (2, nil),
    ]

    /// `\begin{align}` 这类 SwiftMath 不认，但对应的 `aligned` 认
    private static let environments = [
        "{align}": "{aligned}", "{align*}": "{aligned}",
        "{eqnarray}": "{aligned}", "{eqnarray*}": "{aligned}",
        "{gather}": "{gathered}", "{gather*}": "{gathered}",
    ]

    static func compatible(_ latex: String, depth: Int = 0) -> String {
        guard depth < 8 else { return latex }
        var source = latex
        for (from, to) in environments {
            source = source.replacingOccurrences(of: #"\begin"# + from, with: #"\begin"# + to)
            source = source.replacingOccurrences(of: #"\end"# + from, with: #"\end"# + to)
        }

        let text = Array(source)
        var output = "", index = 0

        /// 从 `{` 开始读一整组（允许嵌套），返回组内内容和右括号之后的位置
        func group(at start: Int) -> (body: String, end: Int)? {
            var cursor = start
            while cursor < text.count, text[cursor] == " " { cursor += 1 }
            guard cursor < text.count, text[cursor] == "{" else { return nil }
            var level = 0, body = ""
            while cursor < text.count {
                let character = text[cursor]
                if character == "\\", cursor + 1 < text.count {
                    if level > 0 { body.append(character); body.append(text[cursor + 1]) }
                    cursor += 2
                    continue
                }
                if character == "{" {
                    level += 1
                    if level > 1 { body.append(character) }
                } else if character == "}" {
                    level -= 1
                    if level == 0 { return (body, cursor + 1) }
                    body.append(character)
                } else if level > 0 {
                    body.append(character)
                }
                cursor += 1
            }
            return nil
        }

        while index < text.count {
            guard text[index] == "\\", index + 1 < text.count, text[index + 1].isLetter else {
                // 转义整体带过：`\{` 里的花括号是字符，不是分组
                if text[index] == "\\", index + 1 < text.count {
                    output.append(text[index]); output.append(text[index + 1]); index += 2; continue
                }
                output.append(text[index]); index += 1; continue
            }
            var cursor = index + 1, name = ""
            while cursor < text.count, text[cursor].isLetter { name.append(text[cursor]); cursor += 1 }
            // `\operatorname*` 的星号只影响上下标位置，一律按无星处理
            if cursor < text.count, text[cursor] == "*" { cursor += 1 }

            if let rule = unwraps[name] {
                var bodies: [String] = [], position = cursor
                for _ in 0..<rule.count {
                    guard let parsed = group(at: position) else { break }
                    bodies.append(parsed.body)
                    position = parsed.end
                }
                guard bodies.count == rule.count else {
                    output.append("\\" + name); index = cursor; continue
                }
                // `\underbrace{x}_{n}` 的下标是挂在花括号上的，外壳没了它也没意义
                if rule.count == 1, position < text.count, text[position] == "_" || text[position] == "^" {
                    if let trailing = group(at: position + 1) { position = trailing.end }
                    else if position + 1 < text.count { position += 2 }
                }
                if let keep = rule.keep, keep < bodies.count {
                    output += "{" + compatible(bodies[keep], depth: depth + 1) + "}"
                }
                index = position
                continue
            }
            output += renames[name] ?? ("\\" + name)
            index = cursor
        }
        return output
    }

    private static func image(_ formula: Formula, size: CGFloat) -> Rendered? {
        let key = "\(size):\(formula.display):\(formula.latex)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        // Bound third-party parser depth and work for untrusted document/model text.
        var depth = 0, commands = 0
        guard !formula.latex.isEmpty, formula.latex.utf16.count <= 8192 else { return nil }
        for char in formula.latex {
            if char == "{" { depth += 1 }; if char == "}" { depth -= 1 }; if char == "\\" { commands += 1 }
            guard depth <= 32, commands <= 128 else { return nil }
        }
        var math = MathImage(latex: compatible(formula.latex), fontSize: size, textColor: .textColor, labelMode: formula.display ? .display : .text)
        let (error, image, layout) = math.asImage()
        let result: Rendered
        if error == nil, let image, let layout, image.size.width > 0, image.size.height > 0,
           image.size.width <= 12_000, image.size.height <= 4_000 {
            image.cacheMode = .never // Keep the native vector drawing sharp when zooming.
            result = Rendered(image: image, descent: layout.descent)
        } else { result = Rendered(image: nil) }
        cache.setObject(result, forKey: key, cost: Int((result.image?.size.width ?? 1) * (result.image?.size.height ?? 1) * 4))
        return result
    }
}
