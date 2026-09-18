import AppKit

/// MDQL 的宿主应用。
///
/// macOS 不接受裸的 appex——扩展必须装在一个应用包里，系统才会把它注册进快速查看。
/// 所以这个应用只做两件事：**存在**，以及告诉你去哪里打开它。不做设置界面：
/// 能调的选项越少，「为什么我的预览和别人不一样」就越少。
final class Delegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .centerX
        content.spacing = 14
        content.edgeInsets = NSEdgeInsets(top: 36, left: 40, bottom: 36, right: 40)

        let title = NSTextField(labelWithString: "MDQL")
        title.font = .systemFont(ofSize: 28, weight: .semibold)

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let subtitle = NSTextField(labelWithString: "Markdown 快速查看扩展 · \(version)")
        subtitle.textColor = .secondaryLabelColor

        let hint = NSTextField(wrappingLabelWithString: """
            在访达里选中 .md 文件按空格即可预览。
            如果没有生效，多半是同类扩展不止一个——系统只会挑一个用，\
            到「系统设置 → 通用 → 登录项与扩展 → 快速查看」里只勾选 MDQL。
            """)
        hint.alignment = .center
        hint.textColor = .secondaryLabelColor
        hint.preferredMaxLayoutWidth = 380

        let button = NSButton(title: "打开系统设置", target: self, action: #selector(openSettings))
        button.bezelStyle = .rounded
        button.keyEquivalent = "\r"

        for view in [title, subtitle, hint, button] { content.addArrangedSubview(view) }

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 260),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "MDQL"
        window.contentView = content
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openSettings() {
        // Ventura 之后的扩展面板；打不开就退回系统设置本身，不留一个点了没反应的按钮。
        let panel = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences")!
        if !NSWorkspace.shared.open(panel) {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let application = NSApplication.shared
let delegate = Delegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
