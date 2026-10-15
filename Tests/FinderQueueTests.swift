import Foundation
import Darwin

@main
struct FinderQueueTests {
    static func check(_ condition: @autoclosure () throws -> Bool) throws { let value = try condition(); precondition(value) }
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clearzip-queue-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = root.appendingPathComponent("queue")
        let files = [URL(fileURLWithPath: "/tmp/中文 \" ?#%\n.txt"), URL(fileURLWithPath: "/tmp/second")]
        try FinderRequestQueue.enqueue(files, in: queue)
        try check(FinderRequestQueue.takeAll(from: queue) == [files])
        try check(FinderRequestQueue.takeAll(from: queue).isEmpty)
        print("PASS queue: special paths round-trip, requests claimed once")

        let packet = try JSONSerialization.data(withJSONObject: ["paths": ["/tmp/outside"], "created": Date().timeIntervalSince1970])
        let outside = root.appendingPathComponent("outside.json")
        try packet.write(to: outside)
        let link = queue.appendingPathComponent("\(UUID()).json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let fifo = queue.appendingPathComponent("\(UUID()).json")
        precondition(mkfifo(fifo.path, 0o600) == 0)
        try check(FinderRequestQueue.takeAll(from: queue).isEmpty)
        try check(Data(contentsOf: outside) == packet)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: queue)
        do { _ = try FinderRequestQueue.takeAll(from: alias); fatalError("Followed queue symlink") } catch {}
        print("PASS queue: request/queue symlinks and FIFO never read")

        let bad = queue.appendingPathComponent("\(UUID()).json")
        try Data("{\"paths\":[\"relative\"],\"created\":0}".utf8).write(to: bad)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: bad.path)
        try check(FinderRequestQueue.takeAll(from: queue).isEmpty)
        try FinderRequestQueue.enqueue(files, in: queue)
        try check(FinderRequestQueue.takeAll(from: queue, now: Date().addingTimeInterval(601)).isEmpty)
        do { _ = try FinderRequestQueue.enqueue([URL(string: "https://example.com/")!], in: queue); fatalError("Accepted web URL") } catch {}
        print("PASS queue: expired, malformed and external requests rejected")

        let mutex = NSLock()
        var errors: [Error] = []
        DispatchQueue.concurrentPerform(iterations: 50) { i in
            do { try FinderRequestQueue.enqueue([URL(fileURLWithPath: "/tmp/item-\(i)")], in: queue) }
            catch { mutex.lock(); errors.append(error); mutex.unlock() }
        }
        precondition(errors.isEmpty)
        var received: [[URL]] = []
        DispatchQueue.concurrentPerform(iterations: 4) { _ in
            do {
                let jobs = try FinderRequestQueue.takeAll(from: queue)
                mutex.lock(); received.append(contentsOf: jobs); mutex.unlock()
            } catch { mutex.lock(); errors.append(error); mutex.unlock() }
        }
        precondition(errors.isEmpty && received.count == 50)
        precondition(Set(received.flatMap { $0.map(\.path) }).count == 50)
        print("PASS queue: parallel producers/consumers deliver every request once")
    }
}
