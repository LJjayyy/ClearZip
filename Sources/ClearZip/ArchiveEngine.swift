import Foundation
import Darwin

struct ArchiveFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class ArchiveCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var process: Process?

    func cancel() {
        lock.lock()
        cancelled = true
        let running = process
        lock.unlock()
        if let running, running.isRunning { running.terminate() }
    }

    func check() throws {
        lock.lock()
        let value = cancelled
        lock.unlock()
        if value { throw CancellationError() }
    }

    func run(_ task: Process) throws {
        // Serialize launch with cancellation so a cancelled task never starts later.
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        do { try task.run() } catch { lock.unlock(); throw error }
        process = task
        lock.unlock()
        task.waitUntilExit()
        lock.lock()
        process = nil
        let value = cancelled
        lock.unlock()
        if value { throw CancellationError() }
    }
}

struct ArchiveResult {
    let url: URL
    let itemCount: Int
    let filteredCount: Int
}

enum ArchiveEngine {
    static func isMetadata(_ name: String) -> Bool {
        name == ".DS_Store" || name == "__MACOSX" || name.hasPrefix("._")
    }

    private static func fileInfo(_ url: URL) throws -> stat {
        var info = stat()
        guard url.withUnsafeFileSystemRepresentation({ lstat($0!, &info) }) == 0 else {
            throw ArchiveFailure(message: "无法读取“\(url.lastPathComponent)”：\(String(cString: strerror(errno)))")
        }
        return info
    }

    private static func contains(_ parent: URL, _ child: URL) -> Bool {
        child.path == parent.path || child.path.hasPrefix(parent.path + "/")
    }

    static func compress(
        _ input: [URL], destination: URL? = nil,
        cancellation: ArchiveCancellation = ArchiveCancellation(),
        progress: (String) -> Void = { _ in }
    ) throws -> ArchiveResult {
        let fm = FileManager.default
        typealias Source = (url: URL, parent: ArchiveDescriptor, info: stat)
        var sources: [Source] = []
        var sourceChecks: [() throws -> Void] = []
        var parents: [String: ArchiveDescriptor] = [:]
        var filtered = 0
        for item in input {
            try cancellation.check()
            guard item.isFileURL else { throw ArchiveFailure(message: "请选择本机文件或文件夹。") }
            let url = item.standardizedFileURL
            guard url.path != "/" else { throw ArchiveFailure(message: "请选择具体的文件或文件夹，不能压缩整个磁盘。") }
            // Resolve aliases only in the parent; a selected symlink remains a link.
            // Retain each ancestor descriptor so later path replacements cannot redirect reads.
            let parentURL = url.deletingLastPathComponent()
            let parent = try ArchiveFileSystem.directory(at: parentURL, cache: &parents) { directory, name, expected in
                sourceChecks.append { try ArchiveFileSystem.verify(name, in: directory, matches: expected) }
            }
            let info = try ArchiveFileSystem.info(url.lastPathComponent, in: parent)
            if isMetadata(url.lastPathComponent) { filtered += 1; continue }
            if !sources.contains(where: { $0.url == url }) { sources.append((url, parent, info)) }
        }
        // Selecting a folder together with its descendants should include each only once.
        let all = sources
        sources = all.filter { child in
            !all.contains { parent in
                guard parent.url != child.url, contains(parent.url, child.url) else { return false }
                return parent.info.st_mode & S_IFMT == S_IFDIR
            }
        }
        guard !sources.isEmpty else { throw ArchiveFailure(message: "没有可压缩的内容，所选项目都是 macOS 元数据。") }
        let outputDirectory = (destination ?? sources[0].url.deletingLastPathComponent()).standardizedFileURL
        guard try fileInfo(outputDirectory).st_mode & S_IFMT == S_IFDIR else {
            throw ArchiveFailure(message: "保存位置不是文件夹。")
        }
        // Resolve parent aliases too; otherwise staging inside the source could recurse forever.
        let resolvedOutput = outputDirectory.resolvingSymlinksInPath()
        for source in sources where source.info.st_mode & S_IFMT == S_IFDIR {
            if contains(source.url.resolvingSymlinksInPath(), resolvedOutput) {
                throw ArchiveFailure(message: "保存位置不能位于要压缩的文件夹内。")
            }
        }

        let work = outputDirectory.appendingPathComponent(".clearzip-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: work) }
        let staging = work.appendingPathComponent("contents", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        var count = 0

        func copy(_ name: String, in parent: ArchiveDescriptor, expected info: stat, to target: URL) throws {
            try cancellation.check()
            if isMetadata(name) { filtered += 1; return }
            try ArchiveFileSystem.verify(name, in: parent, matches: info)
            switch info.st_mode & S_IFMT {
            case S_IFLNK:
                let link = try ArchiveFileSystem.link(name, in: parent)
                try fm.createSymbolicLink(atPath: target.path, withDestinationPath: link)
            case S_IFDIR:
                let directory = try ArchiveFileSystem.open(name, in: parent, expected: info)
                try fm.createDirectory(at: target, withIntermediateDirectories: false)
                for child in try ArchiveFileSystem.children(in: directory) {
                    if isMetadata(child) { filtered += 1; continue }
                    let childInfo = try ArchiveFileSystem.info(child, in: directory)
                    try copy(child, in: directory, expected: childInfo, to: target.appendingPathComponent(child))
                }
                // Keep staging directories readable/removable even for unusual source modes.
                try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))], ofItemAtPath: target.path)
            case S_IFREG:
                progress("正在准备：\(name)")
                try cancellation.check()
                let file = try ArchiveFileSystem.open(name, in: parent, expected: info)
                let targetParent = try ArchiveFileSystem.directory(at: target.deletingLastPathComponent().resolvingSymlinksInPath())
                try ArchiveFileSystem.copyData(file, name: target.lastPathComponent, into: targetParent)
                try fm.setAttributes([
                    .posixPermissions: NSNumber(value: info.st_mode & 0o777),
                    .modificationDate: Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
                ], ofItemAtPath: target.path)
            default:
                throw ArchiveFailure(message: "“\(name)”是特殊文件，无法放入 ZIP。")
            }
            try ArchiveFileSystem.verify(name, in: parent, matches: info)
            count += 1
        }

        for source in sources {
            let original = source.url.lastPathComponent
            var name = original
            var suffix = 2
            // Check lstat rather than fileExists, which misses dangling symbolic links.
            while (try? fileInfo(staging.appendingPathComponent(name))) != nil {
                name = "\(original) (\(suffix))"
                suffix += 1
            }
            try copy(original, in: source.parent, expected: source.info, to: staging.appendingPathComponent(name))
        }
        try cancellation.check()
        progress("正在压缩 \(count) 个项目…")
        func verifySources() throws {
            for check in sourceChecks { try check() }
            for source in sources {
                try ArchiveFileSystem.verify(source.url.lastPathComponent, in: source.parent, matches: source.info)
            }
        }
        try verifySources()
        let temporaryArchive = work.appendingPathComponent("archive.zip")
        let log = work.appendingPathComponent("error.log")
        fm.createFile(atPath: log.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: log)
        defer { try? logHandle.close() }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        task.arguments = ["-c", "-k", "--norsrc", "--noextattr", "--noacl", "--noqtn", staging.path, temporaryArchive.path]
        task.standardError = logHandle
        task.standardOutput = FileHandle.nullDevice
        try cancellation.run(task)
        guard task.terminationStatus == 0 else {
            let detail = (try? String(contentsOf: log, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw ArchiveFailure(message: "压缩失败。请检查磁盘空间和文件读取权限。\n\(detail)")
        }
        try cancellation.check()
        progress("正在整理 ZIP 文件名…")
        try ZipEncoding.markUTF8(temporaryArchive, cancellation: cancellation)
        try cancellation.check()
        try verifySources()
        let base = sources.count == 1 ? sources[0].url.lastPathComponent : "归档"
        var index = 1
        while true {
            let name = index == 1 ? "\(base).zip" : "\(base) \(index).zip"
            let target = outputDirectory.appendingPathComponent(name)
            // Atomic, no-overwrite publication, including simultaneous ClearZip processes.
            let result = temporaryArchive.withUnsafeFileSystemRepresentation { src in
                target.withUnsafeFileSystemRepresentation { dst in renamex_np(src!, dst!, UInt32(RENAME_EXCL)) }
            }
            if result == 0 { return ArchiveResult(url: target, itemCount: count, filteredCount: filtered) }
            if errno == EEXIST { index += 1; continue }
            throw ArchiveFailure(message: "无法保存 ZIP：\(String(cString: strerror(errno)))")
        }
    }
}

// ditto writes UTF-8 names but some versions omit ZIP's language-encoding flag.
// Patch only the two-byte flags in both headers, without reading file data into memory.
// ZIP layout: https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT
enum ZipEncoding {
    static func markUTF8(_ url: URL, cancellation: ArchiveCancellation) throws {
        let file = try FileHandle(forUpdating: url)
        defer { try? file.close() }
        let size = try file.seekToEnd()
        func invalid() -> ArchiveFailure { ArchiveFailure(message: "ZIP 目录校验失败，未生成压缩文件。") }
        func read(_ offset: UInt64, _ count: Int) throws -> [UInt8] {
            guard offset <= size, UInt64(count) <= size - offset else { throw invalid() }
            try file.seek(toOffset: offset)
            guard let data = try file.read(upToCount: count), data.count == count else { throw invalid() }
            return Array(data)
        }
        func number(_ bytes: [UInt8], _ offset: Int, _ count: Int) -> UInt64 {
            (0..<count).reduce(UInt64(0)) { $0 | (UInt64(bytes[offset + $1]) << ($1 * 8)) }
        }
        func mark(_ offset: UInt64, _ flags: UInt64) throws {
            let value = flags | 0x0800
            try file.seek(toOffset: offset)
            try file.write(contentsOf: Data([UInt8(value & 0xff), UInt8((value >> 8) & 0xff)]))
        }
        guard size >= 22 else { throw invalid() }
        // Our own ditto archives have no archive comment, encryption, or split disks.
        let end = try read(size - 22, 22)
        guard number(end, 0, 4) == 0x06054b50, number(end, 20, 2) == 0 else { throw invalid() }
        var count = number(end, 10, 2)
        var central = number(end, 16, 4)
        if count == 0xffff || central == 0xffffffff || number(end, 12, 4) == 0xffffffff {
            guard size >= 42 else { throw invalid() }
            let locator = try read(size - 42, 20)
            guard number(locator, 0, 4) == 0x07064b50 else { throw invalid() }
            let zip64 = try read(number(locator, 8, 8), 56)
            guard number(zip64, 0, 4) == 0x06064b50 else { throw invalid() }
            count = number(zip64, 32, 8)
            central = number(zip64, 48, 8)
        }
        guard count <= size / 46 else { throw invalid() }
        for _ in 0..<count {
            try cancellation.check()
            let header = try read(central, 46)
            guard number(header, 0, 4) == 0x02014b50 else { throw invalid() }
            let nameSize = Int(number(header, 28, 2))
            let extraSize = Int(number(header, 30, 2))
            let commentSize = Int(number(header, 32, 2))
            let name = try read(central + 46, nameSize)
            guard String(bytes: name, encoding: .utf8) != nil else {
                throw ArchiveFailure(message: "部分文件名不是有效的 UTF-8，无法创建兼容的 ZIP。")
            }
            var local = number(header, 42, 4)
            if local == 0xffffffff {
                let extra = try read(central + 46 + UInt64(nameSize), extraSize)
                var cursor = 0
                var found = false
                while cursor + 4 <= extra.count {
                    let type = number(extra, cursor, 2)
                    let length = Int(number(extra, cursor + 2, 2))
                    guard cursor + 4 + length <= extra.count else { throw invalid() }
                    if type == 0x0001 {
                        var field = cursor + 4
                        if number(header, 24, 4) == 0xffffffff { field += 8 }
                        if number(header, 20, 4) == 0xffffffff { field += 8 }
                        guard field + 8 <= cursor + 4 + length else { throw invalid() }
                        local = number(extra, field, 8)
                        found = true
                        break
                    }
                    cursor += 4 + length
                }
                guard found else { throw invalid() }
            }
            let localHeader = try read(local, 30)
            guard number(localHeader, 0, 4) == 0x04034b50 else { throw invalid() }
            try mark(central + 8, number(header, 8, 2))
            try mark(local + 6, number(localHeader, 6, 2))
            central += UInt64(46 + nameSize + extraSize + commentSize)
        }
    }
}
