#!/usr/bin/env python3
"""Adapt pinned SwiftMath 1.7.3 and stage its Latin Modern resources.

The native SwiftPM accessor checks the bundle root, then an absolute build path.
Use the app's normal Resources directory first; leave CLI/test fallback intact.
Preserve Chinese atoms for CoreText's system font fallback; math layout stays upstream.
"""
from pathlib import Path
import argparse
import shutil
import stat
import subprocess

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--scratch-path', type=Path, default=root / '.build')
# MDQL 快速查看扩展用同一份补丁，只是包目录不同；默认仍是主项目。
parser.add_argument('--package-path', type=Path, default=root)
parser.add_argument('--copy-resources', nargs=2, type=Path, metavar=('SOURCE', 'DESTINATION'))
args = parser.parse_args()
if args.copy_resources:
    source, destination = args.copy_resources
    # SwiftPM 单架构把 mathFonts.bundle 放在 bundle 根下；多架构（--arch a --arch b）
    # 走的是 Xcode 那套，变成 Contents/Resources/。两种都认，否则 --universal 编不出来。
    fonts = next((d for d in (source / 'mathFonts.bundle',
                              source / 'Contents/Resources/mathFonts.bundle') if d.is_dir()), None)
    if fonts is None:
        raise SystemExit(f'Missing mathFonts.bundle under {source}')
    for name in ('latinmodern-math.otf', 'latinmodern-math.plist', 'GUST-FONT-LICENSE.txt'):
        if not (fonts / name).is_file():
            raise SystemExit(f'Missing math resource: {name}')
    def unused_fonts(directory, names):
        if Path(directory).name != 'mathFonts.bundle':
            return []
        return [name for name in names if Path(name).suffix in ('.otf', '.plist')
                and Path(name).stem != 'latinmodern-math']
    shutil.copytree(source, destination, ignore=unused_fonts)
    raise SystemExit(0)

subprocess.run(['swift', 'package', '--package-path', str(args.package_path),
                '--scratch-path', str(args.scratch_path), 'resolve'], check=True)
checkout = next(path for path in (args.scratch_path / 'checkouts').iterdir() if path.name.lower() == 'swiftmath')
revision = subprocess.check_output(['git', '-C', str(checkout), 'rev-parse', 'HEAD'], text=True).strip()
if revision != 'fa8244ed032f4a1ade4cb0571bf87d2f1a9fd2d7':
    raise SystemExit('SwiftMath revision changed; review resource compatibility before building')
sources = checkout / 'Sources/SwiftMath'
bridge = '''import Foundation

// Prefer the canonical macOS app resource directory over SwiftPM's build fallback.
enum PackagedMathResources {
    static let bundle: Bundle = {
        if let url = Bundle.main.url(forResource: "SwiftMath_SwiftMath", withExtension: "bundle"),
           let bundle = Bundle(url: url) { return bundle }
        return Bundle.module
    }()
}
'''
def write(path, content):
    if path.exists() and path.read_text() == content:
        return
    if path.exists():
        path.chmod(path.stat().st_mode | stat.S_IWUSR)
    path.write_text(content)
for relative, expected in [('MathRender/MTFont.swift', 1), ('MathBundle/MathFont.swift', 2)]:
    path = sources / relative
    text = path.read_text()
    if text.count('PackagedMathResources.bundle') == expected:
        continue
    if text.count('Bundle.module') != expected:
        raise SystemExit(f'Unexpected font resource lookup in {relative}')
    write(path, text.replace('Bundle.module', 'PackagedMathResources.bundle'))
write(sources / 'PackagedMathResources.swift', bridge)
# CJK characters were discarded before reaching CTLine, whose normal font cascade
# already supplies system glyphs. Keep them as ordinary atoms, including in scripts.
path = sources / 'MathRender/MTMathAtomFactory.swift'
text = path.read_text()
original = '            case _ where ch.utf32Char < 0x0021 || ch.utf32Char > 0x007E:'
chinese = '''            case _ where ch.unicodeScalars.contains(where: { $0.properties.isIdeographic })
                || (0x3001...0x303F).contains(ch.utf32Char) || (0xFF01...0xFF60).contains(ch.utf32Char):
                return MTMathAtom(type: .ordinary, value: chStr)
'''
if chinese not in text:
    if text.count(original) != 1:
        raise SystemExit('Unexpected character classification in MTMathAtomFactory.swift')
    write(path, text.replace(original, chinese + original))

# CoreText freezes NSColor into CGColor during layout. Refresh only when that
# resolved color changes, so cached formulas follow the window's appearance.
path = sources / 'MathBundle/MathImage.swift'
text = path.read_text()
original = 'let image = NSImage(size: size, flipped: false) { bounds in'
adaptive = '''var drawingColor = textColor.cgColor
            let image = NSImage(size: size, flipped: false) { [textColor] bounds in
                if drawingColor != textColor.cgColor {
                    displayList.textColor = textColor
                    drawingColor = textColor.cgColor
                }'''
if adaptive not in text:
    if text.count(original) != 1:
        raise SystemExit('Unexpected native image drawing in MathImage.swift')
    write(path, text.replace(original, adaptive))
print('SwiftMath 1.7.3: app resources, Chinese atoms and dynamic appearance prepared')
