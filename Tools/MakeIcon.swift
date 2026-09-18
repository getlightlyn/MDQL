import AppKit

/// 画应用图标，顺带出一张 README 用的 PNG。
///
///     swiftc -parse-as-library -O -o /tmp/mkicon Tools/MakeIcon.swift
///     /tmp/mkicon Resources/AppIcon.icns docs/icon.png
///
/// 记号是「闪电 + D」：闪电那道折线本身就是个 M，和右边的 D 拼起来读作 MD。
/// 轮廓是照着设计稿描下来的多边形，坐标记在 `Mark` 里，单位是记号宽度的万分之一。
/// 描成矢量而不是直接塞位图：图标要出 16 到 1024 七档、每档还有 @2x，位图得逐档重导，
/// 描下来的每档都一致，小尺寸还能单独减料。
@main enum MakeIcon {
    enum Mark {
        static let bolt: [[Int]] = [
          [
            21, 5488, 0, 5447, 92, 5252, 175, 5139, 226, 5015, 288, 4943,
            308, 4882, 462, 4645, 483, 4584, 504, 4573, 524, 4512, 545, 4502,
            565, 4440, 586, 4430, 606, 4368, 658, 4306, 678, 4245, 699, 4234,
            719, 4173, 771, 4111, 1017, 3669, 1007, 3638, 473, 3638, 421, 3577,
            421, 3505, 668, 3135, 709, 3042, 843, 2867, 904, 2744, 1028, 2580,
            1038, 2539, 1202, 2312, 1213, 2271, 1244, 2251, 1254, 2210, 1439, 1953,
            1449, 1912, 1501, 1860, 1562, 1737, 1614, 1686, 1644, 1614, 1850, 1326,
            1891, 1233, 2004, 1089, 2045, 997, 2179, 822, 2199, 761, 2271, 678,
            2354, 524, 2508, 319, 2549, 226, 2672, 82, 2837, 21, 2960, 31,
            3042, 72, 3114, 144, 3145, 206, 3597, 2446, 3607, 2487, 3628, 2497,
            3813, 2271, 4573, 1131, 4604, 1110, 4830, 771, 4841, 730, 4954, 586,
            5221, 123, 5365, 31, 5519, 21, 5653, 72, 5725, 134, 5776, 226,
            5797, 329, 5786, 4954, 5735, 5067, 5683, 5128, 5540, 5200, 5365, 5200,
            5221, 5128, 5159, 5057, 5118, 4964, 5108, 1757, 5087, 1747, 4738, 2220,
            4666, 2292, 4645, 2343, 4532, 2467, 4512, 2518, 4368, 2682, 4214, 2909,
            4173, 2939, 4152, 2991, 4111, 3022, 4049, 3124, 3834, 3381, 3813, 3433,
            3731, 3515, 3638, 3659, 3587, 3700, 3505, 3823, 3392, 3936, 3340, 3957,
            3258, 3957, 3207, 3936, 3155, 3885, 3114, 3803, 2724, 2220, 2703, 2169,
            2672, 2169, 2302, 2559, 2302, 2580, 1860, 3022, 1871, 3063, 2312, 3063,
            2354, 3114, 2343, 3207, 1809, 3762, 1809, 3782, 1737, 3834, 1706, 3885,
            1501, 4080, 1501, 4101, 1449, 4132, 1429, 4173, 514, 5087, 493, 5087,
            154, 5416, 72, 5478,
          ],
        ]
        static let letterD: [[Int]] = [
          [
            8746, 4933, 8520, 5026, 8243, 5108, 7955, 5159, 7708, 5180, 6300, 5180,
            6208, 5139, 6146, 5067, 6115, 4974, 6115, 432, 6125, 185, 6166, 92,
            6228, 41, 6351, 0, 7616, 0, 8099, 41, 8510, 144, 8941, 349,
            9209, 545, 9496, 853, 9702, 1172, 9887, 1634, 9949, 1901, 9990, 2251,
            10000, 2909, 9959, 3299, 9897, 3577, 9815, 3813, 9702, 4049, 9579, 4245,
            9414, 4430, 9414, 4450, 9342, 4522, 9322, 4522, 9270, 4594, 9250, 4594,
            9085, 4738,
          ],
          [
            8058, 4327, 8356, 4193, 8613, 4018, 8818, 3792, 9003, 3433, 9096, 3022,
            9116, 2785, 9116, 2405, 9075, 2035, 8983, 1706, 8890, 1521, 8746, 1326,
            8541, 1141, 8417, 1059, 8304, 1017, 8294, 997, 8016, 904, 7729, 863,
            6876, 863, 6876, 4388, 7760, 4388,
          ],
        ]

        /// 记号整体的高宽比
        static let aspect: CGFloat = 0.54882
        /// 闪电单独占的那一块（同样以记号宽度为单位），小尺寸只摆它
        static let boltBox = CGRect(x: 0, y: 0.00206, width: 0.57965, height: 0.54676)

        static let amber = NSColor(srgbRed: 0.992, green: 0.733, blue: 0.004, alpha: 1)
        static let ink = NSColor(srgbRed: 0.110, green: 0.110, blue: 0.110, alpha: 1)

        /// 把一组环摆进 `box`：环里的坐标 y 向下，AppKit 的画布 y 向上，得翻一下。
        static func path(_ rings: [[Int]], in box: CGRect) -> NSBezierPath {
            let path = NSBezierPath()
            for ring in rings {
                for index in stride(from: 0, to: ring.count, by: 2) {
                    let point = CGPoint(x: box.minX + CGFloat(ring[index]) / 10000 * box.width,
                                        y: box.maxY - CGFloat(ring[index + 1]) / 10000 * box.width)
                    index == 0 ? path.move(to: point) : path.line(to: point)
                }
                path.close()
            }
            // D 的内孔是反向环，evenOdd 不用管环的绕向
            path.windingRule = .evenOdd
            return path
        }
    }

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

        // 设计稿是透明底的，但 Dock 里没有底的图标会散架，补一块白板。
        // 纯白在浅色背景上没有边，压一层极淡的渐变再描一圈，才看得出是块板。
        context.saveGState()
        context.addPath(plate)
        context.clip()
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
            NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1).cgColor,
            NSColor(srgbRed: 0.937, green: 0.941, blue: 0.949, alpha: 1).cgColor,
        ] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: body.maxY),
                                   end: CGPoint(x: 0, y: body.minY), options: [])
        context.restoreGState()

        context.saveGState()
        context.addPath(plate)
        context.setStrokeColor(NSColor(white: 0, alpha: 0.10).cgColor)
        context.setLineWidth(max(1, side / 256))
        context.strokePath()
        context.restoreGState()

        // 16/32 两档只剩十来个像素，D 会糊成一坨——那两档只留闪电，
        // 它接近正方，独占整块地方反而能画大。
        let compact = side < 64
        let focus = compact ? Mark.boltBox : CGRect(x: 0, y: 0, width: 1, height: Mark.aspect)
        let ratio: CGFloat = compact ? 0.72 : 0.74
        let scale = min(body.width * ratio / focus.width, body.height * ratio / focus.height)
        let mark = CGRect(x: body.midX - focus.midX * scale,
                          y: body.midY + focus.midY * scale - Mark.aspect * scale,
                          width: scale, height: Mark.aspect * scale)

        Mark.amber.setFill()
        Mark.path(Mark.bolt, in: mark).fill()
        if !compact {
            Mark.ink.setFill()
            Mark.path(Mark.letterD, in: mark).fill()
        }

        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    static func main() {
        let arguments = CommandLine.arguments
        let output = URL(fileURLWithPath: arguments.count > 1 ? arguments[1] : "Resources/AppIcon.icns")
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

        // README 顶上那张。512 存着、按 128 显示，Retina 下也不糊。
        if arguments.count > 2 {
            let png = URL(fileURLWithPath: arguments[2])
            try? FileManager.default.createDirectory(at: png.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? draw(512).representation(using: .png, properties: [:])!.write(to: png)
            print("✓ \(png.path)")
        }
    }
}
