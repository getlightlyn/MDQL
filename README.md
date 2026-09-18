# MDQL

macOS 的 Markdown 快速查看扩展。在访达里按空格就能看，**不用 WebView**。

扩展整体 2.1 MB，常见 README 首屏 5–20 ms，公式和正文在同一帧出来。

## 为什么不用 WebView

主流的 Markdown 快速查看扩展都是 `cmark → HTML → WKWebView`。cmark 本身很快
（433 KB 的文档只要 19 ms），慢的是后面两段：

- WKWebView 要另起一个 WebContent 进程，建视图到第一帧合成有大约 **80–120 ms 的地板**，
  文件再小也得付；
- 公式和图表只能交给 JS 库。以 MathJax 为例，冷缓存 **1.8–2.3 秒**，
  磁盘缓存热了、新进程第一次仍要 **约 220 ms**——而且是**先把 `$...$` 原样显示出来、
  等库回来再重排**，所以你会看到文字先上屏、公式后跳动。

MDQL 走 `Foundation AttributedString → TextKit`：Foundation 的解析比 cmark 慢
（同样 433 KB 要 340 ms），但它没有那 80 ms 的地板，公式由 SwiftMath 本地矢量排版，
和正文在同一帧完成。**交叉点在 200 KB 附近**——日常 README 是 10–30 KB，
落在快 6–18 倍的那一侧；真到几百 KB 的导出文件，WebView 那条路更快，
所以超过 512 KB 我们直接退回等宽纯文本，不硬撑。

| | 本机实测（M4 / macOS 27） | MDQL | cmark + WKWebView |
|---|---|---|---|
| 10 KB 中文文档 | 首帧 | **4.4 ms** | 81 ms |
| 24 KB README | 首帧 | **18 ms** | 120 ms |
| 6.7 KB，47 个公式 | 公式排完 | **4.1 ms** | 1468–1837 ms（冷）/ 220 ms（热） |
| 216 KB 文档 | 宿主内存 | **+22 MB** | 另起进程峰值约 97 MB |
| 扩展体积 | arm64 | **2.1 MB** | 10.9 MB |

## 支持

标题、列表（含任务列表和多级嵌套）、引用、表格（对齐、隔行底色、按内容估列宽）、
代码块（自写 tokenizer 着色，无第三方依赖）、行内格式、本地图片、分隔线、硬换行。

解析器不管、我们补上的四样：

- **原生 HTML** —— `b/i/u/s/code/kbd/mark/small/sub/sup/a/img/br/hr`、`align="center"`、
  `<details>`。注释和 `script/style/iframe` 连内容丢掉，认不出的标签只留内容。
- **脚注** —— `[^1]` 上标 + 文末列表，编号按首次引用。
- **emoji 短码** —— 1725 条 gemoji 表，代码块里的不动。
- **数学** —— `$...$` / `$$...$$` / `\(...\)` / `\[...\]`，SwiftMath 本地排版。

链接：相对链接按文件所在目录解析，`#锚点` 和脚注上标在文内滚动定位，
外链交给系统打开——**这一步比看上去麻烦，见下**。

### 开外部链接为什么要带一个 XPC 服务

快速查看扩展是**强制沙箱**的，在扩展进程里开不了外部链接：

- `NSExtensionContext.open` 是苹果给扩展的正规 API，但要**宿主实现 openURL 服务**，
  快速查看的宿主不实现；
- `NSWorkspace.open` 在沙箱的扩展进程里也不生效。

«实测» 两条都调过、日志都进了，浏览器就是不起来。所以真正干活的是随包分发的
`MDQLPreview.appex/Contents/XPCServices/MDQLOpener.xpc`（64 KB）：
它的 entitlements 是空的、**不带 `app-sandbox`**，在那里 `NSWorkspace.open` 正常。
服务由 launchd 按需拉起、闲置回收，不需要我们管理生命周期。
QLMarkdown 的 `external-launcher.xpc` 是同一个办法。

它跑在沙箱外，所以是一道权限边界：**协议白名单判在服务端**
（`http/https/mailto/file`），客户端那份只是省一次 IPC，不是安全边界。

**不支持**：mermaid（见下）、`==高亮==`、嵌套引用的层级、裸 `www.` 自动链接、远程图片。

## 真实文档验收

`Tools/BatchScan.swift` 扫一批文档，不光看崩不崩，还**自动检出渲染不干净的痕迹**：
排完之后正文里还剩 `<tag>`、`[^1]`、`:smile:`、`$...$`、`\command`，
就说明那条语法没接住，只是没报错——这种失败不会自己喊出来。
判据会跳过代码块和行内代码（那里的 `$VAR`、`<div>` 本来就该原样保留），
不然真问题会淹在误报里。

```sh
./Tools/build-scan.sh && .build/BatchScan.app/Contents/MacOS/harness 某目录/*.md
```

拿 GitHub 上 35 份真实 README 跑过一轮（vscode / react / rust / pytorch / kubernetes /
fzf / KaTeX / mermaid / JavaGuide / awesome-mac 等，含中英文、数学、图表、大量原生 HTML）：

```
共 35 份：渲染失败 0，有残留 0
合计 706ms，平均 20.2ms，最慢 awesome-mac.md（256KB）181.6ms
```

期间抓到并修掉的真实问题：fzf 用 `<kbd align="center">` 圈住一整段来画边框，
按行内按键那样上底色，底色会贴着字形走，居中之后一行一个宽度、看着像渲染坏了。
带对齐属性的 `<kbd>` 现在当透明容器处理。

## 编译

```sh
./build.sh release          # 产物在 dist/MDQL.app
```

安装：把 `dist/MDQL.app` 拖进 `/Applications` 并打开一次，系统才会注册扩展。
如果 .md 的预览没变，多半是同类扩展不止一个——系统只挑一个用，
到「系统设置 → 通用 → 登录项与扩展 → 快速查看」里只留 MDQL。

```sh
pluginkit -m -i com.lightlyn.MDQL.QLExtension    # 确认注册
./Tools/build-harness.sh && .build/PreviewHarness.app/Contents/MacOS/harness 某文件.md 输出目录
```

最后这条是验收用的测试台：快速查看面板没法自动化，装扩展又会抢掉系统里现有的 .md 预览，
所以它把**扩展真正的 `PreviewViewController`** 放进一个普通窗口跑一遍，深浅色各截一张图。
它能证伪扩展自己的代码路径；证明不了系统注册和沙箱，那两件仍然要真装一次。

## 和 Lightlyn 的关系

渲染器的上游在 **Lightlyn**（闭源商业软件），本仓库里的 `Sources/MDQLPreview/Render/`
是从那边**同步下来的只读副本**——真文件，不是链接，clone 下来就能编。

这个方向是有意的：Lightlyn 分发出去的东西要保持干净，不为了共享去背一个外部依赖；
本仓库也不反向依赖任何闭源代码。代价是**渲染器不接受本仓库的 PR**——
改动请开 issue，我们在上游落地后同步下来。扩展自己的代码（`PreviewViewController.swift`、
`MarkdownScrollView.swift`、宿主应用、打包脚本）欢迎直接提 PR。

```sh
./Tools/sync-render.sh    # 从 Lightlyn 同步，刷新 Render/SOURCE.json 里的 commit 和校验和
./Tools/check-render.sh   # 校验没被就地改过；build.sh 每次都会跑
```

共享的只有这六个文件，它们只依赖 AppKit / Foundation / SwiftMath，
不引 SwiftUI、不碰应用状态——这条约束是上游的硬规矩，破了两边都编不过：

```
MarkdownRenderer.swift    Markdown → TextKit 属性串
MarkdownMath.swift        公式（SwiftMath）
MarkdownHTML.swift        原生 HTML
MarkdownFootnotes.swift   脚注
MarkdownEmoji.swift       emoji 短码
SyntaxHighlighter.swift   代码着色
```

界面各自实现：主应用是 SwiftUI 的 `MarkdownPreviewView`，
扩展是 `PreviewViewController` + `MarkdownScrollView`。

## 沙箱

扩展必须沙箱，系统只保证**被预览的文件本身**可读——旁边的 `assets/img/logo.png` 读不到。
所有 Markdown 快速查看扩展都要面对这一条。

实测（macOS 27，`qlmanage -x -p` 走真实的 QuickLookUIService）：

| 图片位置 | 不加例外 | 加 home 只读例外 |
|---|---|---|
| 同级目录 | ✗ | ✓ |
| 子目录 `assets/img/` | ✗ | ✓ |
| 上一级 `../` | ✗ | ✓ |
| 远程 http(s) | ✗ | ✗（见下） |

注意 `/private/tmp` 下三种都能读——那里没有保护，**别拿它当验证环境**，我一开始就被它骗过。

所以扩展申请了 `com.apple.security.temporary-exception.files.home-relative-path.read-only`。
范围收窄到用户主目录：覆盖 `~/Documents`、`~/Desktop`、`~/Downloads` 和代码仓库，
不碰系统目录和外接卷，且只读。QLMarkdown 开的是整盘的 `absolute-path` 版本。
代价是放在外接卷或 `/opt` 下的文档读不到旁边的图，会退回替代文字。

### 为什么不申请网络

远程图片（README 顶上那排徽章）需要 `com.apple.security.network.client`。没加，而且这个
决定不只是少一个 entitlement：

- 光加权限没有用——得真去下载。而渲染是**同步**的，`preparePreviewOfFile` 返回前面板不显示：
  要么卡在网络上（网慢或断网时预览直接挂住），要么先出替代文字、图到了再重排——
  那正是本项目一直在批评 MathJax 的那种跳动。
- 更重要的是：**预览一个来路不明的 .md 不会向外发任何请求**。追踪像素、IP 泄露都没机会。
  对一个专门用来看陌生文件的工具，这是实打实的属性。

要加的话应该是：后台抓取 + 短超时 + 单图大小上限 + 宿主应用里的开关，默认关。

## mermaid

现在显示成代码块。要真画出来只有三条路：

1. **只为 mermaid 块挂一个 WKWebView** —— 最省事，但 WebKit 和那个独立进程又回来了，
   本项目全部的体积和速度优势建立在没有它上面。
2. **JavaScriptCore 跑 mermaid** —— JSC 是系统框架，不额外占体积也不另起进程。
   但 mermaid 的布局依赖真实 DOM 的 `getBBox()` 量文字，官方的非浏览器方案
   （mermaid-cli）用的是 Puppeteer，也就是一整个 headless Chrome。
   换个 JS 引擎解决不了，得自己补一层够用的 DOM/SVG 垫片，脆且跟不动上游版本。
3. **自己画常见的那几种** —— 解析 `flowchart`/`graph`（TD/LR）和 `sequenceDiagram`，
   用 CoreText 量字、分层布局、CoreGraphics 画成附件，和公式走同一条路。
   README 里的 mermaid 绝大多数就是这两类。工作量真实，但架构上是干净的。

倾向第 3 条，作为后面的一个里程碑；在那之前保持现状——显示源码总比显示一个空框好。

## 许可

MIT。emoji 短码表来自 [gemoji](https://github.com/github/gemoji)，
公式排版来自 [SwiftMath](https://github.com/mgriebling/SwiftMath)。
