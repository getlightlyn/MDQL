import AppKit
import SwiftMath

/// 拿真实文档里的公式逐条喂给 SwiftMath，统计它到底不认哪些命令。
@main enum FormulaProbe {
  static func main() {
    let path = CommandLine.arguments[1]
    let lines = (try! String(contentsOfFile: path, encoding: .utf8)).split(separator: "\n").map(String.init)
    var bad: [String: Int] = [:]
    var failures = 0, samples: [String: String] = [:]
    for latex in lines {
      // 和产品里同一条改写路径
      let fixed = MarkdownMath.compatible(latex)
      var image = MathImage(latex: fixed, fontSize: 16, textColor: .textColor, labelMode: .text)
      let (error, rendered, _) = image.asImage()
      guard error != nil || rendered == nil else { continue }
      failures += 1
      let message = error?.localizedDescription ?? "no image"
      // 「Invalid command \xxx」里的命令名
      let key = message.replacingOccurrences(of: #"^(Invalid command |Unknown environment )"#,
                                             with: "$1", options: .regularExpression)
      bad[key, default: 0] += 1
      if samples[key] == nil { samples[key] = String(latex.prefix(70)) }
    }
    print("失败 \(failures) / \(lines.count)")
    for (key, n) in bad.sorted(by: { $0.value > $1.value }) {
      print("  \(n)×  \(key)")
      if let s = samples[key] { print("        例: \(s)") }
    }
  }
}
