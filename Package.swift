// swift-tools-version: 6.0
import PackageDescription

/// MDQL —— macOS 的 Markdown 快速查看扩展。
///
/// 渲染器（`Sources/MDQLPreview/Render`）是从 Lightlyn 同步下来的**只读副本**，
/// 单向：上游改完跑 `Tools/sync-render.sh` 拿下来，`SOURCE.json` 记下每个文件的 sha256，
/// `Tools/check-render.sh` 在每次构建前校验它没被就地改过。
///
/// 全部编进同一个模块，所以共享的那几个文件不需要为了跨模块把类型变成 public。
let package = Package(
    name: "MDQL",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "MDQL", targets: ["MDQLApp"]),
        .executable(name: "MDQLPreview", targets: ["MDQLPreview"]),
        .executable(name: "MDQLOpener", targets: ["MDQLOpener"]),
    ],
    dependencies: [.package(url: "https://github.com/mgriebling/SwiftMath.git", exact: "1.7.3")],
    targets: [
        // 宿主应用：macOS 不接受裸的 appex，扩展必须装在应用包里才会被注册
        .executableTarget(name: "MDQLApp", swiftSettings: [.swiftLanguageMode(.v5)]),
        // 扩展和开链接服务共享的协议
        .target(name: "MDQLOpenerKit", swiftSettings: [.swiftLanguageMode(.v5)]),
        // 开链接的 XPC 服务。**不加 -application-extension**：它不是扩展，
        // 而且正因为它不在沙箱里，NSWorkspace 在这里才有效。
        .executableTarget(name: "MDQLOpener", dependencies: ["MDQLOpenerKit"],
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(
            name: "MDQLPreview",
            dependencies: [.product(name: "SwiftMath", package: "SwiftMath"), "MDQLOpenerKit"],
            // Render/ 里的说明文档和同步清单不是源码
            exclude: ["Render/README.md", "Render/SOURCE.json"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                // 扩展不能用 NSApplication 那套 API，编译期就拦住
                .unsafeFlags(["-application-extension"]),
            ],
            // appex 的入口是 NSExtensionMain，不是 main()
            linkerSettings: [.unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])]
        ),
    ]
)
