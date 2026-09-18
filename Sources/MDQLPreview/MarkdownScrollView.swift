import AppKit
import OSLog

/// 扩展里的显示层。
///
/// 主应用那套「白纸浮在毛玻璃上」是 Lightlyn 面板的视觉语言，快速查看面板不吃这一套——
/// 系统面板自己就是一张纸。所以这里正文直接铺满，只用固定行长把它按在中间。
///
/// 排版本身和主应用完全一致（同一个 `MarkdownRenderer`），差别只在容器：
/// 不带查找栏、不带缩放、不依赖 SwiftUI——快速查看面板不转发 ⌘F，也没有地方放查找条。
final class MarkdownScrollView: NSScrollView {
    /// 行长上限。窗口再宽也不让一行变得难读，多出来的宽度留白。
    static let readingWidth: CGFloat = 880
    private static let inset = NSSize(width: 32, height: 28)

    private let textView = MarkdownTextView()
    private var tableLayouts: [MarkdownRenderer.TableLayout] = []
    private var tableLayoutWidth: CGFloat?
    private var imageCells: [MarkdownRenderer.MarkdownImageCell] = []
    private var imageCap: CGFloat?
    /// 面板再矮也得给图片留出能看的高度
    private static let imageMinimum: CGFloat = 160

    /// 外部链接怎么打开由宿主决定，视图自己不认识扩展上下文
    var linkOpener: ((URL) -> Void)? {
        get { textView.openExternal }
        set { textView.openExternal = newValue }
    }

    /// 快速查看面板把扩展的视图合成进自己的容器里，`NSScrollView.drawsBackground`
    /// 到那儿不生效——«实测» 面板背景直接透出了桌面壁纸。所以自己铺一层，
    /// 并且声明不透明，别让面板把我们当成可以透视的材质。
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        // NSColor 是动态色，按 draw 时的外观解析，深浅色自动跟随，不用监听外观变化
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
        super.draw(dirtyRect)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsBackground = true
        backgroundColor = .textBackgroundColor
        hasVerticalScroller = true
        scrollerStyle = .overlay
        autohidesScrollers = true
        borderType = .noBorder
        contentView.drawsBackground = false

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = Self.inset
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.heightTracksTextView = false
        // 读 .layoutManager 会把 NSTextView 拉回 TextKit 1——这里是有意的：
        // 只有 TextKit 1 的 NSLayoutManager 支持 NSTextTable，表格全靠它。
        // 按需排版让首屏只排视口那一屏，大文档不必等全文排完。
        textView.layoutManager?.allowsNonContiguousLayout = true
        documentView = textView

        contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipDidChange),
                                               name: NSView.frameDidChangeNotification, object: contentView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit { NotificationCenter.default.removeObserver(self) }

    func setDocument(_ document: NSAttributedString) {
        textView.textStorage?.setAttributedString(document)
        // 表格列宽按整篇文档量一次，真正的宽度等容器定下来再填
        tableLayouts = MarkdownRenderer.tableLayouts(in: document)
        tableLayoutWidth = nil
        imageCells = MarkdownRenderer.imageCells(in: document)
        imageCap = nil
        applyGeometry()
        contentView.scroll(to: .zero)
        reflectScrolledClipView(contentView)
    }

    @objc private func clipDidChange(_ notification: Notification) { applyGeometry() }

    override func layout() {
        super.layout()
        applyGeometry()
    }

    private func applyGeometry() {
        let viewport = contentView.bounds
        guard viewport.width > 1, viewport.height > 1, let container = textView.textContainer else { return }
        let paperWidth = min(Self.readingWidth, viewport.width)
        let contentWidth = max(paperWidth - Self.inset.width * 2, 1)

        if tableLayoutWidth != contentWidth {
            tableLayoutWidth = contentWidth
            for table in tableLayouts { table.fit(in: contentWidth - container.lineFragmentPadding * 2) }
            if !tableLayouts.isEmpty, let storage = textView.textStorage {
                textView.layoutManager?.invalidateLayout(
                    forCharacterRange: NSRange(location: 0, length: storage.length), actualCharacterRange: nil)
                textView.needsDisplay = true
            }
        }
        // 竖图不该占满整个面板；按视口高度封顶，前后文才留得住
        let cap = max(viewport.height - Self.inset.height * 2, Self.imageMinimum)
        if imageCap != cap, !imageCells.isEmpty {
            imageCap = cap
            for cell in imageCells { cell.maxHeight = cap }
            if let storage = textView.textStorage {
                textView.layoutManager?.invalidateLayout(
                    forCharacterRange: NSRange(location: 0, length: storage.length), actualCharacterRange: nil)
                textView.needsDisplay = true
            }
        }

        container.containerSize = NSSize(width: contentWidth, height: .greatestFiniteMagnitude)
        textView.minSize = NSSize(width: paperWidth, height: viewport.height)
        // 窗口比行长宽时，多出来的宽度对半分到两侧
        let x = ((viewport.width - paperWidth) / 2).rounded()
        if textView.frame.origin.x != x || textView.frame.width != paperWidth {
            textView.setFrameOrigin(NSPoint(x: x, y: textView.frame.origin.y))
            textView.setFrameSize(NSSize(width: paperWidth, height: textView.frame.height))
        }
    }
}

/// 链接点击的落点。
///
/// `#锚点` 和脚注上标自己滚过去，其余交给宿主打开——**扩展是沙箱进程，
/// `NSWorkspace.open` 在这里不保证可用**，所以正经路子是 `NSExtensionContext.open`。
/// 由外面把 `openExternal` 填进来，视图自己不认识扩展上下文。
final class MarkdownTextView: NSTextView {
    /// 预览的是别人给的文件，链接地址同样不可信。只放行这四种协议。
    private static let openable: Set<String> = ["http", "https", "mailto", "file"]

    var openExternal: ((URL) -> Void)?

    private static let log = Logger(subsystem: "com.lightlyn.MDQL", category: "link")

    override func clicked(onLink link: Any, at charIndex: Int) {
        let url = (link as? URL) ?? (link as? String).flatMap { URL(string: $0) }
        // 地址本身按默认的 private 记：诊断只需要知道「点到了、解析出来了」，
        // 把别人文档里的链接明文写进系统日志和这个工具「预览不外发」的立场相悖。
        Self.log.info("点到链接 → \(url == nil ? "解析不出 URL" : "已解析", privacy: .public) \(url?.absoluteString ?? "", privacy: .private)")
        guard let url else { return }

        if url.scheme == MarkdownFootnotes.scheme,
           let index = Int(url.absoluteString.dropFirst(MarkdownFootnotes.scheme.count + 1)) {
            reveal(matching: .footnoteIndex) { ($0 as? Int) == index }
            return
        }
        if url.scheme == nil, url.absoluteString.hasPrefix("#") {
            let raw = String(url.absoluteString.dropFirst())
            let anchor = (raw.removingPercentEncoding ?? raw).lowercased()
            reveal(matching: .headingSlug) { ($0 as? String) == anchor }
            return
        }
        guard let scheme = url.scheme?.lowercased(), Self.openable.contains(scheme) else {
            Self.log.info("协议 \(url.scheme ?? "无", privacy: .public) 不在白名单，不打开")
            return
        }
        if openExternal == nil { Self.log.error("没人接管打开链接（linkOpener 为空）") }
        openExternal?(url)
    }

    /// 滚到锚点并闪一下——用查找用的那个黄色气泡，跳转之后眼睛得知道停在哪儿。
    private func reveal(matching key: NSAttributedString.Key, where matches: (Any) -> Bool) {
        guard let storage = textStorage else { return }
        var target: NSRange?
        storage.enumerateAttribute(key, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            if let value, matches(value) { target = range; stop.pointee = true }
        }
        guard let target else { return }
        // 先把目标下方也拉进视口，落点才不会贴在底边上
        let context = NSRange(location: target.location, length: min(240, storage.length - target.location))
        scrollRangeToVisible(context)
        scrollRangeToVisible(target)
        showFindIndicator(for: target)
    }
}
