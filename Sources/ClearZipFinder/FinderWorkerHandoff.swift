import AppKit

// The extension only writes its own cache. The worker reads source files.
enum FinderWorkerHandoff {
    static func perform(_ urls: [URL], workerURL: URL? = nil, completion: @escaping (Bool) -> Void) {
        do {
            let name = try FinderRequestQueue.enqueue(urls)
            let host = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let worker = workerURL ?? host.appendingPathComponent("Contents/Helpers/ClearZipWorker.app")
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.addsToRecentItems = false
            configuration.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: worker, configuration: configuration) { _, error in
                if error != nil { FinderRequestQueue.discard(name) }
                completion(error == nil)
            }
        } catch {
            completion(false)
        }
    }
}
