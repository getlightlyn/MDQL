#!/bin/zsh
# 打发布用的 dmg：两个架构各一个。
#
# 用 dmg 而不是 zip：Mac 上装应用的惯例是拖进「应用程序」，dmg 打开就是那个窗口，
# 里面放一个 Applications 的替身，拖过去就完事。zip 解压出来还得用户自己搬。
#
# 用法: ./Tools/package-release.sh [输出目录]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/dist/release}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"

rm -rf "$OUT"; mkdir -p "$OUT"
for arch in arm64 x86_64; do
  echo "→ $arch"
  "$ROOT/build.sh" release --arch "$arch" >/dev/null

  # dmg 的内容：应用 + 一个「应用程序」替身，打开就能拖
  STAGE="$(mktemp -d)"
  cp -R "$ROOT/dist/MDQL.app" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"

  DMG="$OUT/MDQL-$VERSION-$arch.dmg"
  hdiutil create -quiet -volname "MDQL $VERSION" -srcfolder "$STAGE" \
    -ov -format UDZO -fs HFS+ "$DMG"
  rm -rf "$STAGE"
  echo "  $(du -h "$DMG" | cut -f1)  $(basename "$DMG")"
done

cd "$OUT" && shasum -a 256 *.dmg > SHA256SUMS.txt
echo
echo "✓ $OUT"
cat SHA256SUMS.txt
