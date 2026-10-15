import Foundation
import Darwin

// All source traversal is relative to open directories. Paths are only labels;
// replacing a parent with a symlink cannot redirect an already-open descriptor.
final class ArchiveDescriptor {
    let value: Int32
    init(_ value: Int32) throws {
        guard value >= 0 else { throw ArchiveFileSystem.failure("无法打开文件") }
        self.value = value
    }
    deinit { Darwin.close(value) }
}

enum ArchiveFileSystem {
    static func failure(_ message: String) -> ArchiveFailure {
        ArchiveFailure(message: "\(message)：\(String(cString: strerror(errno)))")
    }

    static func same(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && (a.st_mode & S_IFMT) == (b.st_mode & S_IFMT)
    }

    static func info(_ descriptor: ArchiveDescriptor) throws -> stat {
        var result = stat()
        guard fstat(descriptor.value, &result) == 0 else { throw failure("无法检查文件") }
        return result
    }

    static func info(_ name: String, in directory: ArchiveDescriptor) throws -> stat {
        var result = stat()
        guard fstatat(directory.value, name, &result, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw failure("无法检查“\(name)”")
        }
        return result
    }

    static func verify(_ name: String, in directory: ArchiveDescriptor, matches expected: stat) throws {
        guard let current = try? info(name, in: directory), same(current, expected) else {
            throw ArchiveFailure(message: "源文件或目录“\(name)”在压缩期间被替换，请保持源内容不变后重试。")
        }
    }

    static func directory(
        at url: URL,
        checking: (ArchiveDescriptor, String, stat) -> Void = { _, _, _ in }
    ) throws -> ArchiveDescriptor {
        var cache: [String: ArchiveDescriptor] = [:]
        return try directory(at: url, cache: &cache, checking: checking)
    }

    static func directory(
        at url: URL, cache: inout [String: ArchiveDescriptor],
        checking: (ArchiveDescriptor, String, stat) -> Void = { _, _, _ in }
    ) throws -> ArchiveDescriptor {
        // Foundation retains aliases such as /var on macOS even after resolving
        // symlinks. realpath supplies the actual components for a no-follow walk.
        guard let resolved = realpath(url.path, nil) else { throw failure("无法读取文件夹路径") }
        defer { free(resolved) }
        guard let path = String(validatingUTF8: resolved) else {
            throw ArchiveFailure(message: "文件夹路径不是有效的 UTF-8。")
        }
        let root = try cache["/"] ?? ArchiveDescriptor(Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC))
        cache["/"] = root
        var current = root
        var prefix = ""
        for part in path.split(separator: "/") {
            let component = String(part)
            prefix += "/" + component
            if let existing = cache[prefix] {
                current = existing
                continue
            }
            let expected = try info(component, in: current)
            let next = try open(component, in: current, expected: expected)
            guard try info(next).st_mode & S_IFMT == S_IFDIR else {
                throw ArchiveFailure(message: "“\(component)”不是文件夹。")
            }
            checking(current, component, expected)
            cache[prefix] = next
            current = next
        }
        return current
    }

    static func open(_ name: String, in directory: ArchiveDescriptor, expected: stat) throws -> ArchiveDescriptor {
        let isDirectory = expected.st_mode & S_IFMT == S_IFDIR
        // NONBLOCK prevents a regular file swapped for a FIFO from hanging open().
        let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | (isDirectory ? O_DIRECTORY : O_NONBLOCK)
        let descriptor = try ArchiveDescriptor(openat(directory.value, name, flags))
        guard same(try info(descriptor), expected) else {
            throw ArchiveFailure(message: "源文件或目录“\(name)”在压缩期间被替换。")
        }
        return descriptor
    }

    static func children(in directory: ArchiveDescriptor) throws -> [String] {
        let copy = dup(directory.value)
        guard copy >= 0 else { throw failure("无法读取目录") }
        guard let stream = fdopendir(copy) else { Darwin.close(copy); throw failure("无法读取目录") }
        defer { closedir(stream) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 { throw failure("无法读取目录内容") }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) {
                    String(validatingUTF8: $0)
                }
            }
            guard let name else { throw ArchiveFailure(message: "文件名不是有效的 UTF-8，无法创建兼容的 ZIP。") }
            if name != "." && name != ".." { names.append(name) }
        }
        return names.sorted()
    }

    static func link(_ name: String, in directory: ArchiveDescriptor) throws -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let count = readlinkat(directory.value, name, &buffer, buffer.count - 1)
        guard count >= 0, count < buffer.count - 1 else { throw failure("无法读取符号链接“\(name)”") }
        guard let value = String(validatingUTF8: buffer) else {
            throw ArchiveFailure(message: "符号链接“\(name)”包含无法编码的路径。")
        }
        return value
    }

    static func copyData(_ source: ArchiveDescriptor, name: String, into directory: ArchiveDescriptor) throws {
        // Clone from the already-open file, never from a path that can be changed.
        if fclonefileat(source.value, directory.value, name, UInt32(CLONE_NOOWNERCOPY)) == 0 { return }
        let target = try ArchiveDescriptor(openat(directory.value, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600)))
        guard fcopyfile(source.value, target.value, nil, copyfile_flags_t(COPYFILE_DATA | COPYFILE_DATA_SPARSE)) == 0 else {
            throw failure("无法复制“\(name)”")
        }
    }
}
