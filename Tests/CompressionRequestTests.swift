import Foundation

@main
struct CompressionRequestTests {
    static func main() throws {
        let files = [URL(fileURLWithPath: "/tmp/中文 \" & ? # % +\n.txt"), URL(fileURLWithPath: "/tmp/literal%00"), URL(fileURLWithPath: "/tmp/another")]
        precondition(CompressionRequest.title(for: [URL(fileURLWithPath: "/tmp/分享资料")]) == "干净压缩“分享资料”")
        precondition(CompressionRequest.title(for: files) == "干净压缩 3 个项目")
        precondition(CompressionRequest.files(from: CompressionRequest.arguments(for: files)!) == files)
        precondition(CompressionRequest.arguments(for: []) == nil)
        precondition(CompressionRequest.openedFiles(from: files) == files)
        let localhost = [URL(string: "file://localhost/tmp/file")!]
        precondition(CompressionRequest.openedFiles(from: localhost) == localhost)
        let externalURLs = ["clearzip://compress?path=/tmp/a", "https://example.com/a", "file://example.com/tmp/a", "file:///tmp/a%00b"]
        precondition(CompressionRequest.openedFiles(from: []) == nil)
        for value in externalURLs {
            let urls = [URL(string: value)!]
            for request in [urls, files + urls, urls + files] {
                precondition(CompressionRequest.openedFiles(from: request) == nil, "Accepted unsupported URL: \(value)")
                precondition(CompressionRequest.arguments(for: request) == nil)
            }
        }
        for arguments in [[], ["--finder-compress"], ["--finder-compress", "--"],
                          ["--finder-compress", "--", "relative"],
                          ["--finder-compress", "--", "/tmp/a\0b"],
                          ["--finder-compress", "--", "clearzip://compress?path=/tmp/a"],
                          ["--finder-compress", "--", "/tmp/a", "clearzip://compress?path=/tmp/b"],
                          ["--finder-compress", "/tmp/a"],
                          ["--finder-compress", "--", "file:///tmp/a"],
                          ["clearzip://compress?path=/tmp/a"], ["--compress", "--", "/tmp/a"]] {
            precondition(CompressionRequest.files(from: arguments) == nil)
        }
        print("PASS Finder request: local arguments, special filenames, invalid and URL request rejection")
        print("PASS open URL policy: local files accepted; custom, web, remote, NUL and mixed requests rejected")
    }
}
