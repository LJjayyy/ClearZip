import Foundation

enum CompressionRequest {
    static func title(for urls: [URL]) -> String {
        urls.count == 1 ? "干净压缩“\(urls[0].lastPathComponent)”" : "干净压缩 \(urls.count) 个项目"
    }

    static func arguments(for urls: [URL]) -> [String]? {
        guard let files = openedFiles(from: urls) else { return nil }
        return ["--finder-compress", "--"] + files.map(\.path)
    }

    static func files(from arguments: [String]) -> [URL]? {
        guard arguments.count > 2, arguments[0] == "--finder-compress", arguments[1] == "--" else { return nil }
        let paths = arguments.dropFirst(2)
        guard paths.allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") }) else { return nil }
        return paths.map { URL(fileURLWithPath: $0) }
    }

    static func openedFiles(from urls: [URL]) -> [URL]? {
        // Accept an entire local-file request or reject it. Filtering would let a
        // mixed file/URL event partially execute an otherwise unsupported request.
        guard !urls.isEmpty, urls.allSatisfy({ url in
            url.isFileURL && (url.host == nil || url.host == "" || url.host?.lowercased() == "localhost") &&
                url.path.hasPrefix("/") && !url.path.contains("\0") && !url.absoluteString.contains("%00")
        }) else { return nil }
        return urls
    }
}
