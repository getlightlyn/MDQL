// appex 的入口是系统的 NSExtensionMain，不是我们的 main()。
//
// 但 SwiftPM 的可执行 target 一定会去找 `<模块名>_main` 这个符号，链接时作为
// initial-undefine 传给 ld。Swift 只有在模块里存在一个叫 main.swift 的文件时才生成它。
// 所以这个文件必须在、而且必须叫这个名字，内容可以为空——
// 真正的入口由 Package.swift 里的 `-Xlinker -e -Xlinker _NSExtensionMain` 指定。
