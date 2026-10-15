import AppKit
import FinderSync

final class DropZone: NSView {
    var onDrop: (([URL]) -> Bool)?
    var accepting = true
    private var highlighted = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 16
        registerForDraggedTypes([.fileURL])
        updateAppearance()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func viewDidChangeEffectiveAppearance() { updateAppearance() }
    private func updateAppearance() {
        layer?.backgroundColor = (highlighted ? NSColor.controlAccentColor.withAlphaComponent(0.12) : NSColor.controlBackgroundColor).cgColor
        layer?.borderColor = (highlighted ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
        layer?.borderWidth = highlighted ? 2 : 1
    }
    private func urls(_ board: NSPasteboard) -> [URL] {
        (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard accepting, !urls(sender.draggingPasteboard).isEmpty else { return [] }
        highlighted = true
        updateAppearance()
        return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) {
        highlighted = false
        updateAppearance()
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        highlighted = false
        updateAppearance()
        guard accepting else { return false }
        return onDrop?(urls(sender.draggingPasteboard)) ?? false
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private var drop: DropZone!
    private var titleLabel: NSTextField!
    private var detailLabel: NSTextField!
    private var statusLabel: NSTextField!
    private var chooseButton: NSButton!
    private var cancelButton: NSButton!
    private var revealButton: NSButton!
    private var spinner: NSProgressIndicator!
    private var cancellation: ArchiveCancellation?
    private var lastArchive: URL?
    private var ready = false
    private var hasShownWindow = false
    private var receivedBackgroundRequest = false
    private var backgroundJobs: [[URL]] = []
    private var backgroundRunning = false
    private var receivedUnsupportedURL = false

    init(backgroundFiles: [URL]? = nil) {
        super.init()
        if let files = backgroundFiles, !files.isEmpty {
            receivedBackgroundRequest = true
            backgroundJobs.append(files)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        makeMenu()
        makeWindow()
        ready = true
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        // File/URL/Services launches are not ordinary user launches. Never order a
        // window for these events; the relevant handler decides how to present them.
        let ordinaryLaunch = notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool ?? true
        if ordinaryLaunch && !receivedBackgroundRequest && !receivedUnsupportedURL { showWindow() }
        runNextBackgroundJob()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        // Finder may deliver open events before didFinishLaunching.
        enqueueBackground(filenames.map { URL(fileURLWithPath: $0) })
        sender.reply(toOpenOrPrint: .success)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard !urls.isEmpty else { return }
        if let directFiles = CompressionRequest.openedFiles(from: urls) {
            enqueueBackground(directFiles)
        } else {
            // Old Launch Services registrations may still deliver clearzip:// links.
            // Reject every non-file URL; a web link must never start compression.
            receivedUnsupportedURL = true
            DispatchQueue.main.async { [self] in
                if !hasShownWindow && cancellation == nil && !backgroundRunning && backgroundJobs.isEmpty {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if cancellation != nil || backgroundRunning || !backgroundJobs.isEmpty {
            let alert = NSAlert()
            alert.messageText = "压缩尚未结束"
            alert.informativeText = "请等待当前压缩任务完成后再退出。"
            alert.runModal()
            return .terminateCancel
        }
        return .terminateNow
    }

    // NSMessage=compress -> compress:userData:error: in the macOS Services protocol.
    @objc(compress:userData:error:)
    func compress(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        var urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if urls.isEmpty,
           let paths = pasteboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String] {
            urls = paths.map { URL(fileURLWithPath: $0) }
        }
        guard !urls.isEmpty else { error.pointee = "没有收到文件，请在 Finder 中选中文件后重试。"; return }
        enqueueBackground(urls)
    }

    private func enqueueBackground(_ urls: [URL]) {
        receivedBackgroundRequest = true
        backgroundJobs.append(urls)
        runNextBackgroundJob()
    }

    private func runNextBackgroundJob() {
        guard ready, !backgroundRunning, !backgroundJobs.isEmpty else { return }
        let urls = backgroundJobs.removeFirst()
        backgroundRunning = true
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let outcome = Result { try ArchiveEngine.compress(urls) }
            DispatchQueue.main.async { [self] in
                switch outcome {
                case .success(let result):
                    // Reveal in the Finder only while it is still the foreground app.
                    // A completed long job must not steal focus from the user's next task.
                    if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" {
                        NSWorkspace.shared.activateFileViewerSelecting([result.url])
                    }
                case .failure(let error):
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = "干净压缩失败"
                    alert.informativeText = error.localizedDescription
                    NSApp.activate(ignoringOtherApps: true)
                    alert.runModal()
                }
                backgroundRunning = false
                if backgroundJobs.isEmpty && !hasShownWindow {
                    NSApp.terminate(nil)
                } else {
                    runNextBackgroundJob()
                }
            }
        }
    }

    private func makeMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        menu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "关于 ClearZip", action: #selector(about), keyEquivalent: "")
        appMenu.addItem(.separator())
        let services = NSMenuItem(title: "服务", action: nil, keyEquivalent: "")
        services.submenu = NSMenu()
        appMenu.addItem(services)
        NSApp.servicesMenu = services.submenu
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 ClearZip", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "退出 ClearZip", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let fileItem = NSMenuItem()
        menu.addItem(fileItem)
        let fileMenu = NSMenu(title: "文件")
        fileItem.submenu = fileMenu
        fileMenu.addItem(withTitle: "压缩…", action: #selector(choose), keyEquivalent: "o")
        NSApp.mainMenu = menu
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.alignment = .center
        return field
    }

    private func add(_ view: NSView, to parent: NSView, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        view.frame = NSRect(x: x, y: y, width: width, height: height)
        parent.addSubview(view)
    }

    private func makeWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 420), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "ClearZip"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        let root = window.contentView!

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "doc.zipper", accessibilityDescription: "ZIP 压缩文件")
        icon.contentTintColor = .labelColor
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 28, weight: .regular)
        add(icon, to: root, x: 230, y: 364, width: 40, height: 34)
        add(label("干净压缩", size: 20, weight: .semibold), to: root, x: 30, y: 329, width: 440, height: 30)
        add(label("创建不含 macOS 附加信息的 ZIP 文件。", size: 13, color: .secondaryLabelColor), to: root, x: 30, y: 303, width: 440, height: 22)

        drop = DropZone(frame: .zero)
        drop.onDrop = { [weak self] urls in self?.start(urls) ?? false }
        add(drop, to: root, x: 30, y: 110, width: 440, height: 174)
        titleLabel = label("拖移文件或文件夹到此处", size: 18, weight: .semibold)
        add(titleLabel, to: drop, x: 18, y: 120, width: 404, height: 26)
        detailLabel = label("压缩文件将存储在原位置", size: 13, color: .secondaryLabelColor)
        add(detailLabel, to: drop, x: 18, y: 87, width: 404, height: 30)
        detailLabel.maximumNumberOfLines = 2
        detailLabel.lineBreakMode = .byTruncatingMiddle
        chooseButton = NSButton(title: "压缩…", target: self, action: #selector(choose))
        chooseButton.bezelStyle = .rounded
        chooseButton.keyEquivalent = "\r"
        add(chooseButton, to: drop, x: 160, y: 32, width: 120, height: 32)
        cancelButton = NSButton(title: "取消", target: self, action: #selector(cancel))
        cancelButton.bezelStyle = .rounded
        cancelButton.isHidden = true
        add(cancelButton, to: drop, x: 160, y: 32, width: 120, height: 32)
        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        add(spinner, to: drop, x: 210, y: 7, width: 20, height: 20)

        statusLabel = label("保留普通隐藏文件，移除 Finder 附加信息", size: 11, color: .secondaryLabelColor)
        add(statusLabel, to: root, x: 30, y: 80, width: 440, height: 22)
        statusLabel.maximumNumberOfLines = 1
        statusLabel.lineBreakMode = .byTruncatingMiddle
        let line = NSBox()
        line.boxType = .separator
        add(line, to: root, x: 30, y: 64, width: 440, height: 1)
        let hint = label("访达右键 → 干净压缩“项目名称”", size: 11, color: .secondaryLabelColor)
        hint.alignment = .left
        add(hint, to: root, x: 30, y: 25, width: 310, height: 20)
        let serviceButton = NSButton(title: "访达扩展…", target: self, action: #selector(serviceHelp))
        serviceButton.bezelStyle = .rounded
        add(serviceButton, to: root, x: 379, y: 18, width: 91, height: 32)
        revealButton = NSButton(title: "在访达中显示", target: self, action: #selector(reveal))
        revealButton.bezelStyle = .rounded
        revealButton.isHidden = true
        add(revealButton, to: drop, x: 235, y: 32, width: 164, height: 32)
    }

    private func showWindow() {
        hasShownWindow = true
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func choose() {
        guard cancellation == nil else { return }
        let panel = NSOpenPanel()
        panel.title = "选择要压缩的项目"
        panel.prompt = "压缩"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK { _ = self?.start(panel.urls) }
        }
    }

    @discardableResult private func start(_ urls: [URL]) -> Bool {
        guard cancellation == nil, !urls.isEmpty else { return false }
        showWindow()
        let token = ArchiveCancellation()
        cancellation = token
        drop.accepting = false
        chooseButton.isHidden = true
        revealButton.isHidden = true
        cancelButton.isHidden = false
        cancelButton.isEnabled = true
        window.title = CompressionRequest.title(for: urls)
        titleLabel.stringValue = "正在压缩…"
        detailLabel.textColor = .labelColor
        detailLabel.stringValue = urls.count == 1 ? "“\(urls[0].lastPathComponent)”" : "\(urls.count) 个项目"
        statusLabel.stringValue = "正在准备文件…"
        spinner.startAnimation(nil)
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            var lastUpdate = Date.distantPast
            let outcome = Result {
                try ArchiveEngine.compress(urls, cancellation: token) { message in
                    guard !message.hasPrefix("正在准备：") || Date().timeIntervalSince(lastUpdate) > 0.1 else { return }
                    lastUpdate = Date()
                    DispatchQueue.main.async { [self] in
                        if cancelButton.isEnabled { statusLabel.stringValue = message }
                    }
                }
            }
            DispatchQueue.main.async { [self] in finish(outcome) }
        }
        return true
    }

    private func finish(_ outcome: Result<ArchiveResult, Error>) {
        cancellation = nil
        window.title = "ClearZip"
        drop.accepting = true
        spinner.stopAnimation(nil)
        cancelButton.isHidden = true
        chooseButton.isHidden = false
        chooseButton.frame.origin.x = 160
        chooseButton.title = "压缩…"
        chooseButton.keyEquivalent = "\r"
        revealButton.keyEquivalent = ""
        switch outcome {
        case .success(let result):
            lastArchive = result.url
            titleLabel.stringValue = "压缩完成"
            detailLabel.stringValue = result.url.lastPathComponent
            statusLabel.stringValue = "已创建 ZIP 文件，不含 macOS 附加信息"
            chooseButton.title = "压缩其他项目…"
            chooseButton.frame.origin.x = 52
            chooseButton.keyEquivalent = ""
            revealButton.keyEquivalent = "\r"
            revealButton.isHidden = false
            NSWorkspace.shared.activateFileViewerSelecting([result.url])
        case .failure(let error):
            if error is CancellationError {
                titleLabel.stringValue = "压缩已取消"
                detailLabel.stringValue = "可以重新选择要压缩的项目"
                statusLabel.stringValue = "原文件保持不变"
            } else {
                titleLabel.stringValue = "未能完成压缩"
                detailLabel.stringValue = "请检查文件权限和保存位置后重试"
                statusLabel.stringValue = "原文件保持不变"
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "压缩失败"
                alert.informativeText = error.localizedDescription
                alert.beginSheetModal(for: window)
            }
        }
    }

    @objc private func cancel() {
        guard let cancellation else { return }
        cancellation.cancel()
        cancelButton.isEnabled = false
        titleLabel.stringValue = "正在取消…"
        statusLabel.stringValue = "正在清理临时文件…"
    }
    @objc private func reveal() {
        if let lastArchive { NSWorkspace.shared.activateFileViewerSelecting([lastArchive]) }
    }
    @objc private func serviceHelp() {
        NSUpdateDynamicServices()
        let alert = NSAlert()
        alert.messageText = "启用访达扩展"
        alert.informativeText = "将 ClearZip.app 移到“应用程序”文件夹，并在系统的访达扩展设置中启用 ClearZip。\n\n启用后，右键选中的项目会显示带拉链图标的“干净压缩‘项目名称’”；多选显示项目数量。\n\n未启用扩展时，仍可使用“服务 → 干净压缩”，或将文件拖入此窗口。"
        alert.addButton(withTitle: "打开扩展设置")
        alert.addButton(withTitle: "好")
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { FIFinderSyncController.showExtensionManagementInterface() }
        }
    }
    @objc private func about() { NSApp.orderFrontStandardAboutPanel(nil) }
}
