import Foundation

/// 扩展和开链接服务之间的约定。
///
/// 两边都要用到，所以单独成一个小 target——XPC 的协议一旦两边写歪就是运行时静默失败，
/// 编译期共享一份比复制两遍靠谱。
@objc public protocol MDQLOpening {
    /// 打开一个链接。回调告诉调用方系统到底接没接。
    func open(_ url: URL, withReply reply: @escaping (Bool) -> Void)
}

public enum MDQLOpener {
    /// XPC 服务的 bundle id，也是 NSXPCConnection 的 serviceName
    public static let serviceName = "com.lightlyn.MDQL.opener"

    /// 只放行这四种协议。
    /// **这个判断必须留在服务端**：服务跑在沙箱外，谁能连上它谁就能让系统打开任意 URL。
    /// 客户端那边也查一遍，但那只是省一次 IPC，不是安全边界。
    public static let allowed: Set<String> = ["http", "https", "mailto", "file"]

    public static func permits(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return allowed.contains(scheme)
    }
}
