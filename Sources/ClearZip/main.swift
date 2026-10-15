import AppKit

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "--compress" {
    do {
        var paths = Array(arguments.dropFirst())
        var output: URL?
        if paths.first == "--output-directory" {
            guard paths.count >= 3 else { throw ArchiveFailure(message: "用法：ClearZip --compress [--output-directory 文件夹] -- 文件…") }
            output = URL(fileURLWithPath: paths[1], isDirectory: true)
            paths.removeFirst(2)
        }
        if paths.first == "--" { paths.removeFirst() }
        guard !paths.isEmpty else { throw ArchiveFailure(message: "请提供要压缩的文件。") }
        let result = try ArchiveEngine.compress(paths.map { URL(fileURLWithPath: $0) }, destination: output)
        print(result.url.path)
        exit(0)
    } catch {
        FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
        exit(1)
    }
}
if arguments.first == "--help" {
    print("ClearZip — 干净压缩\n用法：ClearZip --compress [--output-directory 文件夹] -- 文件…\n不带参数时打开原生窗口。")
    exit(0)
}
let finderFiles = CompressionRequest.files(from: arguments)
// Reject old URL requests and malformed launches before starting AppKit.
if !arguments.isEmpty, finderFiles == nil {
    FileHandle.standardError.write(Data("无法识别启动参数。请从访达菜单或应用窗口选择文件。\n".utf8))
    exit(2)
}
let app = NSApplication.shared
let delegate = AppDelegate(backgroundFiles: finderFiles)
app.delegate = delegate
// Services can arrive during application launch, before didFinishLaunching.
app.servicesProvider = delegate
// Start as an agent so Finder-triggered work never flashes a Dock icon/window.
// AppDelegate promotes an ordinary manual launch to a regular app with a window.
app.setActivationPolicy(.accessory)
app.run()
