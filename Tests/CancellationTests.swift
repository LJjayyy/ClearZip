import Foundation

@main
struct CancellationTests {
    static func main() throws {
        if CommandLine.arguments.dropFirst().first == "--mark-utf8" {
            for path in CommandLine.arguments.dropFirst(2) {
                try ZipEncoding.markUTF8(URL(fileURLWithPath: path), cancellation: ArchiveCancellation())
            }
            return
        }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("clearzip-cancel-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let file = root.appendingPathComponent("payload")
        // Incompressible enough to ensure cancellation exercises an active ditto process.
        var bytes = [UInt8](repeating: 0, count: 32 * 1024 * 1024)
        bytes.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, $0.count) }
        try Data(bytes).write(to: file)
        for phase in ["before", "preparing", "compressing"] {
            let token = ArchiveCancellation()
            if phase == "before" { token.cancel() }
            do {
                _ = try ArchiveEngine.compress([file], cancellation: token) { message in
                    if phase == "preparing", message.hasPrefix("正在准备") { token.cancel() }
                    if phase == "compressing", message.hasPrefix("正在压缩") {
                        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { token.cancel() }
                    }
                }
                fatalError("Expected cancellation during \(phase)")
            } catch is CancellationError {
                let remaining = try fm.contentsOfDirectory(atPath: root.path)
                precondition(remaining == ["payload"], "Leftover files: \(remaining)")
                print("PASS cancellation: \(phase)")
            }
        }
    }
}
