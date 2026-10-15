import AppKit
import Security

@main
final class FinderHandoffProbe: NSObject, NSApplicationDelegate {
    static func main() {
        guard let task = SecTaskCreateFromSelf(nil),
              SecTaskCopyValueForEntitlement(task, "com.apple.security.app-sandbox" as CFString, nil) as? Bool == true else {
            fputs("Probe must run with App Sandbox enabled\n", stderr)
            exit(2)
        }
        let app = NSApplication.shared
        let delegate = FinderHandoffProbe()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard CommandLine.arguments.count >= 3 else { exit(2) }
        let worker = URL(fileURLWithPath: CommandLine.arguments[1])
        let urls = CommandLine.arguments.dropFirst(2).map { URL(fileURLWithPath: $0) }
        FinderWorkerHandoff.perform(urls, workerURL: worker) { success in exit(success ? 0 : 1) }
    }
}
