import AppKit

/// Markdown → TextKit 属性串。**这个文件和它旁边的 MarkdownMath / MarkdownHTML /
/// MarkdownFootnotes / MarkdownEmoji / SyntaxHighlighter 是主应用和 Lightmark
/// 快速查看扩展共享的全部内容**，所以这里只依赖 AppKit 和 Foundation：
/// 不引 SwiftUI、不引 LightlynCore、不碰任何应用状态。
/// 输入是一段 Markdown 和它所在的目录，输出是一份可以直接塞进 NSTextView 的属性串。
///
/// 界面那一层各自实现：主应用是 `MarkdownPreviewView`，扩展是 `PreviewViewController`。

extension NSAttributedString.Key {
    /// 标题的锚点名，`[目录](#标题)` 这类文内跳转靠它定位
    static let headingSlug = NSAttributedString.Key("LightlynHeadingSlug")
}

// MARK: - 渲染

enum MarkdownRenderer {
    /// 尺寸闸。Markdown 的解析是 Foundation 做的，成本随文件线性涨，而且**没法只解析一屏**：
    /// «实测» 251KB 光解析就 69ms，加上排版一共 117ms；1MB 就要小半秒了。
    /// 超过这个尺寸的 .md 多半是导出的数据或日志，退回纯文本看反而更快、也一样能读
    /// （纯文本那条路自己有 8MB 上限和截断提示）。
    static let sourceLimit = 512 * 1024

    private static let options = AttributedString.MarkdownParsingOptions(
        allowsExtendedAttributes: true, interpretedSyntax: .full,
        failurePolicy: .returnPartiallyParsedIfPossible)

    /// Model output has no local document directory. Keep image alt text without
    /// reading local files or fetching network images mentioned by generated Markdown.
    static func render(_ markdown: String, codeBackground: NSColor = .quaternarySystemFill) -> NSAttributedString? {
        render(markdown, base: nil, codeBackground: codeBackground)
    }

    static func render(contentsOf url: URL) -> NSAttributedString? {
        guard (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0 <= sourceLimit,
              let markdown = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return render(markdown, base: url.deletingLastPathComponent(), codeBackground: .quaternarySystemFill)
    }

    private static func render(_ markdown: String, base: URL?, codeBackground: NSColor) -> NSAttributedString? {
        guard markdown.utf8.count <= sourceLimit else { return nil }
        // 脚注先把定义行搬到文末（解析器会把 `[^1]` 误当链接引用吃掉），
        // 再让 math 在改写后的正文上保护 TeX。两步都只动源码，顺序不能换。
        let notes = MarkdownFootnotes.prepare(markdown)
        let math = MarkdownMath.prepare(notes.markdown)
        var parsing = options
        parsing.appliesSourcePositionAttributes = base == nil
        guard let parsed = try? AttributedString(markdown: math.markdown, options: parsing) else { return nil }
        return build(parsed, base: base, codeBackground: codeBackground,
                     original: base == nil ? math.markdown : nil, math: math, notes: notes)
    }

    // Markdown 使用阅读字号；其余尺度按正文派生，不影响散文和代码预览。
    private static let bodySize: CGFloat = 16
    private static var indentUnit: CGFloat { bodySize * 2 }
    private static let codeFont = NSFont.monospacedSystemFont(ofSize: bodySize * 0.85, weight: .regular)
    /// 折行后续行的缩进：一个制表位（四个字符宽）
    private static let codeContinuation =
        ("0" as NSString).size(withAttributes: [.font: codeFont]).width * 4

    /// 垫在代码块前后的空段落，把灰底和别的东西隔开
    private static let codeGap = NSAttributedString(string: "\n", attributes: [
        .font: NSFont.systemFont(ofSize: bodySize * 0.6),
    ])

    private static func isCodeBlock(_ intent: PresentationIntent?) -> Bool {
        guard let components = intent?.components else { return false }
        return components.contains { if case .codeBlock = $0.kind { return true }; return false }
    }

    private static func build(_ source: AttributedString, base: URL?, codeBackground: NSColor = .quaternarySystemFill, original: String?, math: MarkdownMath.Prepared, notes: MarkdownFootnotes.Prepared) -> NSAttributedString {
        let output = NSMutableAttributedString()
        // 同一张表的所有单元格必须共用一个 NSTextTable 实例，按 table 意图的 identity 索引
        var tables: [Int: NSTextTable] = [:]
        var buffer = NSMutableAttributedString()
        var pending: PresentationIntent?
        var started = false
        /// 当前这一块里的图片：(alt 文字在 buffer 里的位置, 图片地址)
        var pendingImages: [(NSRange, URL)] = []
        var loader = ImageLoader()
        /// `<p align="center">` 这类容器开在一块、内容在下一块，对齐得跨块带着走
        var container: NSTextAlignment?
        var links = LinkResolver()
        var slugs: [String: Int] = [:]
        var markedListItems = Set<Int>()
        /// 上一个排出来的表格单元格，用来发现被跳过的空列
        var lastCell: (table: Int, row: Int, column: Int, columns: Int)?

        // 上一个**真正排出来的**块的意图，用来判断「换了一张列表」这种块间关系
        var previous: PresentationIntent?

        func flush() {
            let block = buffer
            buffer = NSMutableAttributedString()
            trimTrailingNewlines(block)
            guard block.length > 0 else { pendingImages = []; return }
            // 代码块的底色是**贴着文字**画的，上下都得留口气；两个代码块挨着时
            // 底色更会连成一整片。«踩过» 用 NSTextBlock 的外边距不行——外边距也在底色里面，
            // 加到 3em 也只是把灰底撑得更高。只能垫一个不带块的普通段落。
            if output.length > 0, isCodeBlock(pending) || isCodeBlock(previous) {
                output.append(codeGap)
            }
            // 空单元格在解析结果里**没有任何 run**（零长度的 run 不存在），于是整格消失、
            // 同一行后面的列全体左移一位。«踩过» 我们自己 README 的表头第一格是空的，
            // 渲染出来标题比正文少一列、错位。按意图里的行列号把缺的列补回来。
            if let kinds = pending?.components.map(\.kind), let cell = tableCell(kinds),
               let descriptor = tableDescriptor(pending) {
                let sameRow = lastCell?.table == descriptor.identity && lastCell?.row == cell.row
                let first = sameRow ? (lastCell!.column + 1) : 0
                for column in first..<cell.column {
                    output.append(emptyCell(descriptor, row: cell.row, column: column,
                                            isHeader: cell.isHeader, tables: &tables))
                }
                lastCell = (descriptor.identity, cell.row, cell.column, descriptor.columns.count)
            }
            let item = pending?.components.first { if case .listItem = $0.kind { return true }; return false }
            let startsListItem = item.map { markedListItems.insert($0.identity).inserted } ?? false
            let rendered = NSMutableAttributedString(attributedString: styled(block, intent: pending, previous: previous, startsListItem: startsListItem,
                                 images: pendingImages, base: base, codeBackground: codeBackground, loader: &loader, links: &links, slugs: &slugs, tables: &tables, container: &container))
            math.restore(in: rendered, codeBlock: isCodeBlock(pending))
            notes.restore(in: rendered, codeBlock: isCodeBlock(pending))
            output.append(rendered)
            pendingImages = []
            previous = pending
        }

        /// 换行或离开表格之前，把上一行尾部缺掉的列补上
        func padRowTail(before intent: PresentationIntent?) {
            guard let last = lastCell else { return }
            let cell = intent.map(\.components).map { $0.map(\.kind) }.flatMap(tableCell)
            let descriptor = tableDescriptor(intent)
            if descriptor?.identity == last.table, cell?.row == last.row { return }
            for column in (last.column + 1)..<last.columns {
                output.append(emptyCell(nil, row: last.row, column: column,
                                        isHeader: false, tables: &tables, existing: last.table))
            }
            lastCell = nil
        }

        for run in source.runs {
            let intent = run.presentationIntent
            if !started || intent != pending {
                flush()
                padRowTail(before: intent)
                pending = intent
                started = true
            }
            let start = buffer.length
            let fragment = NSMutableAttributedString(attributedString: NSAttributedString(AttributedString(source[run.range])))
            if !isCodeBlock(intent), run.inlinePresentationIntent?.contains(.code) != true, run.link == nil,
               let original, let position = run.markdownSourcePosition, let range = Range(position, in: original),
               original[range] == fragment.string {
                // Only untouched literal runs qualify; escaped stars and entities keep their meaning.
                repairQuotedEmphasis(in: fragment)
            }
            buffer.append(fragment)
            // 图片的 alt 文字先照常进 buffer，位置记下来，styled 里再换成附件
            if let image = run.imageURL {
                pendingImages.append((NSRange(location: start, length: buffer.length - start), image))
            }
        }
        flush()
        padRowTail(before: nil)
        return output
    }

    // CommonMark leaves **“quoted Chinese”** literal beside Chinese letters.
    // Repair only this model-output pattern, after parsing has excluded code and links.
    private static let quotedEmphasis = try! NSRegularExpression(pattern: #"(?<![\\*])\*\*([“‘「『《〈【（][^*\r\n]+[”’」』》〉】）])\*\*(?!\*)"#)
    private static func repairQuotedEmphasis(in text: NSMutableAttributedString) {
        for match in quotedEmphasis.matches(in: text.string, range: NSRange(location: 0, length: text.length)).reversed() {
            let content = match.range(at: 1)
            let fragment = NSMutableAttributedString(attributedString: text.attributedSubstring(from: content))
            let raw = (fragment.attribute(.inlinePresentationIntent, at: 0, effectiveRange: nil) as? UInt) ?? 0
            fragment.addAttribute(.inlinePresentationIntent, value: raw | InlinePresentationIntent.stronglyEmphasized.rawValue,
                                  range: NSRange(location: 0, length: fragment.length))
            text.replaceCharacters(in: match.range, with: fragment)
        }
    }

    /// Measure once per document; the text container supplies its actual width at layout time.
    /// The owner retains the blocks, rather than the table retaining its own blocks in a cycle.
    struct TableLayout {
        let table: NSTextTable
        let blocks: [NSTextTableBlock]
        let preferred: [CGFloat]
        let insets: [CGFloat]

        func fit(in availableWidth: CGFloat) {
            let desired = zip(preferred, insets).map(+)
            let natural = desired.reduce(0, +)
            let target = min(natural, max(availableWidth, 1))
            // Short columns keep their natural width. Longer columns first receive a
            // readable allowance, then share remaining space by unmet content width.
            let base = zip(preferred, insets).map { min($0, bodySize * 8) + $1 }
            let reserved = base.reduce(0, +)
            let demand = natural - reserved
            let widths: [CGFloat]
            if reserved > target {
                widths = base.map { $0 * target / reserved }
            } else if demand > 0 {
                widths = zip(base, desired).map { $0 + (target - reserved) * ($1 - $0) / demand }
            } else {
                widths = desired
            }
            table.setContentWidth(target, type: .absoluteValueType)
            table.setValue(100, type: .percentageValueType, for: .maximumWidth)
            for block in blocks {
                let column = block.startingColumn
                block.setContentWidth(max(widths[column] - insets[column], 1), type: .absoluteValueType)
            }
        }
    }

    /// 文档里所有图片附件的 cell，交给视图统一设定高度上限。
    /// 和 `tableLayouts(in:)` 一样：渲染器只负责量一次，真实尺寸由容器在版式阶段填。
    static func imageCells(in text: NSAttributedString) -> [MarkdownImageCell] {
        var cells: [MarkdownImageCell] = []
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let cell = (value as? NSTextAttachment)?.attachmentCell as? MarkdownImageCell {
                cells.append(cell)
            }
        }
        return cells
    }

    static func tableLayouts(in text: NSAttributedString) -> [TableLayout] {
        var cells: [NSTextTable: [(NSTextTableBlock, CGFloat)]] = [:]
        text.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let style = value as? NSParagraphStyle,
                  let block = style.textBlocks.last as? NSTextTableBlock else { return }
            let line = CTLineCreateWithAttributedString(text.attributedSubstring(from: range))
            var width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            text.enumerateAttribute(.attachment, in: range) { attachment, _, _ in
                if let cell = (attachment as? NSTextAttachment)?.attachmentCell { width += cell.cellSize().width }
            }
            cells[block.table, default: []].append((block, ceil(width)))
        }
        return cells.map { table, entries in
            var widths = Array(repeating: CGFloat(1), count: table.numberOfColumns)
            var insets = Array(repeating: CGFloat(0), count: table.numberOfColumns)
            for (block, width) in entries {
                let column = block.startingColumn
                widths[column] = max(widths[column], width)
                var inset: CGFloat = 0
                for edge in [NSRectEdge.minX, .maxX] {
                    inset += block.width(for: .padding, edge: edge) + block.width(for: .border, edge: edge)
                }
                insets[column] = max(insets[column], inset)
            }
            return TableLayout(table: table, blocks: entries.map(\.0), preferred: widths, insets: insets)
        }
    }

    /// 给一个块套上字体、段落样式和（代码块/引用/表格的）文本块装饰
    private static func styled(_ raw: NSMutableAttributedString,
                               intent: PresentationIntent?,
                               previous: PresentationIntent?,
                               startsListItem: Bool,
                               images: [(NSRange, URL)],
                               base: URL?,
                               codeBackground: NSColor,
                               loader: inout ImageLoader,
                               links: inout LinkResolver,
                               slugs: inout [String: Int],
                               tables: inout [Int: NSTextTable],
                               container: inout NSTextAlignment?) -> NSAttributedString {
        let kinds = intent?.components.map(\.kind) ?? [.paragraph]
        let text = NSMutableAttributedString(attributedString: raw)
        // 先换图片：这一步会改长度，得赶在算 whole 和取行内意图之前
        replaceImages(in: text, images: images, base: base, loader: &loader)

        // 分隔线没有文字内容，单独处理
        if kinds.contains(where: { if case .thematicBreak = $0 { return true }; return false }) {
            return thematicBreak()
        }

        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.35
        style.paragraphSpacing = bodySize
        // 图片附件的高度就是它该占的高度。行距倍数是给**文字**行准备的，
        // 按比例乘到图上会凭空多出一大截——而且全空在图的上面：
        // «实测» 954pt 的图行片段排到 1304pt，多出 350pt 的白。
        // 小图标（徽章那种）留着正常行距，只有明显比一行高的才关掉。
        if containsTallImage(text) { style.lineHeightMultiple = 1 }

        var baseFont = NSFont.systemFont(ofSize: bodySize)
        var color = NSColor.textColor
        var blocks: [NSTextBlock] = []
        var prefix: String?

        if let level = headerLevel(kinds) {
            let scale: [CGFloat] = [2, 1.5, 1.25, 1, 0.875, 0.85]
            baseFont = .systemFont(ofSize: bodySize * scale[min(level, 6) - 1], weight: .semibold)
            style.lineHeightMultiple = 1.15
            style.paragraphSpacingBefore = previous == nil ? 0 : bodySize * 1.5
            style.paragraphSpacing = bodySize
            if level == 6 { color = .secondaryLabelColor }
            if level <= 2 {
                // GitHub 风格：一级/二级标题下面一条半透明细横杠
                let rule = NSTextBlock()
                rule.setValue(100, type: .percentageValueType, for: .width)
                rule.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
                rule.setBorderColor(.separatorColor, for: .maxY)
                rule.setWidth(bodySize * 0.35, type: .absoluteValueType, for: .padding, edge: .maxY)
                blocks.append(rule)
            }
        }

        var codeLanguage: String?
        if let language = codeBlockLanguage(kinds) {
            codeLanguage = language ?? ""
            baseFont = codeFont
            style.lineHeightMultiple = 1.25
            style.defaultTabInterval = codeContinuation
            style.tabStops = []
            // 代码块**跟着散文一起换行**：Markdown 里放的多是语言代码而不是数据，
            // 为它把整页做成横向滚动不划算。折行的续行缩进一个制表位，
            // 一眼能看出这是接着上一行，而不是新的一行。
            style.headIndent = codeContinuation
            // 代码块里每个换行都是一个段落边界，段间距会把代码排成隔行的样子
            style.paragraphSpacing = 0
            let block = NSTextBlock()
            // 不给宽度的话 TextKit 按最小内容宽排版，代码会变成一列竖排
            block.setValue(100, type: .percentageValueType, for: .width)
            block.setWidth(bodySize, type: .absoluteValueType, for: .padding)
            block.backgroundColor = codeBackground
            blocks.append(block)
        }

        if kinds.contains(where: { if case .blockQuote = $0 { return true }; return false }) {
            color = .secondaryLabelColor
            let block = NSTextBlock()
            block.setValue(100, type: .percentageValueType, for: .width)
            block.setWidth(4, type: .absoluteValueType, for: .border, edge: .minX)
            block.setBorderColor(.separatorColor, for: .minX)
            block.setWidth(bodySize * 0.9, type: .absoluteValueType, for: .padding, edge: .minX)
            blocks.append(block)
        }

        let depth = listDepth(kinds)
        if depth > 0 {
            style.paragraphSpacing = bodySize * 0.25
            // A list item's marker belongs to its first block, not every child paragraph.
            style.firstLineHeadIndent = indentUnit * CGFloat(startsListItem ? depth - 1 : depth)
            style.headIndent = indentUnit * CGFloat(depth)
            style.tabStops = [NSTextTab(textAlignment: .left, location: indentUnit * CGFloat(depth))]
            if startsListItem, let ordinal = listItemOrdinal(kinds) {
                // cmark-gfm 不给 task list 意图，`[ ]` / `[x]` 是原样留在正文开头的
                let bullet = ["●", "○", "▪"][min(depth - 1, 2)]
                prefix = (taskMark(text) ?? (isOrderedList(kinds) ? "\(ordinal)." : bullet)) + "\t"
            }
        }

        // 两组列表（无序接有序）之间、列表和前后正文之间都要断开：
        // 列表项自己的段间距很小，不额外加就会挤成一坨
        if listIdentity(intent) != listIdentity(previous) {
            style.paragraphSpacingBefore = max(style.paragraphSpacingBefore, bodySize * 0.5)
        }

        if let cell = tableCell(kinds), let table = tableDescriptor(intent) {
            let shared = tables[table.identity] ?? {
                let created = NSTextTable()
                created.numberOfColumns = max(table.columns.count, 1)
                created.layoutAlgorithm = .fixedLayoutAlgorithm
                created.collapsesBorders = true
                tables[table.identity] = created
                return created
            }()
            let block = NSTextTableBlock(table: shared,
                                         startingRow: cell.row, rowSpan: 1,
                                         startingColumn: cell.column, columnSpan: 1)
            block.setWidth(1, type: .absoluteValueType, for: .border)
            block.setBorderColor(.separatorColor)
            block.setWidth(bodySize * 0.45, type: .absoluteValueType, for: .padding)
            block.setWidth(bodySize * 0.8, type: .absoluteValueType, for: .padding, edge: .minX)
            block.setWidth(bodySize * 0.8, type: .absoluteValueType, for: .padding, edge: .maxX)
            if !cell.isHeader && cell.row % 2 == 0 {
                block.backgroundColor = .quaternarySystemFill
            }
            blocks.append(block)
            style.paragraphSpacing = 0
            if cell.isHeader { baseFont = .systemFont(ofSize: bodySize, weight: .semibold) }
            if cell.column < table.columns.count {
                switch table.columns[cell.column].alignment {
                case .left: style.alignment = .left
                case .center: style.alignment = .center
                case .right: style.alignment = .right
                @unknown default: style.alignment = .natural
                }
            }
        }

        // emoji 短码和原生 HTML 都会改长度，必须赶在算 whole 之前；
        // 而样式又只能等基础字体铺完才加，所以 HTML 在这里只摘标签、记范围。
        //
        // 绝大多数段落里冒号和尖括号一个都没有。一次扫描同时回答这两个问题——
        // 分开问的话，每个段落都要多走一遍字符串查找，几千个段落加起来就是几毫秒。
        // 上一块开着的容器对齐（`<p align="center">` 那三块里的中间一块）。
        // 放在 HTML 那一步之外：中间那块常常一个尖括号都没有，走不到下面的扫描。
        if let container, blocks.isEmpty, codeLanguage == nil { style.alignment = container }

        var html: MarkdownHTML.Spans?
        if text.mutableString.rangeOfCharacter(from: shortcutMarkers).location != NSNotFound {
            MarkdownEmoji.substitute(in: text, codeBlock: codeLanguage != nil)
            if codeLanguage == nil, let spans = MarkdownHTML.strip(in: text, base: base, loader: &loader) {
                if spans.opensCentered { container = .center }
                if spans.closesContainer { container = nil }
                // `<hr>` 或者只剩一个开标签（居中 logo 那种写法会拆成三块）的块不占版面
                if spans.empty { return spans.rule ? thematicBreak() : NSAttributedString() }
                if spans.centered { style.alignment = .center }
                // HTML 里的 `<img>` 到这一步才变成附件，上面那道行距闸门看不见它。
                // «实测» 一张 128pt 的 logo 会按 1.35 倍排成 173pt 的行，多出来的 45pt 全空在图上面。
                if style.lineHeightMultiple != 1, containsTallImage(text) { style.lineHeightMultiple = 1 }
                html = spans
            }
        }

        style.textBlocks = blocks

        // taskMark 会从正文头上吃掉 "[ ] "，长度到这里才定下来
        let whole = NSRange(location: 0, length: text.length)

        // 先铺基础属性，再按行内意图换字体变体（粗/斜/等宽），保留原有的链接等属性
        text.addAttributes([.font: baseFont, .foregroundColor: color, .paragraphStyle: style],
                           range: whole)
        if let codeLanguage { applyCodeColors(to: text, language: codeLanguage) }
        convertHardBreaks(in: text)
        var inline = applyInlineIntents(to: text, baseFont: baseFont, codeBackground: codeBackground)
        if let html {
            let extra = MarkdownHTML.apply(html, to: text, baseFont: baseFont, codeBackground: codeBackground)
            inline.restyled.append(contentsOf: extra.restyled)
            inline.italics.append(contentsOf: extra.italics)
        }
        // 解析器给的相对链接没有 scheme，直接点是打不开的：按 .md 所在目录解成文件地址。
        // 解不出来（目标不在盘上、锚点、mailto）就保留原样，样式照给，不假装它能跳。
        var relinked: [(NSRange, URL)] = []
        text.enumerateAttribute(.link, in: whole) { value, range, _ in
            guard let url = value as? URL else { return }
            text.addAttributes([.foregroundColor: NSColor.linkColor,
                                .underlineStyle: NSUnderlineStyle.single.rawValue], range: range)
            if url.scheme == nil, let target = links.resolve(url.relativeString, base: base) {
                relinked.append((range, target))
            }
        }
        for (range, url) in relinked { text.addAttribute(.link, value: url, range: range) }

        if let prefix {
            let marker = NSMutableAttributedString(string: prefix,
                                            attributes: [.font: baseFont,
                                                         .foregroundColor: color,
                                                         .paragraphStyle: style])
            if prefix.hasPrefix("●") || prefix.hasPrefix("○") || prefix.hasPrefix("▪") {
                marker.addAttributes([.font: NSFont.systemFont(ofSize: bodySize * 0.65),
                                      .baselineOffset: bodySize * 0.12], range: NSRange(location: 0, length: 1))
            }
            text.insert(marker, at: 0)
            let shift = marker.length
            inline.italics = inline.italics.map { NSRange(location: $0.location + shift, length: $0.length) }
            inline.restyled = inline.restyled.map { NSRange(location: $0.location + shift, length: $0.length) }
        }
        text.append(NSAttributedString(string: "\n",
                                       attributes: [.font: baseFont, .paragraphStyle: style]))

        // 标题挂上锚点，文内 `#小节` 的链接才有地方可去
        if headerLevel(kinds) != nil, text.length > 0 {
            text.addAttribute(.headingSlug, value: slug(text.string, taken: &slugs),
                              range: NSRange(location: 0, length: 1))
        }

        substituteMissingGlyphs(in: text, ranges: inline.restyled)
        applyObliqueness(to: text, ranges: inline.italics)
        return text
    }

    // MARK: 图片

    /// 一次渲染里的图片预算，防着「一篇文档几百张图」把首屏拖垮。
    /// 同一张图重复出现只读一次。
    struct ImageLoader {
        /// 单张图的上限。超过就不读——预览是扫一眼就走，不值得为一张巨图等。
        static let byteLimit = 8 * 1024 * 1024
        /// 一篇文档最多加载多少张
        static let countLimit = 64
        /// 可选的准入闸。返回 false 的图当作读不到处理。
        ///
        /// 主应用不设，一律放行。快速查看扩展会装上它——那边是沙箱进程，
        /// 得把读取范围收窄到用户授权过的目录，不能文档指哪读哪。
        nonisolated(unsafe) static var permits: ((URL) -> Bool)?

        private var cache: [URL: NSImage] = [:]
        private var loaded = 0

        mutating func image(at url: URL) -> NSImage? {
            if let hit = cache[url] { return hit }
            guard loaded < Self.countLimit else { return nil }
            guard Self.permits?(url) ?? true else { return nil }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            guard size > 0, size <= Self.byteLimit, let image = NSImage(contentsOf: url),
                  image.size.width > 0, image.size.height > 0 else { return nil }
            loaded += 1
            cache[url] = image
            return image
        }
    }

    /// 把 `![alt](路径)` 的 alt 文字换成真图。**只认本地图片**——
    /// 远程图片要联网，和 v1「全本地执行」冲突，那种就保留 alt 文字。
    /// 读不出来（路径不对、格式不认、超预算）也保留 alt 文字，不留空白。
    private static func replaceImages(in text: NSMutableAttributedString,
                                      images: [(NSRange, URL)],
                                      base: URL?,
                                      loader: inout ImageLoader) {
        guard let base, !images.isEmpty else { return }
        // 从后往前替换，前面的位置才不会被挪动
        for (range, source) in images.sorted(by: { $0.0.location > $1.0.location }) {
            guard NSMaxRange(range) <= text.length,
                  let resolved = localURL(source, base: base),
                  let image = loader.image(at: resolved) else { continue }
            let attachment = NSTextAttachment()
            attachment.attachmentCell = MarkdownImageCell(imageCell: image)
            text.replaceCharacters(in: range, with: NSAttributedString(attachment: attachment))
        }
    }

    /// GitHub 的锚点命名：转小写、去标点、空格换连字符，重名的后面接序号。
    /// 中日韩原样保留——GitHub 也是这么做的，`#文本预览` 能跳。
    static func slug(_ title: String, taken: inout [String: Int]) -> String {
        var result = ""
        for character in title.lowercased() {
            if character.isLetter || character.isNumber || character == "-" || character == "_" {
                result.append(character)
            } else if character.isWhitespace, !result.isEmpty, result.last != "-" {
                result.append("-")
            }
        }
        while result.last == "-" { result.removeLast() }
        let base = result.isEmpty ? "section" : result
        let seen = taken[base, default: 0]
        taken[base] = seen + 1
        return seen == 0 ? base : "\(base)-\(seen)"
    }

    /// `:短码:` 的冒号和 HTML 标签的尖括号
    private static let shortcutMarkers = CharacterSet(charactersIn: ":<")

    /// 一次渲染里的链接解析结果。同一篇文档里「回到上级」这类链接会出现几十次，
    /// 每次都去问一趟文件系统不值当——命中与否都记下来。
    struct LinkResolver {
        private var cache: [String: URL?] = [:]

        mutating func resolve(_ href: String, base: URL?) -> URL? {
            if let hit = cache[href] { return hit }
            let resolved = MarkdownRenderer.resolveLink(href, base: base)
            if cache.count < 512 { cache[href] = resolved }
            return resolved
        }
    }

    /// 相对链接按 .md 所在目录解成文件地址。目标不在盘上就返回 nil——
    /// 宁可让链接点不动，也不要指到一个不存在的路径上去。
    /// `#锚点`、`mailto:` 这类交给上层原样保留。
    static func resolveLink(_ href: String, base: URL?) -> URL? {
        guard let base, !href.isEmpty, !href.hasPrefix("#") else { return nil }
        if let absolute = URL(string: href), absolute.scheme != nil {
            return absolute.isFileURL ? localURL(absolute, base: base) : nil
        }
        // 片段和查询串不属于文件名
        let path = String(href.prefix { $0 != "#" && $0 != "?" })
        guard !path.isEmpty else { return nil }
        let decoded = path.removingPercentEncoding ?? path
        return localURL(URL(fileURLWithPath: decoded, relativeTo: base), base: base)
    }

    /// 造一个空的表格单元格。
    ///
    /// 解析结果里没有这一格，所以拿不到它的 PresentationIntent，只能按行列号自己拼。
    /// 装饰必须和 `styled` 里那条表格分支一致，否则空格子的边框和底色会和邻居对不上。
    private static func emptyCell(_ descriptor: (identity: Int, columns: [PresentationIntent.TableColumn])?,
                                  row: Int, column: Int, isHeader: Bool,
                                  tables: inout [Int: NSTextTable],
                                  existing: Int? = nil) -> NSAttributedString {
        let key = descriptor?.identity ?? existing ?? 0
        let shared = tables[key] ?? {
            let created = NSTextTable()
            created.numberOfColumns = max(descriptor?.columns.count ?? 1, 1)
            created.layoutAlgorithm = .fixedLayoutAlgorithm
            created.collapsesBorders = true
            tables[key] = created
            return created
        }()
        let block = NSTextTableBlock(table: shared, startingRow: row, rowSpan: 1,
                                     startingColumn: column, columnSpan: 1)
        block.setWidth(1, type: .absoluteValueType, for: .border)
        block.setBorderColor(.separatorColor)
        block.setWidth(bodySize * 0.45, type: .absoluteValueType, for: .padding)
        block.setWidth(bodySize * 0.8, type: .absoluteValueType, for: .padding, edge: .minX)
        block.setWidth(bodySize * 0.8, type: .absoluteValueType, for: .padding, edge: .maxX)
        if !isHeader, row % 2 == 0 { block.backgroundColor = .quaternarySystemFill }
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.35
        style.paragraphSpacing = 0
        style.textBlocks = [block]
        return NSAttributedString(string: "\n", attributes: [
            .font: NSFont.systemFont(ofSize: bodySize), .paragraphStyle: style,
        ])
    }

    /// 段落里有没有明显比一行文字高的图片附件。
    /// 阈值取正文两倍：行内的小徽章不该被当成「图」而丢掉行距。
    private static func containsTallImage(_ text: NSAttributedString) -> Bool {
        var found = false
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, stop in
            guard let cell = (value as? NSTextAttachment)?.attachmentCell,
                  cell.cellSize().height > bodySize * 2 else { return }
            found = true
            stop.pointee = true
        }
        return found
    }

    /// 相对路径按 .md 所在目录解；`file:` 直接用；http(s) 一律不碰。
    static func localURL(_ source: URL, base: URL) -> URL? {
        let resolved: URL
        if source.scheme == nil {
            // 解析器给的是百分号编码过的相对地址，`relativePath` 已经解码
            resolved = URL(fileURLWithPath: source.relativePath, relativeTo: base)
        } else if source.isFileURL {
            resolved = source
        } else {
            return nil
        }
        return FileManager.default.fileExists(atPath: resolved.path) ? resolved.standardized : nil
    }

    /// 图片按**栏宽**缩放。`NSTextAttachment.bounds` 是定尺的，栏宽变了图不会跟着变；
    /// cell 能在排版时拿到行片段宽度，宽图缩到栏宽，窄图保持原大小（不放大，放大只会糊）。
    final class MarkdownImageCell: NSTextAttachmentCell {
        var baseline: CGFloat = 0
        /// 高度上限。竖图只按栏宽缩是不够的——«实测» 一张 640×954 的图宽度本来就没超栏，
        /// 于是原样排出 954pt，占满整个预览面板，前后文全被顶出可视区。
        /// 由视图在版式变化时按视口高度填进来。**不能跟着滚动位置走**：
        /// 那样滚一下图就换一个大小，整篇跟着重排。
        var maxHeight: CGFloat = .greatestFiniteMagnitude
        /// `<img width="128">` 写死的尺寸。只写一边时另一边记 0，按原比例配。
        /// «踩过» 不认这两个属性的话，README 顶上那张 512×512 的 logo 会照原始像素排，
        /// 占掉半个面板——作者写 width 就是因为原图本来就不是要按原大小看的。
        var requested: NSSize?

        /// 该有多大：写了 `width`/`height` 就听它的，没写就按图片自己的像素。
        private var natural: NSSize {
            guard let size = image?.size, size.width > 0, size.height > 0 else { return .zero }
            guard let requested else { return size }
            return NSSize(width: requested.width > 0 ? requested.width : size.width * requested.height / size.height,
                          height: requested.height > 0 ? requested.height : size.height * requested.width / size.width)
        }

        private func fitted(_ width: CGFloat) -> NSSize {
            let size = natural
            guard size.width > 0, size.height > 0 else { return .zero }
            let scale = min(1, max(width, 1) / size.width, max(maxHeight, 1) / size.height)
            return NSSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        }

        override func cellSize() -> NSSize { natural }

        override func cellFrame(for textContainer: NSTextContainer,
                                proposedLineFragment lineFrag: NSRect,
                                glyphPosition position: NSPoint,
                                characterIndex charIndex: Int) -> NSRect {
            let size = fitted(lineFrag.width)
            let scale = size.height / max(image?.size.height ?? 1, 1)
            return NSRect(x: 0, y: -baseline * scale, width: size.width, height: size.height)
        }

        /// 必须自己画。«踩过» 默认实现**按图片原始尺寸画**，不理会排版给的框：
        /// 排版按缩放后的高度留位置、绘制却画原尺寸，宽图就会又拉伸又压到后面的文字上。
        override func draw(withFrame cellFrame: NSRect, in controlView: NSView?,
                           characterIndex charIndex: Int, layoutManager: NSLayoutManager) {
            image?.draw(in: cellFrame)
        }

        override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
            image?.draw(in: cellFrame)
        }
    }

    /// 代码块着色。用的是代码文件预览那同一个 tokenizer（`SyntaxHighlighter`），
    /// 写一次两边共用。记号只有注释/字符串/数字/关键字/类型这几档——
    /// 预览是扫一眼就走，认得出结构就够了，再细的语法不值当。
    /// `SyntaxToken.color` 本身是动态色，烘进属性串也会跟着深浅色变。
    private static func applyCodeColors(to text: NSMutableAttributedString, language: String) {
        let source = text.string as NSString
        guard source.length > 0,
              let highlighter = SyntaxHighlighter(text: source,
                                                  extension: grammarExtension(for: language))
        else { return }
        highlighter.tokens(in: NSRange(location: 0, length: source.length)) { location, length, token in
            text.addAttribute(.foregroundColor, value: token.color,
                              range: NSRange(location: location, length: length))
        }
    }

    /// ```` ```python ```` 里的标记不是扩展名，做一层常见别名。
    /// 认不出来的**不着色**——宁可不上色，也不要按错的语法上错色。
    /// 注意别把 `text` / 空标记映射成 `""`：那个是「无后缀文件」档（Dockerfile / Makefile），
    /// 会拿 `#` 当注释，用在纯文本上就是乱涂。
    private static func grammarExtension(for language: String) -> String {
        switch language.lowercased() {
        case "python", "python3": return "py"
        case "javascript", "node": return "js"
        case "typescript": return "ts"
        case "shell", "console", "terminal": return "sh"
        case "ruby": return "rb"
        case "rust": return "rs"
        case "golang": return "go"
        case "c++": return "cpp"
        case "c#", "csharp": return "cs"
        case "objective-c", "objc": return "m"
        case "kotlin": return "kt"
        case "dockerfile", "makefile", "make": return ""
        case "", "text", "plaintext", "txt", "none": return "\u{0}"   // 落到 default，不着色
        case let other: return other
        }
    }

    /// 等宽字体（`.AppleSystemUIFontMonospaced`）没有中文字形，中文在它下面会排成**空字形**——
    /// 不是画成豆腐块，是整段消失，`行内代码` 只剩一个灰底。
    ///
    /// AppKit 自己也会替换，但它给的结果我们看不见：中文斜体换到 PingFang 之后 italic 掉了，
    /// 得知道最终用的是哪个字体才能决定要不要补倾斜（`applyObliqueness`）。
    /// 所以自己问一遍：逐字问系统「谁能画这个字」，只改画不出来的那些。
    ///
    /// **只扫我们改过字体的范围**（行内代码、粗体、斜体），正文一概不碰——
    /// 逐字问字形是 0.3µs 一个字，60 万字的中文文档要 190ms，铺全文就太贵了。
    private static func substituteMissingGlyphs(in text: NSMutableAttributedString,
                                                ranges: [NSRange]) {
        guard !ranges.isEmpty else { return }
        let source = text.string as NSString
        var replacements: [(NSRange, NSFont)] = []

        for scope in ranges {
            text.enumerateAttribute(.font, in: scope) { value, run, _ in
                guard let font = value as? NSFont else { return }
                var holeStart: Int?

                func closeHole(_ end: Int) {
                    guard let start = holeStart else { return }
                    holeStart = nil
                    let hole = NSRange(location: start, length: end - start)
                    let fallback = CTFontCreateForString(
                        font, source, CFRange(location: hole.location, length: hole.length))
                    replacements.append((hole, fallback as NSFont))
                }

                var index = run.location
                while index < NSMaxRange(run) {
                    let cluster = source.rangeOfComposedCharacterSequence(at: index)
                    let end = min(NSMaxRange(cluster), NSMaxRange(run))
                    if canRender(font, source, NSRange(location: index, length: end - index)) {
                        closeHole(index)
                    } else if holeStart == nil {
                        holeStart = index
                    }
                    index = max(end, index + 1)
                }
                closeHole(NSMaxRange(run))
            }
        }

        for (range, font) in replacements { text.addAttribute(.font, value: font, range: range) }
    }

    private static func canRender(_ font: NSFont, _ source: NSString, _ range: NSRange) -> Bool {
        if range.length == 1, source.character(at: range.location) < 0x80 { return true }
        var units = [UniChar](repeating: 0, count: range.length)
        source.getCharacters(&units, range: range)
        var glyphs = [CGGlyph](repeating: 0, count: range.length)
        return CTFontGetGlyphsForCharacters(font, units, &glyphs, range.length)
    }

    /// 中文字体族没有斜体面（PingFang 只有 Regular/Bold），上一步替换字体后 italic 会掉。
    /// 用倾斜补出来，和系统在别处的做法一致。
    private static func applyObliqueness(to text: NSMutableAttributedString, ranges: [NSRange]) {
        var targets: [NSRange] = []
        for range in ranges {
            text.enumerateAttribute(.font, in: range) { value, sub, _ in
                guard let font = value as? NSFont,
                      !NSFontManager.shared.traits(of: font).contains(.italicFontMask) else { return }
                targets.append(sub)
            }
        }
        for range in targets { text.addAttribute(.obliqueness, value: 0.2, range: range) }
    }

    /// 行尾两个空格的硬换行：意图给的是普通 `\n`，而 `\n` 是**段落**边界，
    /// 会连段间距一起吃进去，看着就成了两段。换成 U+2028（行分隔符）——
    /// 同样断行，但还在同一段里。长度一样，range 不用重算。
    private static func convertHardBreaks(in text: NSMutableAttributedString) {
        var targets: [NSRange] = []
        text.enumerateAttribute(.inlinePresentationIntent,
                                in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let raw = value as? UInt,
                  InlinePresentationIntent(rawValue: raw).contains(.lineBreak) else { return }
            targets.append(range)
        }
        let source = text.string as NSString
        for range in targets where source.substring(with: range) == "\n" {
            text.replaceCharacters(in: range, with: "\u{2028}")
        }
    }

    /// 认列表项开头的 `[ ]` / `[x]`，吃掉它并返回对应的记号
    private static func taskMark(_ text: NSMutableAttributedString) -> String? {
        let source = text.string as NSString
        guard source.length >= 4 else { return nil }
        let mark: String
        switch source.substring(to: 4) {
        case "[ ] ": mark = "☐"
        case "[x] ", "[X] ": mark = "☑"
        default: return nil
        }
        text.deleteCharacters(in: NSRange(location: 0, length: 4))
        return mark
    }

    /// 块尾多余的换行会在代码块底部拖出一大片底色
    private static func trimTrailingNewlines(_ text: NSMutableAttributedString) {
        let source = text.string as NSString
        var end = source.length
        while end > 0, source.character(at: end - 1) == 0x0A { end -= 1 }
        guard end < source.length else { return }
        text.deleteCharacters(in: NSRange(location: end, length: source.length - end))
    }

    /// 我们动过字体的范围。`restyled` 用来限定查字形的开销，`italics` 用来补倾斜。
    private struct InlineSpans {
        var restyled: [NSRange] = []
        var italics: [NSRange] = []
    }

    /// 行内意图（粗体/斜体/行内代码/删除线）换成实际字体
    private static func applyInlineIntents(to text: NSMutableAttributedString,
                                           baseFont: NSFont, codeBackground: NSColor) -> InlineSpans {
        var spans = InlineSpans()
        let whole = NSRange(location: 0, length: text.length)
        text.enumerateAttribute(.inlinePresentationIntent, in: whole) { value, range, _ in
            guard let raw = value as? UInt else { return }
            let intent = InlinePresentationIntent(rawValue: raw)
            var font = baseFont
            if intent.contains(.code) {
                font = .monospacedSystemFont(ofSize: baseFont.pointSize * 0.85, weight: .regular)
            }
            var traits: NSFontTraitMask = []
            if intent.contains(.stronglyEmphasized) { traits.insert(.boldFontMask) }
            if intent.contains(.emphasized) {
                traits.insert(.italicFontMask)
                spans.italics.append(range)
            }
            if !traits.isEmpty {
                font = NSFontManager.shared.convert(font, toHaveTrait: traits)
            }
            if font != baseFont { spans.restyled.append(range) }
            text.addAttribute(.font, value: font, range: range)
            if intent.contains(.strikethrough) {
                text.addAttribute(.strikethroughStyle,
                                  value: NSUnderlineStyle.single.rawValue, range: range)
            }
            if intent.contains(.code) {
                text.addAttribute(.backgroundColor, value: codeBackground, range: range)
            }
        }
        // 用完就摘掉：NSTextStorage 在 fixAttributes 时会**按这个意图重新推导字体**，
        // 把我们替换好的中文字体又改回等宽，中文于是排成空字形整段消失。
        // 代码块没有这个属性，所以只有行内代码中招——查了很久才定位到这里。
        text.removeAttribute(.inlinePresentationIntent, range: whole)
        return spans
    }

    /// 分隔线。用文本块的上边框画——和标题下面那条线同一个画法，已经验证过能画出来。
    /// 旧版用「撑满栏宽的制表符 + 删除线」，制表位设在 10000pt：
    /// 制表符到不了制表位就退化成一个普通空格，线自然也没了。
    private static func thematicBreak() -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = bodySize * 0.7
        style.paragraphSpacing = bodySize * 0.7
        // 拿块的**下边框**当线：和一级/二级标题下面那条线同一个画法。
        // 试过用块底色直接铺一条——块高压不下去（行高钳位对它没用），成了一根灰条。
        let rule = NSTextBlock()
        rule.setValue(100, type: .percentageValueType, for: .width)
        rule.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
        rule.setBorderColor(.separatorColor, for: .maxY)
        style.textBlocks = [rule]
        // 段落得有内容才排得出行片段；字号压到 4pt，块本身就只剩一条线的厚度
        return NSAttributedString(string: " \n", attributes: [
            .font: NSFont.systemFont(ofSize: 4),
            .paragraphStyle: style,
        ])
    }

    // MARK: 意图查询

    private static func headerLevel(_ kinds: [PresentationIntent.Kind]) -> Int? {
        for kind in kinds { if case .header(let level) = kind { return level } }
        return nil
    }

    private static func codeBlockLanguage(_ kinds: [PresentationIntent.Kind]) -> String?? {
        for kind in kinds { if case .codeBlock(let language) = kind { return language } }
        return nil
    }

    private static func listDepth(_ kinds: [PresentationIntent.Kind]) -> Int {
        kinds.reduce(into: 0) { depth, kind in
            switch kind {
            case .orderedList, .unorderedList: depth += 1
            default: break
            }
        }
    }

    private static func isOrderedList(_ kinds: [PresentationIntent.Kind]) -> Bool {
        for kind in kinds {
            switch kind {
            case .orderedList: return true
            case .unorderedList: return false
            default: break
            }
        }
        return false
    }

    private static func listItemOrdinal(_ kinds: [PresentationIntent.Kind]) -> Int? {
        for kind in kinds { if case .listItem(let ordinal) = kind { return ordinal } }
        return nil
    }

    private static func tableCell(_ kinds: [PresentationIntent.Kind]) -> (row: Int, column: Int, isHeader: Bool)? {
        var column: Int?
        var row: Int?
        var isHeader = false
        for kind in kinds {
            switch kind {
            case .tableCell(let index): column = index
            case .tableRow(let index): row = index
            case .tableHeaderRow: isHeader = true; row = 0
            default: break
            }
        }
        guard let column, let row else { return nil }
        return (row, column, isHeader)
    }

    /// identity 取自 IntentType，用来区分同一文档里的多张表。
    /// 列里带着 `:---:` / `---:` 解析出来的对齐，直接可用。
    private static func tableDescriptor(_ intent: PresentationIntent?)
        -> (identity: Int, columns: [PresentationIntent.TableColumn])? {
        guard let components = intent?.components else { return nil }
        for component in components {
            if case .table(let columns) = component.kind {
                return (component.identity, columns)
            }
        }
        return nil
    }

    /// 最外层列表的 identity。取最外层而不是最内层：
    /// 嵌套子列表换了 identity，但它和父列表是同一组，中间不该断开。
    private static func listIdentity(_ intent: PresentationIntent?) -> Int? {
        guard let components = intent?.components else { return nil }
        var outermost: Int?
        for component in components {
            switch component.kind {
            case .orderedList, .unorderedList: outermost = component.identity
            default: break
            }
        }
        return outermost
    }
}
