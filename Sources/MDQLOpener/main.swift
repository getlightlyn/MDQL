import AppKit
import MDQLOpenerKit

/// 开链接的 XPC 服务。
///
/// 存在的唯一理由：**快速查看扩展是强制沙箱的，在里面开不了外部链接**。
/// `NSExtensionContext.open` 要宿主实现这个服务，而快速查看的宿主不实现；
/// `NSWorkspace.open` 在沙箱的扩展进程里也不生效。
/// 所以把这一件事挪到一个**不带 app-sandbox 的 XPC 服务**里做——
/// 它随扩展一起打包、由 launchd 按需拉起，用完自己退出，我们不管理它的生命周期。
/// QLMarkdown 用的也是这个办法（它那个叫 external-launcher.xpc）。
///
/// 这个进程在沙箱外，所以它是一道权限边界：协议白名单必须在这里判，
/// 不能只信客户端传过来的东西。
final class OpenerService: NSObject, MDQLOpening {
    func open(_ url: URL, withReply reply: @escaping (Bool) -> Void) {
        guard MDQLOpener.permits(url) else { return reply(false) }
        reply(NSWorkspace.shared.open(url))
    }
}

final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: MDQLOpening.self)
        connection.exportedObject = OpenerService()
        connection.resume()
        return true
    }
}

let delegate = ServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
