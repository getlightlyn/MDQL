import AppKit

/// 代码语法着色：**自写 tokenizer，零依赖**。
///
/// 只认四类词：**注释 / 字符串 / 数字 / 关键字·类型**（外加 diff 的 +− 行）。
/// 不做语义分析——预览要的是「一眼看出结构」，不是编译器级别的准确。
/// 这个尺度换来的是：着色永远不需要跨行回溯超过一层块注释，可以按视口增量做。

enum SyntaxToken: UInt8 {
    case comment, string, number, keyword, type
    case added, removed, meta      // diff / patch 专用

    /// Xcode 默认配色，浅色/深色各一套（跟随系统外观）
    var color: NSColor {
        let (light, dark) = Self.palette[self]!
        return NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark ? dark : light
        }
    }

    private static let palette: [SyntaxToken: (NSColor, NSColor)] = [
        .comment: (rgb(0x007400), rgb(0x6C7986)),
        .string:  (rgb(0xC41A16), rgb(0xFC6A5D)),
        .number:  (rgb(0x1C00CF), rgb(0xD0BF69)),
        .keyword: (rgb(0xAA0D91), rgb(0xFC5FA3)),
        .type:    (rgb(0x3F6E75), rgb(0x5DD8FF)),
        .added:   (rgb(0x137333), rgb(0x7EE787)),
        .removed: (rgb(0xC5221F), rgb(0xFFA198)),
        .meta:    (rgb(0x6E5494), rgb(0xD2A8FF)),
    ]

    private static func rgb(_ hex: Int) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

// MARK: - 语法表

/// 一门语言需要的全部信息。都是「词法」层面的，没有语法树。
struct SyntaxGrammar {
    var lineComments: [[UInt16]] = []
    var blockOpen: [UInt16] = []
    var blockClose: [UInt16] = []
    /// 字符串定界符（" ' `）
    var quotes: [UInt16] = []
    /// 支持 Python / Swift 那种三引号跨行字符串
    var tripleQuotes = false
    /// 单个定界符但**允许跨行**的字符串：Go 的原始字符串、JS 的模板串，都是反引号
    var multilineQuotes: [UInt16] = []
    var keywords: Set<String> = []
    var types: Set<String> = []
    /// diff/patch：按行首字符着色，不走词法
    var isDiff = false
    /// JSON 式：引号串后面跟冒号的是**键**，和值分开着色
    var stringKeys = false
    /// YAML/TOML/INI 式：行首到 `:` 或 `=` 之间的裸词是**键**
    var lineKeys = false
    /// XML/HTML 式：`<tag` `</tag` 当关键字着色
    var tagMarkup = false

    var hasBlockComment: Bool { !blockOpen.isEmpty }
}

private func u16(_ s: String) -> [UInt16] { Array(s.utf16) }
private func words(_ s: String) -> Set<String> { Set(s.split(separator: " ").map(String.init)) }

extension SyntaxGrammar {
    /// 按扩展名取语法表。认不出来返回 nil = 不着色（纯文本、日志、未知格式）。
    static func forExtension(_ ext: String) -> SyntaxGrammar? {
        switch ext {
        case "c", "h", "cpp", "cc", "cxx", "hpp", "hh", "m", "mm":
            return cFamily(keywords: cKeywords + " " + cppKeywords, types: cTypes)
        case "java", "kt", "kts", "scala", "groovy", "cs", "dart":
            return cFamily(keywords: javaKeywords, types: javaTypes)
        case "js", "mjs", "cjs", "jsx", "ts", "tsx", "mts", "cts":
            return cFamily(keywords: jsKeywords, types: jsTypes)
        case "go":
            return cFamily(keywords: goKeywords, types: goTypes)
        case "rs":
            return cFamily(keywords: rustKeywords, types: rustTypes)
        case "swift":
            var g = cFamily(keywords: swiftKeywords, types: swiftTypes)
            g.tripleQuotes = true
            return g
        case "php":
            return cFamily(keywords: phpKeywords, types: "")
        case "proto":
            return cFamily(keywords: "syntax package import option message enum service rpc returns repeated optional required reserved oneof map extend",
                           types: "double float int32 int64 uint32 uint64 sint32 sint64 fixed32 fixed64 bool string bytes")
        case "css", "scss", "less", "sass":
            var g = cFamily(keywords: "", types: "")
            g.lineComments = [u16("//")]
            return g
        case "py", "pyi", "pyw":
            return script(comment: "#", keywords: pythonKeywords, types: pythonTypes, triple: true)
        case "sh", "bash", "zsh", "fish", "ksh", "profile", "bashrc", "zshrc":
            return script(comment: "#", keywords: shellKeywords, types: "")
        case "rb", "gemspec", "podspec", "rake":
            return script(comment: "#", keywords: rubyKeywords, types: "")
        case "pl", "pm", "r":
            return script(comment: "#", keywords: "", types: "")
        case "lua":
            var g = script(comment: "--", keywords: luaKeywords, types: "")
            g.blockOpen = u16("--[[")
            g.blockClose = u16("]]")
            return g
        case "sql":
            var g = script(comment: "--", keywords: sqlKeywords, types: sqlTypes)
            g.blockOpen = u16("/*"); g.blockClose = u16("*/")
            g.quotes = [39, 34]
            return g
        case "json", "jsonl", "ndjson", "json5", "geojson", "ipynb":
            var g = SyntaxGrammar()
            g.quotes = [34]
            g.keywords = words("true false null")
            g.stringKeys = true
            return g
        case "yaml", "yml":
            var g = script(comment: "#", keywords: "true false null yes no on off", types: "")
            g.lineKeys = true
            return g
        case "toml", "ini", "conf", "cfg", "properties", "editorconfig", "gitconfig":
            var g = script(comment: "#", keywords: "true false", types: "")
            g.lineComments = [u16("#"), u16(";")]
            g.lineKeys = true
            return g
        case "xml", "plist", "svg", "xib", "storyboard", "gradle", "pom", "html", "htm", "vue":
            var g = SyntaxGrammar()
            g.blockOpen = u16("<!--"); g.blockClose = u16("-->")
            g.quotes = [34, 39]
            g.tagMarkup = true
            return g
        case "patch", "diff":
            var g = SyntaxGrammar()
            g.isDiff = true
            return g
        case "":
            // 无后缀的那批（Dockerfile / Makefile / .gitignore …）统一按 # 注释处理
            return script(comment: "#", keywords: dockerKeywords, types: "")
        default:
            return nil
        }
    }

    private static func cFamily(keywords k: String, types t: String) -> SyntaxGrammar {
        var g = SyntaxGrammar()
        g.lineComments = [u16("//")]
        g.blockOpen = u16("/*"); g.blockClose = u16("*/")
        g.quotes = [34, 39, 96]          // " ' `
        g.multilineQuotes = [96]         // Go 原始字符串 / JS 模板串跨行
        g.keywords = words(k)
        g.types = words(t)
        return g
    }

    private static func script(comment: String, keywords k: String, types t: String,
                               triple: Bool = false) -> SyntaxGrammar {
        var g = SyntaxGrammar()
        g.lineComments = [u16(comment)]
        g.quotes = [34, 39]
        g.tripleQuotes = triple
        g.keywords = words(k)
        g.types = words(t)
        return g
    }

    // 关键字表：只收「一眼能认出是这门语言」的那些，不求全
    private static let cKeywords = "auto break case char const continue default do double else enum extern float for goto if inline int long register restrict return short signed sizeof static struct switch typedef union unsigned void volatile while"
    private static let cppKeywords = "class namespace template typename public private protected virtual override final new delete this nullptr true false using friend operator constexpr noexcept explicit mutable throw try catch static_cast dynamic_cast const_cast reinterpret_cast decltype auto concept requires co_await co_return co_yield import module #include #define #ifdef #ifndef #endif #pragma"
    private static let cTypes = "bool size_t ssize_t int8_t int16_t int32_t int64_t uint8_t uint16_t uint32_t uint64_t intptr_t uintptr_t ptrdiff_t wchar_t FILE NULL"
    private static let javaKeywords = "abstract assert break case catch class const continue default do else enum extends final finally for goto if implements import instanceof interface native new package private protected public return static strictfp super switch synchronized this throw throws transient try volatile while var val fun object companion data sealed suspend when is in out lateinit init override open internal typealias namespace using async await yield get set"
    private static let javaTypes = "boolean byte char double float int long short void String Object List Map Set Integer Boolean Double Long Unit Any Nothing Array"
    private static let jsKeywords = "async await break case catch class const continue debugger default delete do else export extends finally for from function get if import in instanceof let new of return set static super switch this throw try typeof var void while with yield true false null undefined interface type enum implements declare namespace abstract public private protected readonly satisfies as keyof infer"
    private static let jsTypes = "string number boolean object symbol bigint any unknown never Array Promise Record Partial Readonly Pick Omit Map Set Date RegExp Error JSON Math console window document"
    private static let goKeywords = "break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var nil true false iota make new len cap append copy delete panic recover"
    private static let goTypes = "bool byte complex64 complex128 error float32 float64 int int8 int16 int32 int64 rune string uint uint8 uint16 uint32 uint64 uintptr any comparable"
    private static let rustKeywords = "as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait true type unsafe use where while box macro_rules"
    private static let rustTypes = "bool char f32 f64 i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize str String Vec Option Some None Result Ok Err Box Rc Arc HashMap HashSet"
    private static let swiftKeywords = "associatedtype class deinit enum extension fileprivate func import init inout internal let open operator private precedencegroup protocol public rethrows static struct subscript typealias var where while repeat guard defer do catch throw throws try if else for in return break continue fallthrough switch case default as is nil true false self Self super some any async await actor lazy weak unowned mutating nonmutating override final convenience required indirect @objc @escaping @MainActor"
    private static let swiftTypes = "Int Int8 Int16 Int32 Int64 UInt UInt8 UInt16 UInt32 UInt64 Double Float CGFloat Bool String Character Array Dictionary Set Optional Result Error Data Date URL Never Void AnyObject"
    private static let phpKeywords = "abstract and array as break callable case catch class clone const continue declare default do echo else elseif empty enddeclare endfor endforeach endif endswitch endwhile enum extends final finally fn for foreach function global goto if implements include include_once instanceof insteadof interface isset list match namespace new or print private protected public readonly require require_once return static switch throw trait try unset use var while xor yield true false null"
    private static let pythonKeywords = "and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield True False None self match case"
    private static let pythonTypes = "int float str bool bytes list dict set tuple frozenset object type range len print open Exception ValueError TypeError KeyError IndexError Optional List Dict Any Union Callable"
    private static let shellKeywords = "if then else elif fi case esac for while until do done in function return break continue local export readonly declare unset source alias set shift trap exit eval exec test echo printf cd pwd"
    private static let rubyKeywords = "alias and begin break case class def defined? do else elsif end ensure false for if in module next nil not or redo rescue retry return self super then true undef unless until when while yield require require_relative attr_accessor attr_reader attr_writer puts lambda proc"
    private static let luaKeywords = "and break do else elseif end false for function goto if in local nil not or repeat return then true until while self"
    private static let sqlKeywords = "SELECT FROM WHERE INSERT INTO VALUES UPDATE SET DELETE CREATE TABLE ALTER DROP INDEX VIEW JOIN LEFT RIGHT INNER OUTER FULL CROSS ON AS AND OR NOT NULL IS IN BETWEEN LIKE ORDER BY GROUP HAVING LIMIT OFFSET UNION ALL DISTINCT COUNT SUM AVG MIN MAX CASE WHEN THEN ELSE END PRIMARY KEY FOREIGN REFERENCES UNIQUE DEFAULT CHECK CONSTRAINT CASCADE BEGIN COMMIT ROLLBACK TRANSACTION WITH RETURNING EXISTS select from where insert into values update set delete create table alter drop index view join left right inner outer on as and or not null is in between like order by group having limit offset union all distinct"
    private static let sqlTypes = "INT INTEGER BIGINT SMALLINT TINYINT DECIMAL NUMERIC FLOAT REAL DOUBLE CHAR VARCHAR TEXT BLOB DATE TIME DATETIME TIMESTAMP BOOLEAN JSON JSONB UUID SERIAL int integer bigint text varchar boolean timestamp"
    private static let dockerKeywords = "FROM RUN CMD LABEL EXPOSE ENV ADD COPY ENTRYPOINT VOLUME USER WORKDIR ARG ONBUILD STOPSIGNAL HEALTHCHECK SHELL AS"
}

// MARK: - 扫描器

/// 跨行状态。只有两种东西能跨行：块注释、三引号字符串。
/// 状态这么小，是「不做语法树」这个尺度换来的——按视口增量着色才可能。
struct SyntaxState: Equatable {
    var inBlockComment = false
    /// 正在进行中的三引号的引号字符，0 = 不在三引号里
    var inTripleQuote: UInt16 = 0
    /// 正在进行中的跨行字符串（反引号）的定界符，0 = 不在里面
    var inRawString: UInt16 = 0
}

/// Foundation 的小型读取缓冲，避免为高亮复制整份 UTF-16 文本。
final class SyntaxText: RandomAccessCollection {
    typealias Index = Int
    typealias Element = UInt16
    let startIndex = 0
    let endIndex: Int
    private let text: NSString
    private var buffer = CFStringInlineBuffer()
    private let asciiBuffer: UnsafePointer<CChar>?
    private let unicodeBuffer: UnsafePointer<UInt16>?

    init(_ text: NSString) {
        self.text = text
        endIndex = text.length
        asciiBuffer = CFStringGetCStringPtr(text as CFString, CFStringBuiltInEncodings.ASCII.rawValue)
        unicodeBuffer = CFStringGetCharactersPtr(text as CFString)
        CFStringInitInlineBuffer(text as CFString, &buffer, CFRange(location: 0, length: text.length))
    }

    @inline(__always) subscript(index: Int) -> UInt16 {
        if let asciiBuffer { return UInt16(asciiBuffer[index]) }
        if let unicodeBuffer { return unicodeBuffer[index] }
        return CFStringGetCharacterFromInlineBuffer(&buffer, index)
    }
    func index(after i: Int) -> Int { i + 1 }
    func index(before i: Int) -> Int { i - 1 }
}

enum SyntaxScanner {
    /// 从 `from` 扫到 `to`。
    ///
    /// `emitting == false` 时**只推进跨行状态、不产出记号**，也不去查关键字表——
    /// 这是「跳到 8MB 文件末尾」时唯一要跑的那趟扫描，必须便宜。
    static func scan<C: RandomAccessCollection>(_ c: C, from: Int, to: Int,
                     grammar g: SyntaxGrammar,
                     state: inout SyntaxState,
                     emitting: Bool,
                     visibleRange: NSRange? = nil,
                     emit: (Int, Int, SyntaxToken) -> Void) where C.Element == UInt16, C.Index == Int {
        if g.isDiff {
            if emitting { scanDiff(c, from: from, to: to, emit: emit) }
            return
        }
        var i = from
        while i < to {
            if let visibleRange, i >= NSMaxRange(visibleRange) { break }
            // —— 先把上一段没闭合的跨行结构收掉
            if state.inBlockComment {
                let start = i
                while i < to {
                    if matches(c, i, g.blockClose, to) {
                        i += g.blockClose.count; state.inBlockComment = false; break
                    }
                    i += 1
                }
                if emitting { emit(start, i - start, .comment) }
                continue
            }
            if state.inTripleQuote != 0 {
                let start = i
                closeTriple(c, &i, to, state.inTripleQuote, &state)
                if emitting { emit(start, i - start, .string) }
                continue
            }
            if state.inRawString != 0 {
                let start = i
                closeRaw(c, &i, to, state.inRawString, &state)
                if emitting { emit(start, i - start, .string) }
                continue
            }

            let ch = c[i]

            // —— 行首的键（yaml/toml/ini）。放在最前面：它要看「是不是行首」，
            //    被别的分支消费掉一个字符就判断不出来了。
            if g.lineKeys, i == 0 || c[i - 1] == 10 {
                var j = i
                while j < to, c[j] == 32 || c[j] == 9 { j += 1 }
                if j + 1 < to, c[j] == 45, c[j + 1] == 32 { j += 2 }   // yaml 的「- 」列表项
                let keyStart = j
                while j < to, isKeyPart(c[j]) { j += 1 }
                if j > keyStart, j < to, c[j] == 58 || c[j] == 61 {     // ':' 或 '='
                    if emitting { emit(keyStart, j - keyStart, .type) }
                    i = j + 1
                    continue
                }
            }

            // —— 行注释
            var consumed = false
            for marker in g.lineComments where matches(c, i, marker, to) {
                let start = i
                while i < to, c[i] != 10 { i += 1 }
                if emitting { emit(start, i - start, .comment) }
                consumed = true
                break
            }
            if consumed { continue }

            // —— 块注释
            if g.hasBlockComment, matches(c, i, g.blockOpen, to) {
                let start = i
                i += g.blockOpen.count
                state.inBlockComment = true
                while i < to {
                    if matches(c, i, g.blockClose, to) {
                        i += g.blockClose.count; state.inBlockComment = false; break
                    }
                    i += 1
                }
                if emitting { emit(start, i - start, .comment) }
                continue
            }

            // —— 标签（xml/html）。块注释在上面已经先摘掉了，不会把 <!-- 当成标签。
            if g.tagMarkup, ch == 60 {                                  // '<'
                var j = i + 1
                if j < to, c[j] == 47 { j += 1 }                        // '</'
                let nameStart = j
                while j < to, isIdentifierPart(c[j]) || c[j] == 45 || c[j] == 58 { j += 1 }
                if j > nameStart {
                    if emitting { emit(i, j - i, .keyword) }
                    i = j
                    continue
                }
            }

            // —— 字符串
            if g.quotes.contains(ch) {
                let start = i
                if g.tripleQuotes, i + 2 < to, c[i + 1] == ch, c[i + 2] == ch {
                    i += 3
                    state.inTripleQuote = ch
                    closeTriple(c, &i, to, ch, &state)
                } else if g.multilineQuotes.contains(ch) {
                    i += 1
                    state.inRawString = ch
                    closeRaw(c, &i, to, ch, &state)
                } else {
                    i += 1
                    while i < to {
                        if c[i] == 92 { i += 2; continue }          // 反斜杠转义
                        if c[i] == ch { i += 1; break }
                        // 不跨行：一个落单的撇号（it's）否则会把半个文件染红
                        if c[i] == 10 { break }
                        i += 1
                    }
                }
                if emitting {
                    // 后面跟着冒号的引号串是键（JSON），和值分开——
                    // 不分的话整份 JSON 全是一个红色，等于没着色
                    var token = SyntaxToken.string
                    if g.stringKeys {
                        var j = i
                        while j < to, c[j] == 32 || c[j] == 9 { j += 1 }
                        if j < to, c[j] == 58 { token = .type }
                    }
                    emit(start, min(i, to) - start, token)
                }
                continue
            }

            // —— 标识符（顺带查关键字表）。不 emitting 时也要整体跳过，
            //    否则 abc123 里的 123 会被当成数字。
            if isIdentifierStart(ch) {
                let start = i
                while i < to, isIdentifierPart(c[i]) { i += 1 }
                if emitting {
                    if let visibleRange, i <= visibleRange.location { continue }
                    let word = String(decoding: c[start..<i], as: UTF16.self)
                    if g.keywords.contains(word) { emit(start, i - start, .keyword) }
                    else if g.types.contains(word) { emit(start, i - start, .type) }
                }
                continue
            }

            // —— 数字
            if isDigit(ch) {
                let start = i
                while i < to, isNumberPart(c[i]) { i += 1 }
                if emitting { emit(start, i - start, .number) }
                continue
            }

            i += 1
        }
    }

    /// diff/patch 按行首字符着色，和词法无关
    private static func scanDiff<C: RandomAccessCollection>(_ c: C, from: Int, to: Int,
                                 emit: (Int, Int, SyntaxToken) -> Void) where C.Element == UInt16, C.Index == Int {
        var i = from
        while i < to {
            let start = i
            while i < to, c[i] != 10 { i += 1 }
            let length = i - start
            if i < to { i += 1 }
            guard length > 0 else { continue }
            switch c[start] {
            case 43:                                   // '+'
                emit(start, length, matches(c, start, u16("+++"), to) ? .meta : .added)
            case 45:                                   // '-'
                emit(start, length, matches(c, start, u16("---"), to) ? .meta : .removed)
            case 64 where matches(c, start, u16("@@"), to):
                emit(start, length, .meta)
            case 100 where matches(c, start, u16("diff "), to),   // "diff "
                 105 where matches(c, start, u16("index "), to):  // "index "
                emit(start, length, .comment)
            default:
                break
            }
        }
    }

    private static func closeTriple<C: RandomAccessCollection>(_ c: C, _ i: inout Int, _ to: Int,
                                    _ quote: UInt16, _ state: inout SyntaxState) where C.Element == UInt16, C.Index == Int {
        while i < to {
            if c[i] == quote, i + 2 < to, c[i + 1] == quote, c[i + 2] == quote {
                i += 3; state.inTripleQuote = 0; return
            }
            i += 1
        }
        state.inTripleQuote = quote
    }

    private static func closeRaw<C: RandomAccessCollection>(_ c: C, _ i: inout Int, _ to: Int,
                                 _ quote: UInt16, _ state: inout SyntaxState) where C.Element == UInt16, C.Index == Int {
        while i < to {
            if c[i] == 92 { i += 2; continue }
            if c[i] == quote { i += 1; state.inRawString = 0; return }
            i += 1
        }
        state.inRawString = quote
    }

    private static func matches<C: RandomAccessCollection>(_ c: C, _ i: Int, _ pattern: [UInt16], _ to: Int) -> Bool where C.Element == UInt16, C.Index == Int {
        guard !pattern.isEmpty, i + pattern.count <= to else { return false }
        for (offset, unit) in pattern.enumerated() where c[i + offset] != unit { return false }
        return true
    }

    private static func isDigit(_ u: UInt16) -> Bool { u >= 48 && u <= 57 }

    private static func isIdentifierStart(_ u: UInt16) -> Bool {
        (u >= 65 && u <= 90) || (u >= 97 && u <= 122) || u == 95 || u == 36 || u == 64 || u == 35
    }

    private static func isIdentifierPart(_ u: UInt16) -> Bool {
        isIdentifierStart(u) || isDigit(u) || u == 63 || u == 33   // Ruby 的 defined? / empty!
    }

    /// 键名允许的字符。刻意不含 `#`，否则注释行会被当成键。
    private static func isKeyPart(_ u: UInt16) -> Bool {
        (u >= 65 && u <= 90) || (u >= 97 && u <= 122) || isDigit(u)
            || u == 95 || u == 45 || u == 46 || u == 47 || u == 34 || u == 39
    }

    /// 0x1F / 1e-9 / 1_000 / 3.14f 都算一个数
    private static func isNumberPart(_ u: UInt16) -> Bool {
        isDigit(u) || (u >= 65 && u <= 90) || (u >= 97 && u <= 122) || u == 46 || u == 95
    }
}

// MARK: - 按视口取记号

/// 把扫描器接到渲染上：**只给看得见的那几行取记号**。
///
/// 配合可见区自绘，避免一次性给全文着色。
/// 用户滑到哪才需要哪。做法是把文档切成固定大小的**块**，
/// 每块记一个「进入这块时的跨行状态」当检查点，要哪一段就从最近的检查点扫过去。
final class SyntaxHighlighter {
    /// 块大小。太小则检查点数组长、跳转时循环次数多；太大则每次取记号要多扫一段。
    private static let chunkSize = 16 * 1024

    private let units: SyntaxText
    /// 只扫正文，不扫尾部那段「仅显示开头部分」的提示
    private let limit: Int
    private let text: NSString
    private let grammar: SyntaxGrammar
    private let lineStarts: [Int32]?

    /// checkpoints[k] = 第 k 块开头处的跨行状态；只有 0...known 是算好的
    private var checkpoints: [SyntaxState] = [SyntaxState()]
    private var known = 0

    init?(text: NSString, extension ext: String, lineStarts: [Int32]? = nil) {
        guard let grammar = SyntaxGrammar.forExtension(ext.lowercased()) else { return nil }
        self.grammar = grammar
        self.text = text
        self.lineStarts = lineStarts
        self.limit = text.length
        self.units = SyntaxText(text)
    }

    /// 从行首恢复词法上下文，只输出与可见片段相交的记号。
    func tokens(in range: NSRange, _ emit: (Int, Int, SyntaxToken) -> Void) {
        let from = min(max(range.location, 0), limit)
        let to = min(NSMaxRange(range), limit)
        guard from < to else { return }
        let start: Int
        var state = SyntaxState()
        if !grammar.hasBlockComment && !grammar.tripleQuotes && grammar.multilineQuotes.isEmpty {
            // JSONL 等语法没有跨行状态，跳到文件末尾也不必扫描前文。
            start = lineRange(at: from).location
        } else {
            let chunk = from / Self.chunkSize
            state = self.state(atChunk: chunk)
            start = chunkStart(chunk)
        }
        let visible = NSRange(location: from, length: to - from)
        let end = NSMaxRange(lineRange(at: to - 1))
        SyntaxScanner.scan(units, from: start, to: end, grammar: grammar,
                           state: &state, emitting: true, visibleRange: visible) { location, length, token in
            let hit = NSIntersectionRange(visible, NSRange(location: location, length: length))
            if hit.length > 0 { emit(hit.location, hit.length, token) }
        }
    }

    /// 第 k 块开头的跨行状态。没算过就从最后一个检查点往前推——
    /// 只推进状态、不产出记号，所以「一步跳到文件末尾」也只是一趟廉价扫描。
    private func state(atChunk chunk: Int) -> SyntaxState {
        while known < chunk {
            var carried = checkpoints[known]
            SyntaxScanner.scan(units, from: chunkStart(known), to: chunkStart(known + 1),
                               grammar: grammar, state: &carried,
                               emitting: false) { _, _, _ in }
            checkpoints.append(carried)
            known += 1
        }
        return checkpoints[chunk]
    }

    /// 块的边界**对齐到行首**。切在半行上会让下一块从一个词的中间开始扫，
    /// 一个字符串或标识符被劈成两半，颜色就错了。
    private func chunkStart(_ chunk: Int) -> Int {
        let raw = chunk * Self.chunkSize
        if raw <= 0 { return 0 }
        if raw >= limit { return limit }
        return lineRange(at: raw).location
    }

    /// 代码预览已建好行索引；不再让 NSString 为每帧扫描整条长行。
    private func lineRange(at offset: Int) -> NSRange {
        guard let lineStarts else { return text.lineRange(for: NSRange(location: offset, length: 0)) }
        var low = 0, high = lineStarts.count - 1
        while low + 1 < high {
            let mid = (low + high) / 2
            if Int(lineStarts[mid]) <= offset { low = mid } else { high = mid }
        }
        let from = Int(lineStarts[low])
        return NSRange(location: from, length: min(Int(lineStarts[high]), limit) - from)
    }
}
