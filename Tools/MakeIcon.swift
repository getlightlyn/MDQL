import AppKit

/// 画应用图标，输出 .icns。
///
/// 用代码画而不是放一张位图：图标要出 16 到 1024 十档尺寸，手工导出十次容易漏、
/// 改个颜色又得重来一遍；矢量重画每次都一致，小尺寸下线宽还能单独调。
///
///     swift Tools/MakeIcon.swift Resources/AppIcon.icns
///
/// 造型：macOS 的圆角方底 + Markdown 的「M ▾」记号。不模仿系统图标，也不用任何第三方素材。
@main enum MakeIcon {
    static let sizes = [16, 32, 64, 128, 256, 512, 1024]

    static func draw(_ side: CGFloat) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(side), pixelsHigh: Int(side),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let context = NSGraphicsContext.current!.cgContext

        // 底：macOS 应用图标四边各留约 10% 的空，图标本体才不会顶到边
        let inset = side * 0.094
        let body = CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
        let corner = body.width * 0.2237      // 系统圆角方的比例
        let plate = CGPath(roundedRect: body, cornerWidth: corner, cornerHeight: corner, transform: nil)

        context.saveGState()
        context.addPath(plate)
        context.clip()
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
            NSColor(srgbRed: 0.204, green: 0.290, blue: 0.443, alpha: 1).cgColor,
            NSColor(srgbRed: 0.106, green: 0.145, blue: 0.239, alpha: 1).cgColor,
        ] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: body.maxY),
                                   end: CGPoint(x: 0, y: body.minY), options: [])
        context.restoreGState()

        // 从顶部渐隐的高光。用纯色矩形会在中间留一条硬边——看着像画错了，不像有厚度。
        context.saveGState()
        context.addPath(plate)
        context.clip()
        let sheen = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
            NSColor(white: 1, alpha: 0.16).cgColor,
            NSColor(white: 1, alpha: 0).cgColor,
        ] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(sheen, start: CGPoint(x: 0, y: body.maxY),
                                   end: CGPoint(x: 0, y: body.midY), options: [])
        context.restoreGState()

        // Markdown 的记号是「M + 朝下的三角」。
        // 只画 M 容易翻车：拐点必须**向下**，向上就成了 W——上一版就是这么错的。
        // 16/32 这两档只剩十来个像素，三角和 M 挤在一起会糊成一团，所以小尺寸只留 M。
        let mark = body.insetBy(dx: body.width * 0.23, dy: body.height * 0.345)
        let compact = side < 64
        // M 和箭头之间要留出气口，挨太近会连成一坨
        let letter = compact ? mark : CGRect(x: mark.minX, y: mark.minY,
                                             width: mark.width * 0.56, height: mark.height)
        let stroke = max(side * (compact ? 0.100 : 0.064), 1.5)
        let path = NSBezierPath()
        path.lineWidth = stroke
        path.lineCapStyle = .round
        path.lineJoinStyle = .miter
        path.move(to: CGPoint(x: letter.minX, y: letter.minY))
        path.line(to: CGPoint(x: letter.minX, y: letter.maxY))
        path.line(to: CGPoint(x: letter.midX, y: letter.minY + letter.height * 0.26))
        path.line(to: CGPoint(x: letter.maxX, y: letter.maxY))
        path.line(to: CGPoint(x: letter.maxX, y: letter.minY))
        NSColor.white.setStroke()
        path.stroke()

        if !compact {
            let arrowWidth = mark.width * 0.26
            let arrow = CGRect(x: mark.maxX - arrowWidth, y: mark.minY + mark.height * 0.06,
                               width: arrowWidth, height: mark.height * 0.88)
            let stem = NSBezierPath()
            stem.lineWidth = stroke
            stem.lineCapStyle = .butt
            stem.move(to: CGPoint(x: arrow.midX, y: arrow.maxY))
            stem.line(to: CGPoint(x: arrow.midX, y: arrow.minY + arrow.height * 0.40))
            NSColor.white.setStroke()
            stem.stroke()

            let head = NSBezierPath()
            head.move(to: CGPoint(x: arrow.minX, y: arrow.minY + arrow.height * 0.44))
            head.line(to: CGPoint(x: arrow.maxX, y: arrow.minY + arrow.height * 0.44))
            head.line(to: CGPoint(x: arrow.midX, y: arrow.minY))
            head.close()
            NSColor.white.setFill()
            head.fill()
        }

        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    static func main() {
        let output = CommandLine.arguments.count > 1
            ? URL(fileURLWithPath: CommandLine.arguments[1])
            : URL(fileURLWithPath: "Resources/AppIcon.icns")
        let iconset = output.deletingPathExtension().appendingPathExtension("iconset")
        try? FileManager.default.removeItem(at: iconset)
        try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

        // iconset 要求每档都有 1x 和 2x 两份；2x 是下一档的像素数
        for size in sizes {
            for scale in [1, 2] {
                let pixels = size * scale
                guard pixels <= 1024 else { continue }
                let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
                let data = draw(CGFloat(pixels)).representation(using: .png, properties: [:])!
                try? data.write(to: iconset.appendingPathComponent(name))
            }
        }

        let iconutil = Process()
        iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
        try? iconutil.run()
        iconutil.waitUntilExit()
        try? FileManager.default.removeItem(at: iconset)
        print(iconutil.terminationStatus == 0 ? "✓ \(output.path)" : "✗ iconutil 失败")
    }
}
