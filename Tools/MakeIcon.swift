import AppKit

/// 画应用图标，输出 .icns。
///
/// 用代码画而不是放一张位图：图标要出 16 到 1024 十档尺寸，手工导出十次容易漏、
/// 改个颜色又得重来一遍；矢量重画每次都一致，小尺寸下线宽还能单独调。
///
///     swift Tools/MakeIcon.swift Resources/AppIcon.icns
///
/// 造型：macOS 的圆角方底 + 闪电和 D。闪电那道折线就是 M 的右半边，
/// 和 D 共用中间一竖，合起来读作 MD。不模仿系统图标，也不用任何第三方素材。
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

        // 记号是「闪电 + D」：闪电本身是一道折线，像 M 的右半边，
        // 和右边的 D 拼起来读作 MD——中间那一竖是两者共用的一笔。
        // 16/32 两档只剩十来个像素，D 会糊成一坨，那两档只留闪电。
        let mark = body.insetBy(dx: body.width * 0.17, dy: body.height * 0.24)
        let compact = side < 64
        let boltWidth = compact ? mark.width : mark.width * 0.42
        let bolt = CGRect(x: mark.minX, y: mark.minY, width: boltWidth, height: mark.height)

        // 闪电：上宽下窄的折线，腰部往右折。顶点贴着框，视觉重心才不会往下掉。
        let flash = NSBezierPath()
        flash.move(to: CGPoint(x: bolt.minX + bolt.width * 0.52, y: bolt.maxY))
        flash.line(to: CGPoint(x: bolt.minX, y: bolt.midY + bolt.height * 0.08))
        flash.line(to: CGPoint(x: bolt.minX + bolt.width * 0.42, y: bolt.midY + bolt.height * 0.08))
        flash.line(to: CGPoint(x: bolt.minX + bolt.width * 0.16, y: bolt.minY))
        flash.line(to: CGPoint(x: bolt.maxX, y: bolt.midY + bolt.height * 0.30))
        flash.line(to: CGPoint(x: bolt.minX + bolt.width * 0.54, y: bolt.midY + bolt.height * 0.30))
        flash.close()
        NSColor.white.setFill()
        flash.fill()

        if !compact {
            // D = 左边一竖 + 右边半圆。用圆弧画，别手搓贝塞尔控制点——
            // 上一版内外两条曲线的控制点不一致，笔画粗细不均，中间像被掐了一下。
            let height = mark.height
            let width = min(height * 0.82, mark.maxX - (bolt.maxX + mark.width * 0.03))
            let d = CGRect(x: mark.maxX - width, y: mark.minY, width: width, height: height)
            let weight = side * 0.062

            func shape(_ rect: CGRect) -> NSBezierPath {
                let radius = min(rect.height / 2, rect.width)
                let center = CGPoint(x: rect.maxX - radius, y: rect.midY)
                let path = NSBezierPath()
                path.move(to: CGPoint(x: rect.minX, y: rect.minY))
                path.line(to: CGPoint(x: rect.minX, y: rect.maxY))
                path.line(to: CGPoint(x: center.x, y: rect.maxY))
                path.appendArc(withCenter: center, radius: radius,
                               startAngle: 90, endAngle: -90, clockwise: true)
                path.line(to: CGPoint(x: rect.minX, y: rect.minY))
                path.close()
                return path
            }

            let letter = shape(d)
            // 内孔：上下各缩一个笔画厚度，左边让开竖线的宽度
            let hole = shape(CGRect(x: d.minX + weight, y: d.minY + weight,
                                    width: d.width - weight * 2, height: d.height - weight * 2))
            letter.append(hole.reversed)
            letter.windingRule = .evenOdd
            NSColor.white.setFill()
            letter.fill()
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
