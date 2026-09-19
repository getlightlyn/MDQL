import AppKit

/// 界面文案按系统语言取。`Resources/<语言>.lproj/Localizable.strings` 里各一份，
/// 系统语言不在里面就退回 en（`CFBundleDevelopmentRegion`）。
func T(_ key: String, _ arguments: CVarArg...) -> String {
    let format = NSLocalizedString(key, comment: "")
    return arguments.isEmpty ? format : String(format: format, arguments: arguments)
}

/// 扩展在系统里的状态。
///
/// 问的是 `pluginkit`，不是我们自己的记录——用户在系统设置里勾掉的那一下只有它知道。
enum ExtensionStatus {
    /// 注册了、没被停用，而且注册的就是本应用包里这一份
    case enabled
    /// 系统压根没见过这个扩展（应用还没打开过，或者不在「应用程序」里）
    case unregistered
    /// 注册了，但在系统设置里被关掉了
    case disabled
    /// 系统认的是另一个位置上的 MDQL：多半是下载目录里还留着一份旧的
    case otherCopy(String)

    var ok: Bool { if case .enabled = self { return true }; return false }

    var summary: String {
        switch self {
        case .enabled:      return T("status.enabled")
        case .unregistered: return T("status.unregistered")
        case .disabled:     return T("status.disabled")
        case .otherCopy:    return T("status.othercopy")
        }
    }

    /// 摘要下面那行具体怎么办；已启用的时候不需要
    var detail: String? {
        switch self {
        case .enabled:      return nil
        case .unregistered: return T("detail.unregistered")
        case .disabled:     return T("detail.disabled")
        case .otherCopy(let path): return T("detail.othercopy", path)
        }
    }

    var color: NSColor { ok ? .systemGreen : .systemOrange }
}

enum ExtensionProbe {
    static let identifier = "com.lightlyn.MDQL.QLExtension"

    /// 向 pluginkit 问一次。实测 10ms 以内，同步调就行。
    ///
    /// 匹配上的话输出一行，第一列是状态位（`-` 停用，`+` 显式启用，空格是默认）：
    ///
    ///     `     com.lightlyn.MDQL.QLExtension(0.1.0)\t<UUID>\t<日期>\t<appex 路径>`
    ///
    /// «踩过» 没装上的时候它打印「(no matches)」并且**照样退出 0**，所以不能只看退出码。
    static func run() -> ExtensionStatus {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        task.arguments = ["-m", "-v", "-i", identifier]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return .unregistered }
        // 先读完再等退出：反过来会在管道写满时卡死
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        let output = String(decoding: data, as: UTF8.self)
        guard let line = output.split(separator: "\n").first(where: { $0.contains(identifier) })
        else { return .unregistered }
        if line.hasPrefix("-") { return .disabled }

        // 第 4 个 tab 字段是 appex 的路径。它该在本应用包里，不然系统认的是别人。
        let fields = line.components(separatedBy: "\t")
        guard fields.count > 3 else { return .enabled }
        let registered = resolve(fields[3])
        let mine = resolve(Bundle.main.bundlePath)
        guard !registered.hasPrefix(mine + "/") else { return .enabled }
        // 从 appex 往上退三级回到那份 .app，路径给用户看的是应用而不是扩展
        let app = URL(fileURLWithPath: registered)
            .deletingLastPathComponent()   // PlugIns
            .deletingLastPathComponent()   // Contents
            .deletingLastPathComponent()   // MDQL.app
        return .otherCopy(app.path)
    }

    /// `/var` 和 `/private/var` 这类软链两边得先拉齐，否则同一份也比不相等
    private static func resolve(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }
}

/// MDQL 的宿主应用。
///
/// macOS 不接受裸的 appex——扩展必须装在一个应用包里，系统才会把它注册进快速查看。
/// 所以这个应用只做两件事：**存在**，以及告诉你扩展现在到底生效没有。不做设置界面：
/// 能调的选项越少，「为什么我的预览和别人不一样」就越少。
final class Delegate: NSObject, NSApplicationDelegate {
    private static let width: CGFloat = 460

    private var window: NSWindow!
    private let status = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private lazy var button = NSButton(title: T("open.settings"), target: self, action: #selector(openSettings))

    func applicationWillFinishLaunching(_ notification: Notification) {
        // 没有主菜单的话 ⌘W / ⌘Q / ⌘M 全是死的——这些快捷键是菜单项带来的，不是窗口自带的
        NSApp.mainMenu = makeMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .centerX
        content.spacing = 14
        content.edgeInsets = NSEdgeInsets(top: 36, left: 40, bottom: 36, right: 40)

        let title = NSTextField(labelWithString: "MDQL")
        title.font = .systemFont(ofSize: 28, weight: .semibold)

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let subtitle = NSTextField(labelWithString: T("subtitle", version))
        subtitle.textColor = .secondaryLabelColor

        let hint = NSTextField(wrappingLabelWithString: T("hint"))
        hint.alignment = .center
        hint.textColor = .secondaryLabelColor
        hint.preferredMaxLayoutWidth = 380

        status.font = .systemFont(ofSize: 13, weight: .medium)
        detail.alignment = .center
        detail.textColor = .secondaryLabelColor
        detail.preferredMaxLayoutWidth = 380

        button.bezelStyle = .rounded
        button.keyEquivalent = "\r"

        for view in [title, subtitle, hint, status, detail, button] { content.addArrangedSubview(view) }
        refresh()

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 300),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "MDQL"
        window.contentView = content
        fitWindow()
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 窗口高度跟着内容走：按钮藏起来的时候不该在下面留一大片空白。
    /// 从上边缘往下长，标题栏不动。
    private func fitWindow() {
        guard let window, let content = window.contentView else { return }
        let height = content.fittingSize.height
        guard height > 0 else { return }
        var frame = window.frame
        let target = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: Self.width, height: height))
        frame.origin.y += frame.height - target.height
        frame.size = target.size
        window.setFrame(frame, display: true, animate: false)
    }

    /// 从系统设置切回来时再问一遍：用户刚勾上的那一下，界面要自己跟上
    func applicationDidBecomeActive(_ notification: Notification) { refresh() }

    /// 检查过了才决定显不显示按钮——没问题的时候不该摆一个没用的入口
    private func refresh() {
        let state = ExtensionProbe.run()
        status.stringValue = state.summary
        status.textColor = state.color
        detail.stringValue = state.detail ?? ""
        detail.isHidden = state.detail == nil
        button.isHidden = state.ok
        fitWindow()
    }

    @objc private func openSettings() {
        // Ventura 之后的扩展面板；打不开就退回系统设置本身，不留一个点了没反应的按钮。
        let panel = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences")!
        if !NSWorkspace.shared.open(panel) {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
        }
    }

    /// 够用就行的主菜单：只要标准的关闭、最小化、隐藏和退出。
    private func makeMenu() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "MDQL")
        appMenu.addItem(withTitle: T("menu.about"),
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: T("menu.hide"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: T("menu.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: T("menu.window"))
        windowMenu.addItem(withTitle: T("menu.close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: T("menu.minimize"),
                           action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        return main
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let application = NSApplication.shared
let delegate = Delegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
