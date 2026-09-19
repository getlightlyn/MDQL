#!/bin/zsh
# 校验从 Lightlyn 同步下来的文件没有被就地改过。
#
# 这是硬闸：它们的上游在 Lightlyn，这里改了也留不住，
# 与其等下次同步默默覆盖掉，不如现在就拦下来。build.sh 每次都会跑。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$ROOT/Sources/MDQLPreview/Render/SOURCE.json"

[[ -f "$MANIFEST" ]] || { echo "缺 $MANIFEST，先跑 ./Tools/sync-render.sh"; exit 1; }

# 先整份读出来再逐行比。用管道直接喂 while 的话，
# 清单坏掉时 python 的失败会被吞掉，一个文件都没查却报「一致」。
ENTRIES="$(python3 -c '
import json, sys
data = json.load(open(sys.argv[1]))
for name, entry in data["files"].items():
    digest = entry["sha256"]
    print(f"{name}\t{digest}")
' "$MANIFEST")" || { echo "✗ 读不了 $MANIFEST"; exit 1; }
[[ -n "$ENTRIES" ]] || { echo "✗ $MANIFEST 里一个文件都没有"; exit 1; }

DRIFT=0
while IFS=$'\t' read -r name expected; do
  [[ -n "$name" ]] || continue
  if [[ ! -f "$ROOT/$name" ]]; then
    echo "✗ 缺文件 $name"; DRIFT=1; continue
  fi
  actual="$(shasum -a 256 "$ROOT/$name" | cut -d' ' -f1)"
  if [[ "$actual" != "$expected" ]]; then
    echo "✗ $name 被就地改过"; DRIFT=1
  fi
done <<< "$ENTRIES"

if (( DRIFT )); then
  echo
  echo "这些文件的上游在 Lightlyn，不要在这个仓库里改它们。"
  echo "  1. 去 Lightlyn 改 Sources/LightlynApp/Preview/Formats/Text/ 或 Tools/prepare_swiftmath.py"
  echo "  2. 回来跑 ./Tools/sync-render.sh"
  exit 1
fi
COMMIT="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["commit"])' "$MANIFEST")"
echo "✓ $(wc -l <<< "$ENTRIES" | tr -d ' ') 个同步文件与 $COMMIT 一致"
