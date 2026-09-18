<p align="center">
  <img src="docs/icon.png" width="128" alt="MDQL">
</p>

<h1 align="center">MDQL</h1>

<p align="center">给你 mac 电脑上的 QuickLook 加上 Markdown 支持，按下空格，文档出现</p>

<p align="center"><em>Markdown preview extension for macOS QuickLook</em></p>

## 特性

支持标题、列表、表格、代码高亮、公式、图片、原生 HTML、脚注、emoji，暂不支持远程图片与 mermaid

使用系统 API 与 TextKit 作为基础，对外部依赖尽可能删减，这意味着：

-   **快**：99.5% Markdown 渲染不等待，至多比 HTML 快 **20x**
-   **小**：体积仅 **2.2 MB**，内存消耗相比 HTML 方案低 **70%+**
-   良好的深色模式适配

## 安装

1. 下载 `MDQL.app`，拖进「应用程序」
2. **打开一次**——系统要看到它启动过，才会把预览扩展注册进去
3. 在访达里选中任意 `.md`，按空格

### 第一次打开会被拦住

现在的版本还没做 Apple 公证，直接双击会提示"无法打开，因为无法验证开发者"。绕过一次即可：

**右键点 MDQL.app → 打开 → 再点「打开」。**

用右键菜单里的「打开」，和双击走的是两条路——这条会给你一个"仍要打开"的按钮。
只需要做一次，之后就正常了。

如果右键也没有「打开」选项，在「系统设置 → 隐私与安全性」往下翻，会看到
"已阻止 MDQL"，点旁边的「仍要打开」。

### 预览没有变化？

`.md` 可能被别的扩展占着，**系统只会挑一个用**。到
「系统设置 → 通用 → 登录项与扩展 → 快速查看」里，把其它 Markdown 预览关掉、只留 MDQL。

确认是否注册成功：

```sh
pluginkit -m -i com.lightlyn.MDQL.QLExtension
```

## 自己编译

```sh
./build.sh release          # 产物在 dist/MDQL.app
```

## 许可

MIT，见 [LICENSE](LICENSE)。第三方素材与依赖见 [NOTICE](NOTICE)。
有渲染相关的问题欢迎提交 issue；扩展本身、打包脚本、文档欢迎直接提 PR。
