#!/bin/zsh
# 从 Lightlyn 同步渲染器。
#
# 方向是**单向**的：上游在 Lightlyn（闭源），这里是下游的只读副本。
# 反过来同步不存在——本仓库里改 Render/ 下的文件，下一次同步就会被覆盖。
#
# 用法: ./Tools/sync-render.sh [Lightlyn 仓库路径]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UPSTREAM="${1:-$ROOT/../Lightlyn}"
SOURCE_DIR="$UPSTREAM/Sources/LightlynApp/Preview/Formats/Text"
DEST="$ROOT/Sources/MDQLPreview/Render"

FILES=(MarkdownRenderer.swift MarkdownMath.swift MarkdownHTML.swift
       MarkdownFootnotes.swift MarkdownEmoji.swift SyntaxHighlighter.swift)

[[ -d "$SOURCE_DIR" ]] || { echo "找不到上游: $SOURCE_DIR"; exit 1; }
mkdir -p "$DEST"

COMMIT="$(git -C "$UPSTREAM" rev-parse --short HEAD 2>/dev/null || echo unknown)"
DIRTY=""
if ! git -C "$UPSTREAM" diff --quiet -- "$SOURCE_DIR" 2>/dev/null; then
  DIRTY=" (工作区有未提交改动)"
  echo "⚠️  上游有未提交的改动，同步下来的内容对应不到任何 commit"
fi

for name in "${FILES[@]}"; do
  [[ -f "$SOURCE_DIR/$name" ]] || { echo "上游缺文件: $name"; exit 1; }
  cp "$SOURCE_DIR/$name" "$DEST/$name"
done

# 记下来源，check-render.sh 靠它判断有没有被就地改过
{
  echo "{"
  echo "  \"origin\": \"Lightlyn\","
  echo "  \"commit\": \"$COMMIT$DIRTY\","
  echo "  \"synced\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
  echo "  \"files\": {"
  local last="${FILES[-1]}"
  for name in "${FILES[@]}"; do
    sum="$(shasum -a 256 "$DEST/$name" | cut -d' ' -f1)"
    comma=","; [[ "$name" == "$last" ]] && comma=""
    echo "    \"$name\": \"$sum\"$comma"
  done
  echo "  }"
  echo "}"
} > "$DEST/SOURCE.json"

echo "✓ 同步 ${#FILES[@]} 个文件，上游 $COMMIT"
