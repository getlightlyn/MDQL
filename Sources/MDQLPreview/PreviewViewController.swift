import AppKit
import MDQLOpenerKit
import OSLog
import Quartz

/// MDQL 的快速查看预览控制器。
///
/// 系统把 .md 交过来，我们同步渲染完再返回——`preparePreviewOfFile` 返回之前
/// 面板不会显示，所以这里**不能**先给一个空视图再异步填：那会闪一下白。
/// 实测常见 README（10–30KB）解析加首屏排版在 5–20ms，同步做完全来得及。
@MainActor
final class PreviewViewController: NSViewController, QLPreviewingController {
    /// 超过这个大小就不做格式化渲染。Foundation 的 Markdown 解析成本随文件线性涨，
    /// 而且没法只解析一屏：512KiB 约 340ms，1MiB 就要小半秒。
    /// 这种尺寸的 .md 多半是导出的数据或日志，退回等宽纯文本反而更快、也一样能读。
    private static let plainTextLimit = 8 * 1024 * 1024

    static let log = Logger(subsystem: "com.lightlyn.MDQL", category: "link")

    private let scroll = MarkdownScrollView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))

    /// 打开外部链接。
    ///
    /// 快速查看扩展是**强制沙箱**的，这件事在扩展进程里做不到：
    /// `NSExtensionContext.open` 需要宿主实现 openURL 服务，快速查看的宿主不实现；
    /// `NSWorkspace.open` 在沙箱的扩展进程里也不生效——«踩过» 两条都调了、日志都进了，
    /// 浏览器就是不起来。所以真正干活的是随包分发的 `MDQLOpener.xpc`：
    /// 它**没有 app-sandbox**，由 launchd 按需拉起、用完自己退出，我们不管它的生命周期。
    /// （QLMarkdown 的 external-launcher.xpc 是同一个办法。）
    ///
    /// 前两条仍然留着当兜底：万一哪天系统开了口子，或者 XPC 服务没打进包里。
    private static func open(_ url: URL, through context: NSExtensionContext?) {
        guard MDQLOpener.permits(url) else {
            log.info("协议不在白名单，不打开")
            return
        }
        let connection = NSXPCConnection(serviceName: MDQLOpener.serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: MDQLOpening.self)
        connection.resume()
        let service = connection.remoteObjectProxyWithErrorHandler { error in
            log.error("XPC 连不上：\(error.localizedDescription, privacy: .public)")
            fallback(url, through: context)
            connection.invalidate()
        } as? MDQLOpening
        guard let service else {
            fallback(url, through: context)
            connection.invalidate()
            return
        }
        service.open(url) { opened in
            log.info("XPC 打开链接 → \(opened ? "成功" : "失败", privacy: .public)")
            if !opened { fallback(url, through: context) }
            connection.invalidate()
        }
    }

    /// XPC 走不通时再试系统的两条路，都失败就只能记一笔
    private static func fallback(_ url: URL, through context: NSExtensionContext?) {
        if let context {
            context.open(url) { opened in
                log.info("extensionContext.open → \(opened ? "成功" : "被拒", privacy: .public)")
                if !opened {
                    let direct = NSWorkspace.shared.open(url)
                    log.info("NSWorkspace.open → \(direct ? "成功" : "失败", privacy: .public)")
                }
            }
        } else {
            let direct = NSWorkspace.shared.open(url)
            log.info("没有 extensionContext；NSWorkspace.open → \(direct ? "成功" : "失败", privacy: .public)")
        }
    }

    override func loadView() { view = scroll }

    func preparePreviewOfFile(at url: URL) async throws {
        // 沙箱只保证被预览的文件本身可读；同目录的图片要不要能读见 README 的说明。
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard let document = MarkdownRenderer.render(contentsOf: url) ?? Self.plainText(url) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        scroll.setDocument(document)
        scroll.linkOpener = { [weak self] target in
            Self.open(target, through: self?.extensionContext)
        }
    }

    /// 超限或者解码失败时的兜底：等宽显示源码，并说明为什么没有排版。
    /// 不伪装成全文，也不留空白页。
    private static func plainText(_ url: URL) -> NSAttributedString? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        let slice = data.prefix(plainTextLimit)
        guard let text = String(data: slice, encoding: .utf8)
            ?? String(data: slice, encoding: .utf16)
            ?? String(data: slice, encoding: .isoLatin1) else { return nil }

        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.25
        let body = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.textColor,
            .paragraphStyle: style,
        ])
        if data.count > slice.count {
            let note = NSMutableParagraphStyle()
            note.alignment = .center
            note.paragraphSpacingBefore = 24
            body.append(NSAttributedString(string: "\n\n" + Strings.truncated + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: note,
            ]))
        }
        return body
    }
}

enum Strings {
    static var truncated: String {
        Bundle.main.localizedString(forKey: "preview.truncated", value:
            "文件过大，只显示开头部分", table: nil)
    }
}
