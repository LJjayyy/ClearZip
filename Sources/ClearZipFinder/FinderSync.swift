import AppKit
import FinderSync

@objc(ClearZipFinderSync)
final class ClearZipFinderSync: FIFinderSync {
    override init() {
        super.init()
        // Finder supplies visible selections only. No filesystem crawling, badges or sync work.
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard menuKind == .contextualMenuForItems,
              let urls = FIFinderSyncController.default().selectedItemURLs(), !urls.isEmpty else { return nil }
        let menu = NSMenu()
        let item = NSMenuItem(title: CompressionRequest.title(for: urls), action: #selector(compress(_:)), keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: "doc.zipper", accessibilityDescription: "干净压缩")
        item.image?.isTemplate = true
        item.image?.size = NSSize(width: 16, height: 16)
        menu.addItem(item)
        return menu
    }

    @objc private func compress(_ sender: NSMenuItem) {
        // Finder transports menu items across processes; representedObject is not retained.
        let selection = FIFinderSyncController.default().selectedItemURLs()
        guard let urls = selection else { return }
        // Schedule the background worker launch on the main event loop.
        DispatchQueue.main.async {
            FinderWorkerHandoff.perform(urls) { success in
                if !success { NSLog("ClearZip: unable to launch the background compression worker") }
            }
        }
    }
}
