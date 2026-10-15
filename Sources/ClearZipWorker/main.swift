import AppKit

// The extension only writes its private cache; this worker reads source files.
let identifier = Bundle.main.object(forInfoDictionaryKey: "ClearZipRequestSource") as? String ?? FinderRequestQueue.extensionIdentifier
let directory = FinderRequestQueue.receiverDirectory(for: identifier)
var failures: [Error] = []
do {
    for files in try FinderRequestQueue.takeAll(from: directory) {
        do {
            let result = try ArchiveEngine.compress(files)
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" {
                NSWorkspace.shared.activateFileViewerSelecting([result.url])
            }
        } catch { failures.append(error) }
    }
} catch { failures.append(error) }
if let error = failures.first {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "干净压缩失败"
    alert.informativeText = error.localizedDescription
    app.activate(ignoringOtherApps: true)
    alert.runModal()
    exit(1)
}
exit(0)
