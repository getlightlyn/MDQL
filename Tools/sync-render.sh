#!/bin/zsh
# 从 Lightlyn 同步渲染器和 SwiftMath 补丁脚本。
#
# 方向是**单向**的：上游在 Lightlyn（闭源），这里是下游的只读副本。
# 反过来同步不存在——本仓库里改这些文件，下一次同步就会被覆盖。
#
# 用法: ./Tools/sync-render.sh [Lightlyn 仓库路径]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UPSTREAM="${1:-$ROOT/../Lightlyn}"

# 「上游路径|本仓库路径」，两边都相对各自的仓库根。
# 渲染器六个文件，外加打 SwiftMath 补丁的脚本——后者 build.sh 每次都要用，
# 不带上它的话独立 clone 根本编不了。
TEXT=Sources/LightlynApp/Preview/Formats/Text
PAIRS=(
  "$TEXT/MarkdownRenderer.swift|Sources/MDQLPreview/Render/MarkdownRenderer.swift"
  "$TEXT/MarkdownMath.swift|Sources/MDQLPreview/Render/MarkdownMath.swift"
  "$TEXT/MarkdownHTML.swift|Sources/MDQLPreview/Render/MarkdownHTML.swift"
  "$TEXT/MarkdownFootnotes.swift|Sources/MDQLPreview/Render/MarkdownFootnotes.swift"
  "$TEXT/MarkdownEmoji.swift|Sources/MDQLPreview/Render/MarkdownEmoji.swift"
  "$TEXT/SyntaxHighlighter.swift|Sources/MDQLPreview/Render/SyntaxHighlighter.swift"
  "Tools/prepare_swiftmath.py|Tools/prepare_swiftmath.py"
)

[[ -d "$UPSTREAM/$TEXT" ]] || { echo "找不到上游: $UPSTREAM"; exit 1; }

COMMIT="$(git -C "$UPSTREAM" rev-parse --short HEAD 2>/dev/null || echo unknown)"
DIRTY=""
SOURCES=()
for pair in "${PAIRS[@]}"; do SOURCES+=("${pair%%|*}"); done
if ! git -C "$UPSTREAM" diff --quiet -- "${SOURCES[@]}" 2>/dev/null; then
  DIRTY=" (工作区有未提交改动)"
  echo "⚠️  上游有未提交的改动，同步下来的内容对应不到任何 commit"
fi

for pair in "${PAIRS[@]}"; do
  src="${pair%%|*}"; dst="${pair##*|}"
  [[ -f "$UPSTREAM/$src" ]] || { echo "上游缺文件: $src"; exit 1; }
  mkdir -p "$(dirname "$ROOT/$dst")"
  cp "$UPSTREAM/$src" "$ROOT/$dst"
done

# 记下来源，check-render.sh 靠它判断有没有被就地改过。
# 键是本仓库根下的相对路径，`from` 是上游仓库根下的——上游那边的
# script/check_render_sync.py 也读这份清单，映射写在数据里就不用两边各存一份。
MANIFEST="$ROOT/Sources/MDQLPreview/Render/SOURCE.json"
{
  echo "{"
  echo "  \"origin\": \"Lightlyn\","
  echo "  \"commit\": \"$COMMIT$DIRTY\","
  echo "  \"synced\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
  echo "  \"files\": {"
  local last="${PAIRS[-1]##*|}"
  for pair in "${PAIRS[@]}"; do
    src="${pair%%|*}"; dst="${pair##*|}"
    sum="$(shasum -a 256 "$ROOT/$dst" | cut -d' ' -f1)"
    comma=","; [[ "$dst" == "$last" ]] && comma=""
    echo "    \"$dst\": { \"from\": \"$src\", \"sha256\": \"$sum\" }$comma"
  done
  echo "  }"
  echo "}"
} > "$MANIFEST"

echo "✓ 同步 ${#PAIRS[@]} 个文件，上游 $COMMIT"
