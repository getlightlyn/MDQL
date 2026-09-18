#!/bin/zsh
# 用扩展的真实源码编一个普通 app 测试台（不带 -application-extension）。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/.build/ExampleReport.app"
BIN="$ROOT/.build/release"
[[ -d /Applications/Xcode.app && -z "${DEVELOPER_DIR:-}" ]] && export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
python3 "$ROOT/../Lightlyn/Tools/prepare_swiftmath.py" --copy-resources \
  "$BIN/SwiftMath_SwiftMath.bundle" "$APP/Contents/Resources/SwiftMath_SwiftMath.bundle"
python3 - "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist" <<'PY'
import plistlib, sys
p = plistlib.loads(open(sys.argv[1],'rb').read())
p.update(CFBundleIdentifier="com.lightlyn.MDQL.harness", CFBundleExecutable="harness",
         CFBundleName="MDQL Harness", CFBundleDisplayName="MDQL Harness")
p.pop("UTImportedTypeDeclarations", None)
open(sys.argv[2],'wb').write(plistlib.dumps(p))
PY

SOURCES=()
while IFS= read -r f; do SOURCES+=("$f"); done < <(find "$ROOT/Sources/MDQLPreview" -name "*.swift" ! -name "main.swift" | sort)
OBJECTS=()
while IFS= read -r o; do OBJECTS+=("$o"); done < <(find "$BIN/SwiftMath.build" -name "*.o" | sort)

xcrun swiftc -swift-version 5 -O -parse-as-library \
  -target "$(uname -m)-apple-macos15.0" -I "$BIN/Modules" \
  "${OBJECTS[@]}" "${SOURCES[@]}" "$ROOT/Tools/ExampleReport.swift" \
  -o "$APP/Contents/MacOS/harness"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1
echo "$APP/Contents/MacOS/harness"
