<p align="center">
  <img src="docs/icon.png" width="128" alt="MDQL">
</p>

<h1 align="center">MDQL</h1>

<p align="center">给你 mac 电脑上的 QuickLook 加上 Markdown 支持，按下空格，文档出现</p>

## 特性

支持标题、列表、表格、代码高亮、公式、图片、原生 HTML、脚注、emoji，暂不支持远程图片与 mermaid

使用系统 API 与 TextKit 作为基础，对外部依赖尽可能删减，这意味着：

-   **快**：**99.97%** 的 Markdown 在 100ms 内渲染完成（M4 芯片，本机 83,284 份 Markdown 文件实测）
-   **小**：体积 **< 3 MB**，内存占用相比 HTML 方案低 **86%**
-   良好的深色模式适配

## 安装

1. 到 [Releases](https://github.com/getlightlyn/MDQL/releases) 下载对应芯片的包
   （Apple 芯片选 `arm64`，Intel 选 `x86_64`；不确定就看苹果菜单 →「关于本机」），解压后拖进「应用程序」
2. **打开一次**——系统要看到它启动过，才会把预览扩展注册进去
3. 在访达里选中任意 `.md`，按空格

### 第一次打开会被拦住

现在的版本还没做 Apple 公证，直接双击会提示"无法打开，因为无法验证开发者"。
放行一次即可，之后就正常了：

1. 先双击一次 MDQL.app，让它被拦下来
2. 打开「系统设置 → 隐私与安全性」，往下翻到"已阻止 MDQL"
3. 点「仍要打开」

嫌麻烦的话，一条命令等效：

```sh
xattr -d com.apple.quarantine /Applications/MDQL.app
```

### 预览没有变化？

`.md` 可能被别的扩展占着。到「系统设置 → 通用 → 登录项与扩展 → 快速查看」里，把其它 Markdown 预览关掉、只留 MDQL。

确认是否注册成功：

```sh
pluginkit -m -i com.lightlyn.MDQL.QLExtension
```

## 自己编译

```sh
./build.sh release                    # 本机架构，产物在 dist/MDQL.app
./build.sh release --arch x86_64      # 指定架构
./build.sh release --universal        # 两个架构打进一个包
```

## 许可

MIT，见 [LICENSE](LICENSE)。第三方素材与依赖见 [NOTICE](NOTICE)。
有渲染相关的问题欢迎提交 issue；扩展本身、打包脚本、文档欢迎直接提 PR。
