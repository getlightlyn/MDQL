#!/usr/bin/env python3
"""从 gemoji 重新生成 MarkdownEmoji.swift 里的短码表。

为什么要有这个脚本：表的内容是「短码 → 表情字符」的事实映射，源头是 GitHub 的
gemoji（MIT）。但最初那一份是从 QLMarkdown 的二进制里 strings 出来的，而 QLMarkdown
链了 GPL 的 highlight 库、整体是 GPL——数据本身不因此变成 GPL，可是**来源说不清**。
对一个要挂 MIT 的仓库，来源必须是可引用的，所以用这个脚本从上游重新生成一遍。

    python3 Tools/generate-emoji-table.py            # 联网拉 gemoji
    python3 Tools/generate-emoji-table.py emoji.json # 用本地已下载的

生成的文件要写回**上游 Lightlyn**，不是这个仓库——渲染器在这里是只读副本。
写完回来跑 ./Tools/sync-render.sh。
"""
import json
import sys
import urllib.request
from pathlib import Path

GEMOJI = "https://raw.githubusercontent.com/github/gemoji/master/db/emoji.json"
ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUT = ROOT / "../Lightlyn/Sources/LightlynApp/Preview/Formats/Text/MarkdownEmoji.swift"

TEMPLATE = '''import AppKit

/// GitHub 风格的 emoji 短码（`:smile:` → 😄）。
///
/// CommonMark 没有这个语法，Foundation 也不认，短码会原样留在正文里。
/// 表是「名字 空格 表情」一行一条，**首次真的遇到短码才切开**——
/// {count} 条，不值得为没有短码的文档付这份钱。
///
/// 数据来自 gemoji（MIT），由 Tools/generate-emoji-table.py 生成，不要手改。
enum MarkdownEmoji {{
    /// 短码只由小写字母、数字、下划线和加减号组成；两端的冒号不参与捕获。
    private static let pattern = try! NSRegularExpression(pattern: #":([a-z0-9_+-]{{1,40}}):"#)

    private static let table: [String: String] = {{
        var result: [String: String] = [:]
        result.reserveCapacity({capacity})
        for line in packed.split(separator: "\\n") {{
            guard let space = line.firstIndex(of: " ") else {{ continue }}
            result[String(line[line.startIndex..<space])] = String(line[line.index(after: space)...])
        }}
        return result
    }}()

    /// 把一段文本里的短码换成表情。**代码块和行内代码一概不碰**——
    /// `:smile:` 出现在代码里多半是 YAML 的键或者字典字面量，替换掉就是改了内容。
    /// 从后往前替换，前面的位置才不会被挪动。
    static func substitute(in text: NSMutableAttributedString, codeBlock: Bool) {{
        guard !codeBlock else {{ return }}
        // 绝大多数段落里一个冒号都没有。先问一句再决定要不要走正则——
        // 正则铺到全文上，五十万字要多花十几毫秒。
        // 用 mutableString 而不是 .string：后者每次都会把整段桥接成一个新的 Swift String。
        guard text.mutableString.range(of: ":").location != NSNotFound else {{ return }}
        let source = text.string as NSString
        let matches = pattern.matches(in: text.string, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else {{ return }}
        for match in matches.reversed() {{
            let name = source.substring(with: match.range(at: 1))
            guard let emoji = table[name] else {{ continue }}
            let attributes = text.attributes(at: match.range.location, effectiveRange: nil)
            let intent = (attributes[.inlinePresentationIntent] as? UInt).map(InlinePresentationIntent.init(rawValue:))
            // 行内代码、原生 HTML 标签内部都保持原样
            guard intent?.contains(.code) != true, intent?.contains(.inlineHTML) != true,
                  intent?.contains(.blockHTML) != true else {{ continue }}
            var replacement = attributes
            // 表情自己挑字体，别让上文的等宽/粗体字体把它顶成豆腐块
            replacement.removeValue(forKey: .font)
            text.replaceCharacters(in: match.range, with: NSAttributedString(string: emoji, attributes: replacement))
        }}
    }}

    /// 由 Tools/generate-emoji-table.py 从 gemoji 生成。
    private static let packed = """
{body}
"""
}}
'''


def load(argument):
    if argument:
        return json.loads(Path(argument).read_text())
    with urllib.request.urlopen(GEMOJI, timeout=30) as response:
        return json.loads(response.read())


def main():
    entries = load(sys.argv[1] if len(sys.argv) > 1 else None)
    table = {}
    for entry in entries:
        emoji = entry.get("emoji")
        if not emoji:
            continue
        # 短码里不能有空格或换行——打包格式靠这两样切分
        for alias in entry.get("aliases", []):
            if alias and " " not in alias and "\n" not in alias:
                table.setdefault(alias, emoji)
    if not table:
        raise SystemExit("gemoji 数据里没读出任何别名，格式可能变了")
    body = "\n".join(f"{name} {emoji}" for name, emoji in sorted(table.items()))
    out = Path(sys.argv[2]) if len(sys.argv) > 2 else DEFAULT_OUT
    out.write_text(TEMPLATE.format(count=len(table), capacity=len(table) * 2 // 1000 * 1000 + 2048, body=body))
    print(f"✓ {len(table)} 条写入 {out}")
    print("  这是上游文件；写完回来跑 ./Tools/sync-render.sh")


if __name__ == "__main__":
    main()
