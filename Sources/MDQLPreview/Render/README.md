# 渲染器（副本，勿改）

这个目录里的 `.swift` 是从 **Lightlyn** 同步下来的只读副本，上游在那边。
在这里改了也留不住：下一次 `./Tools/sync-render.sh` 会原样覆盖，
而且 `./Tools/check-render.sh` 会在构建时直接拦下来。

要改渲染行为：

1. 在 Lightlyn 里改 `Sources/LightlynApp/Preview/Formats/Text/`
2. 回到本仓库跑 `./Tools/sync-render.sh`，`SOURCE.json` 会记下上游的 commit

**外部贡献者**：渲染器的改动请开 issue 说明，我们在上游落地后同步下来；
扩展自己的代码（`PreviewViewController.swift`、`MarkdownScrollView.swift`、
宿主应用、打包脚本）欢迎直接提 PR。

这几个文件只依赖 AppKit / Foundation / SwiftMath——不引 SwiftUI、不碰任何应用状态，
所以能原样搬过来编。这个约束是上游的硬规矩，破了两边都编不过。
