#!/bin/zsh
# 把 SwiftPM 产物打成可安装的 MDQL.app（带快速查看扩展）。
# 用法: ./build.sh [release|debug]
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/dist/MDQL.app"
EXT="$APP/Contents/PlugIns/MDQLPreview.appex"
SIGNING_IDENTITY="${MDQL_SIGNING_IDENTITY:-}"
if [[ -z "$SIGNING_IDENTITY" && -f "$ROOT/.signing-identity" ]]; then
  SIGNING_IDENTITY="$(<"$ROOT/.signing-identity")"
fi
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"

# CLT 缺组件；装了 Xcode 就优先用它的工具链
if [[ -d /Applications/Xcode.app && -z "${DEVELOPER_DIR:-}" ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

# 渲染器是从 Lightlyn 同步下来的副本，不该在这里被改过
"$ROOT/Tools/check-render.sh"

# 离线兜底：旁边就有 Lightlyn 工作副本的话，借它已经解析好的 SwiftMath。
# 独立 clone 里这个目录不存在，整段直接跳过，`swift build` 自己去 clone。
if [[ ! -d "$ROOT/.build/checkouts/SwiftMath" && -d "$ROOT/../Lightlyn/.build/checkouts/SwiftMath" ]]; then
  echo "→ 借用主项目已解析的 SwiftMath"
  mkdir -p "$ROOT/.build"
  cp -R "$ROOT/../Lightlyn/.build/repositories" "$ROOT/.build/"
  cp -R "$ROOT/../Lightlyn/.build/checkouts" "$ROOT/.build/"
  [[ -f "$ROOT/../Lightlyn/Package.resolved" ]] && cp "$ROOT/../Lightlyn/Package.resolved" "$ROOT/Package.resolved"
fi

# SwiftMath 的资源查找要指回 bundle 根，得先给它打个补丁。
# 这一步要联网解析依赖；解不动但检出已经在的话就按离线走，不为一次 fetch 卡住构建。
OFFLINE=()
if ! python3 "$ROOT/Tools/prepare_swiftmath.py" \
       --package-path "$ROOT" --scratch-path "$ROOT/.build"; then
  [[ -d "$ROOT/.build/checkouts/SwiftMath" ]] || { echo "依赖解析失败，且本地没有 SwiftMath 检出"; exit 1; }
  echo "→ 联网解析失败，沿用已有检出（离线构建）"
  OFFLINE=(--disable-automatic-resolution)
fi

echo "→ swift build -c $CONFIG"
swift build --build-system native -c "$CONFIG" --package-path "$ROOT" "${OFFLINE[@]}"

BIN="$ROOT/.build/$CONFIG"
[[ -x "$BIN/MDQL" ]] || { echo "宿主应用没编出来: $BIN/MDQL"; exit 1; }
[[ -x "$BIN/MDQLPreview" ]] || { echo "扩展没编出来: $BIN/MDQLPreview"; exit 1; }
[[ -x "$BIN/MDQLOpener" ]] || { echo "开链接服务没编出来: $BIN/MDQLOpener"; exit 1; }

echo "→ 组装 $APP"
rm -rf "$APP"
OPENER="$EXT/Contents/XPCServices/MDQLOpener.xpc"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" \
         "$EXT/Contents/MacOS" "$EXT/Contents/Resources" \
         "$OPENER/Contents/MacOS"

cp "$BIN/MDQL" "$APP/Contents/MacOS/MDQL"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
[[ -f "$ROOT/Resources/AppIcon.icns" ]] && cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"

cp "$BIN/MDQLPreview" "$EXT/Contents/MacOS/MDQLPreview"
cp "$ROOT/QLExtension/Info.plist" "$EXT/Contents/Info.plist"

# 开链接的 XPC 服务。扩展是强制沙箱的，在里面开不了外部链接；
# 这个服务**不带 app-sandbox**，随扩展分发、由 launchd 按需拉起。
cp "$BIN/MDQLOpener" "$OPENER/Contents/MacOS/MDQLOpener"
cp "$ROOT/XPCService/Info.plist" "$OPENER/Contents/Info.plist"

# 公式字体。Bundle.main 在扩展里就是 appex 自己，所以资源要放进扩展而不是宿主应用。
python3 "$ROOT/Tools/prepare_swiftmath.py" --copy-resources \
  "$BIN/SwiftMath_SwiftMath.bundle" "$EXT/Contents/Resources/SwiftMath_SwiftMath.bundle"

# 从最里层往外签：外层的签名覆盖内层内容，反过来签外层会立刻失效。
# 服务用空 entitlements——不带 app-sandbox 正是它能开链接的原因。
codesign --force --sign "$SIGNING_IDENTITY" \
  --entitlements "$ROOT/XPCService/MDQLOpener.entitlements" "$OPENER"
codesign --force --sign "$SIGNING_IDENTITY" \
  --entitlements "$ROOT/QLExtension/MDQL.entitlements" "$EXT"
codesign --force --sign "$SIGNING_IDENTITY" "$APP"

echo "✓ $APP"
echo "  开链接服务 $(du -h "$OPENER/Contents/MacOS/MDQLOpener" | cut -f1)"
echo "  扩展二进制 $(du -h "$EXT/Contents/MacOS/MDQLPreview" | cut -f1)，整个扩展 $(du -sh "$EXT" | cut -f1)，整包 $(du -sh "$APP" | cut -f1)"
echo
echo "  安装：把 MDQL.app 拖进 /Applications 后打开一次，系统才会注册扩展。"
echo "  确认：pluginkit -m -i com.lightlyn.MDQL.QLExtension"
echo "  试用：qlmanage -p 某个文件.md"
