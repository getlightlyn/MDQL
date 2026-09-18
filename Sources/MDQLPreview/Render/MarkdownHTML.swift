import AppKit

/// 正文里的原生 HTML。
///
/// CommonMark 允许 HTML 原样穿过解析器，Foundation 也照做——但它只是**标记**出来，
/// 不解释：行内标签标成 `.inlineHTML`，整块标成 `.blockHTML`，文字照旧留在正文里。
/// 不处理的话 README 顶上那句 `<p align="center">` 会原样显示出来，
/// 而这正是 GitHub 上最常见的写法（居中 logo、`<kbd>`、`<details>` 折叠、`<br>`）。
///
/// 这里不写 HTML 解析器，只做一件事：**把标签摘掉，能映射成排版属性的映射，其余只留内容**。
/// 认不出的标签一律当透明——宁可少一层样式，也不要把尖括号甩在读者脸上。
enum MarkdownHTML {
    enum Role {
        case bold, italic, underline, strikethrough
        case code, keyboard, mark, small
        case superscriptText, subscriptText
        case link(URL)
    }

    struct Spans {
        var roles: [(NSRange, Role)] = []
        /// 块上带 `align="center"`（居中 logo 的标准写法）
        var centered = false
        /// 整块只有一条 `<hr>`
        var rule = false
        /// 摘完标签什么都不剩——`<p align="center">` 单独成块时就是这样，整块丢掉
        var empty = false
    }

    // MARK: 扫描

    /// `<!--注释-->` / `</close>` / `<open attrs>` / `<void attrs/>`
    private static let tagPattern = try! NSRegularExpression(
        pattern: #"<!--[\s\S]*?-->|</([a-zA-Z][a-zA-Z0-9-]*)\s*>|<([a-zA-Z][a-zA-Z0-9-]*)((?:"[^"]*"|'[^']*'|[^"'>])*?)(/?)>"#)
    private static let attributePattern = try! NSRegularExpression(
        pattern: #"([a-zA-Z-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))"#)

    /// 自闭合 / 没有结束标签的元素
    private static let voids: Set<String> = [
        "br", "hr", "img", "wbr", "input", "meta", "link", "source", "area", "base", "col", "embed", "param", "track",
    ]
    /// 内容不是给人读的，标签连内容一起丢
    private static let opaque: Set<String> = ["script", "style", "head", "iframe", "noscript", "template"]

    private static func role(for tag: String) -> Role? {
        switch tag {
        case "b", "strong": return .bold
        case "i", "em", "cite", "var", "dfn": return .italic
        case "u", "ins": return .underline
        case "s", "del", "strike": return .strikethrough
        case "code", "tt", "samp": return .code
        case "kbd": return .keyboard
        case "mark": return .mark
        case "small": return .small
        case "sup": return .superscriptText
        case "sub": return .subscriptText
        case "summary": return .bold
        default: return nil
        }
    }

    private static func attributes(_ source: String) -> [String: String] {
        guard !source.isEmpty else { return [:] }
        let text = source as NSString
        var result: [String: String] = [:]
        for match in attributePattern.matches(in: source, range: NSRange(location: 0, length: text.length)) {
            let name = text.substring(with: match.range(at: 1)).lowercased()
            for group in 2...4 where match.range(at: group).location != NSNotFound {
                result[name] = text.substring(with: match.range(at: group))
                break
            }
        }
        return result
    }

    // MARK: 第一步——摘标签

    private enum Token {
        case comment
        case open(String, [String: String])
        case close(String)
        case void(String, [String: String])
    }

    /// 摘掉标签，记下每段内容该套什么样式。
    ///
    /// 分两步做是被后面的流程逼的：样式要等 `applyInlineIntents` 铺完基础字体才能加，
    /// 但删字符必须赶在算 `whole` 之前——两件事中间隔着整套段落样式。
    /// 所以这里只删字符、只记范围，真正上属性交给 `apply`。
    static func strip(in text: NSMutableAttributedString, base: URL?,
                      loader: inout MarkdownRenderer.ImageLoader) -> Spans? {
        // 没有尖括号就不可能有标签。这一句省掉的是对每个段落都走一遍属性枚举。
        // mutableString 是原串的视图，不像 .string 那样每次桥接出一份新的 Swift String。
        guard text.mutableString.range(of: "<").location != NSNotFound else { return nil }
        var scopes: [NSRange] = [], blockScopes: [NSRange] = []
        let whole = NSRange(location: 0, length: text.length)
        text.enumerateAttribute(.inlinePresentationIntent, in: whole) { value, range, _ in
            guard let raw = value as? UInt else { return }
            let intent = InlinePresentationIntent(rawValue: raw)
            guard intent.contains(.inlineHTML) || intent.contains(.blockHTML) else { return }
            scopes.append(range)
            if intent.contains(.blockHTML) { blockScopes.append(range) }
        }
        guard !scopes.isEmpty else { return nil }
        let blockOnly = scopes.reduce(0) { $0 + $1.length } == text.length

        let source = text.string as NSString
        var tokens: [(NSRange, Token)] = []
        for scope in scopes {
            for match in tagPattern.matches(in: text.string, range: scope) {
                if match.range(at: 1).location != NSNotFound {
                    tokens.append((match.range, .close(source.substring(with: match.range(at: 1)).lowercased())))
                } else if match.range(at: 2).location != NSNotFound {
                    let name = source.substring(with: match.range(at: 2)).lowercased()
                    let parsed = attributes(source.substring(with: match.range(at: 3)))
                    let selfClosing = match.range(at: 4).length > 0 || voids.contains(name)
                    tokens.append((match.range, selfClosing ? .void(name, parsed) : .open(name, parsed)))
                } else {
                    tokens.append((match.range, .comment))
                }
            }
        }
        guard !tokens.isEmpty else { return nil }
        tokens.sort { $0.0.location < $1.0.location }

        var spans = Spans()
        // 块级 HTML 里的换行是源码排版用的，不是内容——浏览器也会把它折叠掉。
        // 不处理的话 `<details>\n<summary>…` 会在正文里留一行空白。
        // 换成空格，长度不变，下面记的范围不用重算；`<pre>` 里的换行有意义，整块跳过。
        if !blockScopes.isEmpty, source.range(of: "<pre", options: .caseInsensitive).location == NSNotFound {
            for scope in blockScopes {
                for index in scope.location..<NSMaxRange(scope) where source.character(at: index) == 0x0A {
                    text.replaceCharacters(in: NSRange(location: index, length: 1), with: " ")
                }
            }
        }
        // (标签名, 开标签范围, 内容起点, 角色)
        var stack: [(String, NSRange, Int, Role?)] = []
        var edits: [(NSRange, NSAttributedString?)] = []
        var pending: [(NSRange, Role)] = []

        for (range, token) in tokens {
            switch token {
            case .comment:
                edits.append((range, nil))
            case .open(let name, let parsed):
                if parsed["align"]?.lowercased() == "center" { spans.centered = true }
                // 带对齐属性的 `<kbd>` 是在拿它当盒子画边框（GitHub 上的常见写法），
                // 不是一个按键——按键不需要对齐。这种直接当透明容器。
                let container = name == "kbd" && parsed["align"] != nil
                stack.append((name, range, NSMaxRange(range), container ? nil : role(for: name)))
            case .close(let name):
                // 从栈顶往下找配对；找不到就是一个孤立的结束标签，删掉了事
                guard let index = stack.lastIndex(where: { $0.0 == name }) else {
                    edits.append((range, nil)); continue
                }
                let (tag, openRange, start, kind) = stack[index]
                stack.removeSubrange(index...)
                if opaque.contains(tag) {
                    // <script> 之类连内容一起丢
                    edits.append((NSRange(location: openRange.location,
                                          length: NSMaxRange(range) - openRange.location), nil))
                    continue
                }
                edits.append((openRange, nil))
                edits.append((range, nil))
                if let kind, range.location > start {
                    pending.append((NSRange(location: start, length: range.location - start), kind))
                }
                if tag == "summary", range.location > start {
                    edits.append((NSRange(location: start, length: 0), NSAttributedString(string: "▸ ")))
                }
            case .void(let name, let parsed):
                switch name {
                case "br":
                    // 和行尾两空格的硬换行同一个处理：U+2028 断行但不断段
                    edits.append((range, NSAttributedString(string: "\u{2028}")))
                case "hr":
                    spans.rule = true
                    edits.append((range, nil))
                case "img":
                    let replacement = image(parsed, base: base, loader: &loader, attributes:
                                                text.attributes(at: min(range.location, text.length - 1), effectiveRange: nil))
                    edits.append((range, replacement))
                default:
                    edits.append((range, nil))
                }
            }
        }
        // 没等到结束标签的开标签（`<p align="center">` 单独成块就是这种）
        for (tag, openRange, start, kind) in stack {
            if opaque.contains(tag) {
                edits.append((NSRange(location: openRange.location, length: text.length - openRange.location), nil))
                continue
            }
            edits.append((openRange, nil))
            if let kind, text.length > start {
                pending.append((NSRange(location: start, length: text.length - start), kind))
            }
        }

        // <a href> 的链接要从开标签的属性上取，上面配对时没带出来，单独再走一遍
        var anchors: [(NSRange, URL)] = []
        var open: [(NSRange, URL)] = []
        for (range, token) in tokens {
            switch token {
            case .open("a", let parsed):
                if let value = parsed["href"], let url = href(value, base: base) {
                    open.append((NSRange(location: NSMaxRange(range), length: 0), url))
                }
            case .close("a"):
                if let (start, url) = open.popLast(), range.location > start.location {
                    anchors.append((NSRange(location: start.location, length: range.location - start.location), url))
                }
            default: break
            }
        }
        pending.append(contentsOf: anchors.map { ($0.0, Role.link($0.1)) })

        // 从后往前改，前面的位置才不会被挪动
        edits.sort { $0.0.location == $1.0.location ? $0.0.length > $1.0.length : $0.0.location < $1.0.location }
        var applied: [(NSRange, Int)] = []
        for (range, replacement) in edits.reversed() {
            // 「没有结束标签的 <script>」那条会删到文末，而它排在最后才执行，
            // 那时前面的标签已经删掉、串变短了——按原长度会越界，钳到当前长度。
            guard range.location <= text.length else { continue }
            let clamped = NSRange(location: range.location,
                                  length: min(range.length, text.length - range.location))
            let insert = replacement ?? NSAttributedString()
            text.replaceCharacters(in: clamped, with: insert)
            applied.append((clamped, insert.length))
        }
        applied.sort { $0.0.location < $1.0.location }

        func mapped(_ offset: Int) -> Int {
            var result = offset
            for (range, length) in applied where NSMaxRange(range) <= offset {
                result += length - range.length
            }
            return max(0, min(result, text.length))
        }
        for (range, kind) in pending {
            let start = mapped(range.location), end = mapped(NSMaxRange(range))
            guard end > start else { continue }
            spans.roles.append((NSRange(location: start, length: end - start), kind))
        }
        // 摘完标签后开头剩下的空白是标签之间的缝，不是作者写的缩进
        if blockOnly {
            let stripped = text.string as NSString
            var head = 0
            while head < stripped.length, let scalar = Unicode.Scalar(stripped.character(at: head)),
                  CharacterSet.whitespacesAndNewlines.contains(scalar) { head += 1 }
            if head > 0 {
                text.deleteCharacters(in: NSRange(location: 0, length: head))
                spans.roles = spans.roles.compactMap { range, role in
                    let start = max(0, range.location - head), end = max(0, NSMaxRange(range) - head)
                    return end > start ? (NSRange(location: start, length: end - start), role) : nil
                }
            }
        }
        spans.empty = blockOnly && text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return spans
    }

    /// `<a href>` 的地址。带协议的原样用，`#锚点`原样留给点击那一侧，
    /// 其余当相对路径按 .md 所在目录解——和 Markdown 语法的链接走同一套规则。
    private static func href(_ value: String, base: URL?) -> URL? {
        if let absolute = URL(string: value), absolute.scheme != nil { return absolute }
        if value.hasPrefix("#") { return URL(string: value) }
        return MarkdownRenderer.resolveLink(value, base: base)
    }

    private static func image(_ parsed: [String: String], base: URL?,
                              loader: inout MarkdownRenderer.ImageLoader,
                              attributes: [NSAttributedString.Key: Any]) -> NSAttributedString? {
        let alt = parsed["alt"].flatMap { $0.isEmpty ? nil : $0 }
        guard let source = parsed["src"], let base,
              let url = URL(string: source) ?? URL(string: source.addingPercentEncoding(
                withAllowedCharacters: .urlPathAllowed) ?? source),
              let resolved = MarkdownRenderer.localURL(url, base: base),
              let image = loader.image(at: resolved) else {
            // 远程图不下载、本地图读不出来，都保留 alt 文字，不留空白
            return alt.map { NSAttributedString(string: $0, attributes: attributes) }
        }
        let attachment = NSTextAttachment()
        attachment.attachmentCell = MarkdownRenderer.MarkdownImageCell(imageCell: image)
        let result = NSMutableAttributedString(attachment: attachment)
        result.addAttributes(attributes, range: NSRange(location: 0, length: result.length))
        return result
    }

    // MARK: 第二步——上属性

    /// 在基础字体铺好之后补样式。返回**动过字体的范围**，交给上层去查缺字形。
    static func apply(_ spans: Spans, to text: NSMutableAttributedString,
                      baseFont: NSFont, codeBackground: NSColor) -> (restyled: [NSRange], italics: [NSRange]) {
        var restyled: [NSRange] = [], italics: [NSRange] = []
        for (range, role) in spans.roles {
            guard NSMaxRange(range) <= text.length, range.length > 0 else { continue }
            switch role {
            case .bold, .italic:
                let trait: NSFontTraitMask = role.isBold ? .boldFontMask : .italicFontMask
                text.enumerateAttribute(.font, in: range) { value, sub, _ in
                    let font = (value as? NSFont) ?? baseFont
                    text.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: trait), range: sub)
                }
                restyled.append(range)
                if !role.isBold { italics.append(range) }
            case .underline:
                text.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            case .strikethrough:
                text.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            case .code, .keyboard:
                // 跨行说明这个标签被当**块容器**用了，不是行内记号。
                // «踩过» fzf 的 README 用 `<kbd align="center">` 圈住一整段来画边框：
                // 按行内按键那样上底色，底色会贴着字形走，居中之后一行一个宽度、
                // 看着像渲染坏了。`<kbd>` 这种直接放行；`<code>` 保留等宽但去掉底色。
                let spansLines = text.mutableString.rangeOfCharacter(
                    from: .newlines, range: range).location != NSNotFound
                if spansLines, role.isKeyboard { continue }
                var attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedSystemFont(ofSize: baseFont.pointSize * 0.85, weight: .regular),
                ]
                if !spansLines { attributes[.backgroundColor] = codeBackground }
                text.addAttributes(attributes, range: range)
                restyled.append(range)
            case .mark:
                text.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.35), range: range)
            case .small:
                text.addAttribute(.font, value: NSFont.systemFont(ofSize: baseFont.pointSize * 0.85), range: range)
                restyled.append(range)
            case .superscriptText, .subscriptText:
                let up = role.isSuperscript
                text.enumerateAttribute(.font, in: range) { value, sub, _ in
                    let font = (value as? NSFont) ?? baseFont
                    text.addAttributes([
                        .font: NSFont(descriptor: font.fontDescriptor, size: font.pointSize * 0.72) ?? font,
                        .baselineOffset: font.pointSize * (up ? 0.34 : -0.16),
                    ], range: sub)
                }
                restyled.append(range)
            case .link(let url):
                text.addAttributes([
                    .link: url,
                    .foregroundColor: NSColor.linkColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                ], range: range)
            }
        }
        return (restyled, italics)
    }
}

private extension MarkdownHTML.Role {
    var isBold: Bool { if case .bold = self { return true }; return false }
    var isKeyboard: Bool { if case .keyboard = self { return true }; return false }
    var isSuperscript: Bool { if case .superscriptText = self { return true }; return false }
}
