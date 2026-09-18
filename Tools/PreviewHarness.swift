import AppKit

/// 把扩展的 `PreviewViewController` 放进一个普通窗口里跑一遍并截图。
///
/// 快速查看面板（⌥Space）没法自动化，装扩展又会抢掉系统里现有的 .md 预览。
/// 所以验收走这条路：**同一份控制器、同一份渲染器**，只是宿主换成一个普通窗口。
/// 这能证伪的是「扩展自己的代码路径有没有问题」；证明不了的是系统注册和沙箱，
/// 那两件仍然要真装一次才算数。
@main @MainActor enum PreviewHarness {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count >= 2 else { print("用法: harness <文件.md> <输出目录>"); exit(2) }
        let url = URL(fileURLWithPath: args[0])
        let output = URL(fileURLWithPath: args[1])
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)

        Task { @MainActor in
            try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let controller = PreviewViewController()
            // 第三、四个参数可以指定窗口大小，用来模拟快速查看面板的真实尺寸
            let width = args.count > 2 ? Double(args[2]) ?? 1000 : 1000
            let height = args.count > 3 ? Double(args[3]) ?? 760 : 760
            let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: width, height: height),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.title = url.lastPathComponent
            window.contentViewController = controller
            window.orderFrontRegardless()

            let started = CFAbsoluteTimeGetCurrent()
            do { try await controller.preparePreviewOfFile(at: url) }
            catch { print("FAIL 渲染失败: \(error)"); exit(1) }
            let elapsed = (CFAbsoluteTimeGetCurrent() - started) * 1000
            controller.view.layoutSubtreeIfNeeded()
            print(String(format: "PASS %@ 准备完成 %.1f ms", url.lastPathComponent, elapsed))

            for (index, appearance) in [NSAppearance.Name.aqua, .darkAqua].enumerated() {
                window.appearance = NSAppearance(named: appearance)
                try? await Task.sleep(for: .milliseconds(450))
                let name = "\(url.deletingPathExtension().lastPathComponent)-\(index == 0 ? "浅色" : "深色").png"
                let target = output.appendingPathComponent(name)
                let capture = Process()
                capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                capture.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", target.path]
                try? capture.run(); capture.waitUntilExit()
                print(capture.terminationStatus == 0 ? "PASS 截图 \(name)" : "FAIL 截图 \(name)")
            }
            exit(0)
        }
        application.run()
    }
}
