import Foundation
import Darwin

enum FinderRequestQueue {
    static let extensionIdentifier = "com.clearzip.mac.finder"
    static let directoryName = "com.clearzip.finder-requests"
    private static let maximumBytes = 1_048_576

    private struct Request: Codable {
        let paths: [String]
        let created: TimeInterval
    }

    static var senderDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent(directoryName)
    }

    static func receiverDirectory(for identifier: String = extensionIdentifier) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/\(identifier)/Data/Library/Caches/\(directoryName)")
    }

    @discardableResult
    static func enqueue(_ urls: [URL], in directory: URL = senderDirectory) throws -> String {
        guard let files = CompressionRequest.openedFiles(from: urls) else { throw failure() }
        let data = try JSONEncoder().encode(Request(paths: files.map(\.path), created: Date().timeIntervalSince1970))
        guard data.count <= maximumBytes else { throw failure() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return try locked(directory) { root in
            let name = "\(UUID().uuidString).json"
            let fd = openat(root, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw failure() }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            do {
                try handle.write(contentsOf: data)
                try handle.close()
                return name
            } catch {
                unlinkat(root, name, 0)
                throw error
            }
        }
    }

    static func discard(_ name: String, in directory: URL = senderDirectory) {
        guard validName(name) else { return }
        try? locked(directory) { root in _ = unlinkat(root, name, 0) }
    }

    static func takeAll(from directory: URL = receiverDirectory(), now: Date = Date()) throws -> [[URL]] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try locked(directory) { root in
            var requests: [(TimeInterval, [URL])] = []
            for name in try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() where validName(name) {
                let fd = openat(root, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard fd >= 0 else { continue }
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                defer { try? handle.close() }
                var info = stat()
                guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                      info.st_uid == geteuid(), info.st_size <= maximumBytes,
                      info.st_mode & 0o077 == 0 else { continue }
                var data = Data()
                do {
                    while data.count <= maximumBytes {
                        let chunk = try handle.read(upToCount: maximumBytes + 1 - data.count) ?? Data()
                        if chunk.isEmpty { break }
                        data.append(chunk)
                    }
                } catch { continue }
                // Claim under the queue lock before starting any archive job.
                guard unlinkat(root, name, 0) == 0 else { continue }
                guard data.count <= maximumBytes,
                      let request = try? JSONDecoder().decode(Request.self, from: data),
                      !request.paths.isEmpty,
                      request.paths.allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") }),
                      now.timeIntervalSince1970 - request.created >= -30,
                      now.timeIntervalSince1970 - request.created <= 600 else { continue }
                requests.append((request.created, request.paths.map { URL(fileURLWithPath: $0) }))
            }
            return requests.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
    }

    private static func validName(_ name: String) -> Bool {
        name.hasSuffix(".json") && UUID(uuidString: String(name.dropLast(5))) != nil
    }

    private static func locked<T>(_ directory: URL, body: (Int32) throws -> T) throws -> T {
        let root = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw failure() }
        defer { close(root) }
        var info = stat()
        guard fstat(root, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else { throw failure() }
        let lock = openat(root, ".lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw failure() }
        defer { close(lock) }
        guard fstat(lock, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(),
              flock(lock, LOCK_EX) == 0 else { throw failure() }
        defer { flock(lock, LOCK_UN) }
        return try body(root)
    }

    private static func failure() -> NSError {
        NSError(domain: "ClearZip.FinderHandoff", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "无法交接选中的文件，请重试。"])
    }
}
