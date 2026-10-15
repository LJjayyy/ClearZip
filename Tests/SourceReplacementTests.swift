import Foundation
import Darwin

@main
struct SourceReplacementTests {
    static let fm = FileManager.default

    static func main() throws {
        // The progress callback gives each replacement a deterministic point between
        // inspecting an entry and reading its data. No timing-dependent race loop.
        for kind in ["selected-directory", "nested-directory", "ancestor", "file-link", "file-inode", "file-fifo", "late-directory"] {
            try rejectsReplacement(kind)
        }
        try temporaryReplacementCannotRedirectReads()
    }

    static func fixture() throws -> URL {
        let root = fm.temporaryDirectory.appendingPathComponent("clearzip-source-" + UUID().uuidString)
        for name in ["input/selected/nested", "outside/nested", "output"] {
            try fm.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try Data("SELECTED_CONTENT".utf8).write(to: root.appendingPathComponent("input/selected/nested/payload"))
        for name in ["outside/payload", "outside/nested/payload"] {
            try Data("OUTSIDE_CONTENT".utf8).write(to: root.appendingPathComponent(name))
        }
        return root
    }

    static func rejectsReplacement(_ kind: String) throws {
        let root = try fixture()
        defer { try? fm.removeItem(at: root) }
        let selected = root.appendingPathComponent("input/selected")
        let outside = root.appendingPathComponent("outside")
        let output = root.appendingPathComponent("output")
        var changed = false
        var hookFailure: Error?
        do {
            _ = try ArchiveEngine.compress([selected], destination: output) { message in
                let phase = kind == "late-directory" ? "正在压缩" : "正在准备："
                guard !changed, message.hasPrefix(phase) else { return }
                changed = true
                do {
                    let victim: URL
                    switch kind {
                    case "selected-directory", "late-directory": victim = selected
                    case "nested-directory": victim = selected.appendingPathComponent("nested")
                    case "ancestor": victim = root.appendingPathComponent("input")
                    default: victim = selected.appendingPathComponent("nested/payload")
                    }
                    // Keep the original inode alive, so a new entry cannot reuse it.
                    try fm.moveItem(at: victim, to: root.appendingPathComponent("before"))
                    if kind == "file-inode" {
                        try Data("REPLACEMENT_CONTENT".utf8).write(to: victim)
                    } else if kind == "file-fifo" {
                        guard mkfifo(victim.path, 0o600) == 0 else { throw ArchiveFileSystem.failure("mkfifo") }
                    } else {
                        let target = kind == "file-link" ? outside.appendingPathComponent("payload") : outside
                        try fm.createSymbolicLink(at: victim, withDestinationURL: target)
                    }
                } catch { hookFailure = error }
            }
            fatalError("Published an archive after \(kind) replacement")
        } catch is ArchiveFailure {
            if let hookFailure { throw hookFailure }
            precondition(changed, "Replacement was not exercised: \(kind)")
            let remaining = try fm.contentsOfDirectory(atPath: output.path)
            let outsideContents = try String(contentsOf: outside.appendingPathComponent("payload"), encoding: .utf8)
            precondition(remaining.isEmpty, "Left a ZIP or staging directory after \(kind)")
            precondition(outsideContents == "OUTSIDE_CONTENT")
            print("PASS source replacement: \(kind)")
        }
    }

    static func temporaryReplacementCannotRedirectReads() throws {
        let root = try fixture()
        defer { try? fm.removeItem(at: root) }
        let selected = root.appendingPathComponent("input/selected")
        let nested = selected.appendingPathComponent("nested")
        let saved = root.appendingPathComponent("saved")
        try Data("SECOND_FILE".utf8).write(to: nested.appendingPathComponent("z-last"))
        try Data("OUTSIDE_SECOND".utf8).write(to: root.appendingPathComponent("outside/nested/z-last"))
        var swapped = false
        var restored = false
        var hookFailure: Error?
        let result = try ArchiveEngine.compress([selected], destination: root.appendingPathComponent("output")) { message in
            do {
                if message == "正在准备：payload" {
                    try fm.moveItem(at: selected, to: saved)
                    try fm.createSymbolicLink(at: selected, withDestinationURL: root.appendingPathComponent("outside"))
                    swapped = true
                } else if message == "正在准备：z-last", swapped {
                    try fm.removeItem(at: selected)
                    try fm.moveItem(at: saved, to: selected)
                    restored = true
                }
            } catch { hookFailure = error }
        }
        if let hookFailure { throw hookFailure }
        precondition(swapped && restored, "Temporary substitution was not exercised")
        let pipe = Pipe()
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-p", result.url.path, "selected/nested/payload"]
        unzip.standardOutput = pipe
        try unzip.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        unzip.waitUntilExit()
        precondition(unzip.terminationStatus == 0 && data == Data("SELECTED_CONTENT".utf8), "Read data through a substituted parent")
        print("PASS source replacement: temporary parent substitution never reads outside data")
    }
}
