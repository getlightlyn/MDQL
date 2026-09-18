#!/bin/zsh
# 校验 Render/ 下的副本没有被就地改过。
#
# 这是硬闸：渲染器的上游在 Lightlyn，这里改了也留不住，
# 与其等下次同步默默覆盖掉，不如现在就拦下来。build.sh 每次都会跑。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Sources/MDQLPreview/Render"
MANIFEST="$DEST/SOURCE.json"

[[ -f "$MANIFEST" ]] || { echo "缺 $MANIFEST，先跑 ./Tools/sync-render.sh"; exit 1; }

DRIFT=0
while IFS=$'\t' read -r name expected; do
  [[ -n "$name" ]] || continue
  if [[ ! -f "$DEST/$name" ]]; then
    echo "✗ 缺文件 $name"; DRIFT=1; continue
  fi
  actual="$(shasum -a 256 "$DEST/$name" | cut -d' ' -f1)"
  if [[ "$actual" != "$expected" ]]; then
    echo "✗ $name 被就地改过"; DRIFT=1
  fi
done < <(python3 -c '
import json, sys
data = json.load(open(sys.argv[1]))
for name, digest in data["files"].items():
    print(f"{name}\t{digest}")
' "$MANIFEST")

if (( DRIFT )); then
  echo
  echo "渲染器的上游在 Lightlyn，不要在这个仓库里改它。"
  echo "  1. 去 Lightlyn 改 Sources/LightlynApp/Preview/Formats/Text/"
  echo "  2. 回来跑 ./Tools/sync-render.sh"
  exit 1
fi
echo "✓ 渲染器与 $(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["commit"])' "$MANIFEST") 一致"
