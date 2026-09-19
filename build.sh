#!/bin/zsh
# 把 SwiftPM 产物打成可安装的 MDQL.app（带快速查看扩展）。
# 用法: ./build.sh [release|debug] [--arch arm64|x86_64]... [--universal] [--mas]
#
# 不指定架构就编本机的。发版要按架构各编一个：Intel 机器装不了只有 arm64 的包，
# 而快速查看扩展没法像应用那样靠 Rosetta 兜底——扩展跟着宿主 Finder 的架构走。
#   ./build.sh release --arch arm64
#   ./build.sh release --arch x86_64
# --universal 是 `--arch arm64 --arch x86_64` 的简写，两个架构打进一个包。
#
# --mas 打 App Store 版，和默认版差三处，都是沙箱逼的：
#   1. 不带开链接的 XPC 服务——它靠「不在沙箱里」才能开链接，
#      而上架要求包里每个可执行文件都沙箱化。代价是预览里的链接点不开。
#   2. 宿主应用加沙箱，于是「扩展已启用」那行状态查不出来（«实测» 沙箱里
#      pluginkit 问不到，让扩展写心跳也不行——快速查看扩展对 app group 容器
#      只能读不能写），那一行干脆不显示，只留「打开系统设置」的入口。
#   3. 图片只读被预览文档所在的目录。entitlement 仍是主目录只读（不给的话
#      连同目录的图都读不到），但行为收窄到文档自己那一片，审核时说得清。
#      默认版不收窄，图放在主目录哪儿都能显示。
set -euo pipefail

CONFIG=release
MAS=0
ARCHS=()
while (( $# )); do
  case "$1" in
    release|debug) CONFIG="$1" ;;
    --arch) shift; [[ $# -gt 0 ]] || { echo "--arch 后面要跟架构名"; exit 2; }; ARCHS+=(--arch "$1") ;;
    --universal) ARCHS+=(--arch arm64 --arch x86_64) ;;
    --mas) MAS=1 ;;
    *) echo "不认识的参数: $1"
       echo "用法: ./build.sh [release|debug] [--arch arm64|x86_64]... [--universal]"; exit 2 ;;
  esac
  shift
done
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

echo "→ swift build -c $CONFIG ${ARCHS[*]:-（本机架构）}"
swift build --build-system native -c "$CONFIG" --package-path "$ROOT" "${OFFLINE[@]}" "${ARCHS[@]}"

# 一个架构（不管是不是本机）走 SwiftPM 的常规目录；两个以上它会另起一个
# Xcode 风格的目录，产物不在 .build/<配置> 下
if (( ${#ARCHS[@]} > 2 )); then
  BIN="$ROOT/.build/out/Products/$(echo "${CONFIG:0:1}" | tr '[:lower:]' '[:upper:]')${CONFIG:1}"
else
  BIN="$ROOT/.build/$CONFIG"
fi
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

# 界面文案。有哪些 .lproj，系统就认为支持哪些语言；都不匹配时退回
# Info.plist 里 CFBundleDevelopmentRegion 指定的 en。
for lproj in "$ROOT/Resources"/*.lproj; do
  [[ -d "$lproj" ]] && cp -R "$lproj" "$APP/Contents/Resources/"
done

cp "$BIN/MDQLPreview" "$EXT/Contents/MacOS/MDQLPreview"
cp "$ROOT/QLExtension/Info.plist" "$EXT/Contents/Info.plist"

# 开链接的 XPC 服务。扩展是强制沙箱的，在里面开不了外部链接；
# 这个服务**不带 app-sandbox**，随扩展分发、由 launchd 按需拉起。
# 上架版不能带它（包里每个可执行文件都得沙箱化），链接因此点不开。
if (( MAS )); then
  rm -rf "$EXT/Contents/XPCServices"
else
  cp "$BIN/MDQLOpener" "$OPENER/Contents/MacOS/MDQLOpener"
  cp "$ROOT/XPCService/Info.plist" "$OPENER/Contents/Info.plist"
fi

# 公式字体。Bundle.main 在扩展里就是 appex 自己，所以资源要放进扩展而不是宿主应用。
python3 "$ROOT/Tools/prepare_swiftmath.py" --copy-resources \
  "$BIN/SwiftMath_SwiftMath.bundle" "$EXT/Contents/Resources/SwiftMath_SwiftMath.bundle"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
APP_ENTS=""
if (( MAS )); then
  # 上架版：宿主应用加沙箱，并让扩展把图片范围收窄到文档所在目录
  APP_ENTS="$ROOT/Resources/MDQLApp.entitlements"
  /usr/libexec/PlistBuddy -c "Add :MDQLScopeImagesToDocument bool true" \
    "$EXT/Contents/Info.plist" >/dev/null
fi

# 从最里层往外签：外层的签名覆盖内层内容，反过来签外层会立刻失效。
# 服务用空 entitlements——不带 app-sandbox 正是它能开链接的原因。
if (( MAS == 0 )); then
  codesign --force --sign "$SIGNING_IDENTITY" \
    --entitlements "$ROOT/XPCService/MDQLOpener.entitlements" "$OPENER"
fi
codesign --force --sign "$SIGNING_IDENTITY" \
  --entitlements "$ROOT/QLExtension/MDQL.entitlements" "$EXT"
if [[ -n "$APP_ENTS" ]]; then
  codesign --force --sign "$SIGNING_IDENTITY" --entitlements "$APP_ENTS" "$APP"
else
  codesign --force --sign "$SIGNING_IDENTITY" "$APP"
fi

echo "✓ $APP"
echo "  架构 $(lipo -archs "$EXT/Contents/MacOS/MDQLPreview")$( ((MAS)) && echo "  ·  App Store 版（无 XPC、宿主带沙箱）")"
(( MAS )) || echo "  开链接服务 $(du -h "$OPENER/Contents/MacOS/MDQLOpener" | cut -f1)"
echo "  扩展二进制 $(du -h "$EXT/Contents/MacOS/MDQLPreview" | cut -f1)，整个扩展 $(du -sh "$EXT" | cut -f1)，整包 $(du -sh "$APP" | cut -f1)"
echo
echo "  安装：把 MDQL.app 拖进 /Applications 后打开一次，系统才会注册扩展。"
echo "  确认：pluginkit -m -i com.lightlyn.MDQL.QLExtension"
echo "  试用：qlmanage -p 某个文件.md"
