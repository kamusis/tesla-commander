import AppKit
import Foundation
import WebKit

/// Main application delegate coordinating the window, WKWebView, native bridge, and telemetry stream.
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    private var window: NSWindow!
    private var webView: WKWebView!
    private var bridgeHandler: BridgeHandler!
    private var telemetryStream: TelemetryStream!
    private var client: TessieClient!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let config = Config.shared
        print("[TeslaCommander] Initializing with VIN: \(config.vin), Token present: \(!config.token.isEmpty)")

        // 0. Set Application Icon
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") {
            NSApp.applicationIconImage = NSImage(contentsOf: iconURL)
        }

        // 0.1 Setup Application Main Menu (Cmd+Q, Cmd+W, Cmd+C/V, etc.)
        setupMainMenu()

        // 1. Initialize Clients and Handlers
        self.client = TessieClient(token: config.token, vin: config.vin)
        self.bridgeHandler = BridgeHandler(client: client)
        self.telemetryStream = TelemetryStream()

        // 2. Configure WKWebView with Native Script Message Handler
        let webConfig = WKWebViewConfiguration()
        let userController = WKUserContentController()
        userController.add(bridgeHandler, name: "teslaNative")
        webConfig.userContentController = userController
        webConfig.preferences.setValue(true, forKey: "developerExtrasEnabled")

        // 3. Create NSWindow
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let targetWidth: CGFloat = min(1320, max(960, screenFrame.width - 40))
        let targetHeight: CGFloat = min(980, max(700, screenFrame.height - 40))
        let windowRect = NSRect(x: 0, y: 0, width: targetWidth, height: targetHeight)
        self.window = NSWindow(
            contentRect: windowRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        self.window.center()
        self.window.minSize = NSSize(width: 960, height: 600)
        self.window.title = "Tesla Commander — Moomin Y (Model Y)"
        self.window.delegate = self

        // 4. Attach WKWebView
        self.webView = WKWebView(frame: windowRect, configuration: webConfig)
        self.webView.autoresizingMask = [.width, .height]
        self.webView.navigationDelegate = self
        self.webView.uiDelegate = self
        self.bridgeHandler.webView = self.webView
        self.window.contentView = self.webView

        // 5. Load Dashboard HTML
        loadDashboardContent()

        // 6. Connect Real-time Telemetry Stream
        setupTelemetryStream(config: config)

        // 7. Present Window
        self.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // 8. Fetch Initial Full Snapshot on launch
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            Task { @MainActor in
                await self?.bridgeHandler.refreshVehicleState()
            }
        }

        // 9. Periodic Heartbeat Refresh (every 30s)
        Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.bridgeHandler.refreshVehicleState()
            }
        }
    }

    private func setupTelemetryStream(config: Config) {
        telemetryStream.onConnectionStateChange = { [weak self] connected in
            self?.bridgeHandler.sendStreamingStatus(connected: connected)
        }

        telemetryStream.onTelemetryFrame = { [weak self] frame in
            self?.bridgeHandler.sendTelemetryFrame(frame)
        }

        Task {
            do {
                let resolvedVin = try await client.resolveVin()
                print("[TeslaCommander] Dynamically resolved vehicle VIN: \(resolvedVin)")
                telemetryStream.connect(vin: resolvedVin, token: config.token)
            } catch {
                print("[TeslaCommander] Failed to resolve vehicle VIN: \(error.localizedDescription)")
            }
        }
    }

    private func loadDashboardContent() {
        if let fileURL = locateDashboardFile() {
            print("[TeslaCommander] Loading dashboard from file: \(fileURL.path)")
            webView.loadFileURL(fileURL, allowingReadAccessTo: fileURL.deletingLastPathComponent())
        } else {
            print("[TeslaCommander] Error: Could not locate tesla_dashboard.html")
            let fallbackHTML = "<html><body style='font-family:sans-serif;padding:40px;'><h2>Tesla Commander</h2><p>Could not locate <code>tesla_dashboard.html</code>.</p></body></html>"
            webView.loadHTMLString(fallbackHTML, baseURL: nil)
        }
    }

    private func locateDashboardFile() -> URL? {
        let fm = FileManager.default

        // 1. Check App Bundle (standard for macOS .app)
        if let mainURL = Bundle.main.url(forResource: "tesla_dashboard", withExtension: "html") {
            return mainURL
        }

        // 2. Check filesystem relative paths (for local dev / direct execution)
        let cwd = fm.currentDirectoryPath
        let candidates = [
            (cwd as NSString).appendingPathComponent("Sources/Resources/tesla_dashboard.html"),
            (cwd as NSString).appendingPathComponent("macos/Sources/Resources/tesla_dashboard.html")
        ]

        for path in candidates {
            if fm.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }

        return nil
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        telemetryStream.disconnect()
    }

    // MARK: - WKNavigationDelegate & WKUIDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        // Allow loading local dashboard file or file schemes
        if url.isFileURL || (navigationAction.navigationType == .other && url.scheme == "file") {
            decisionHandler(.allow)
            return
        }

        // Open external web links in macOS default browser
        if url.scheme == "http" || url.scheme == "https" || url.scheme == "maps" {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }

        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Instantly populate dashboard with locally cached trips (0ms network delay)
        self.bridgeHandler.sendInitialCachedState()
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Intercept target="_blank" links and open in macOS system browser
        if let url = navigationAction.request.url {
            NSWorkspace.shared.open(url)
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = "Tesla Commander"
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Tesla Commander"
        alert.informativeText = message
        alert.addButton(withTitle: "确认")
        alert.addButton(withTitle: "取消")
        let res = alert.runModal()
        completionHandler(res == .alertFirstButtonReturn)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Tesla Commander"
        alert.informativeText = prompt
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        input.stringValue = defaultText ?? ""
        alert.accessoryView = input
        let res = alert.runModal()
        if res == .alertFirstButtonReturn {
            completionHandler(input.stringValue)
        } else {
            completionHandler(nil)
        }
    }

    // MARK: - Native macOS Main Menu (Cmd+Q, Cmd+W, Cmd+C/V, etc.)

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // 1. Application Menu (Tesla Commander)
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu

        let appName = "Tesla Commander"
        appMenu.addItem(withTitle: "关于 \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "隐藏 \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthersItem = NSMenuItem(title: "隐藏其他", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthersItem)
        appMenu.addItem(withTitle: "显示全部", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "退出 \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // 2. File Menu
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "文件")
        fileMenuItem.submenu = fileMenu
        fileMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        // 3. Edit Menu (Crucial for Copy / Paste / Cut / Select All in WKWebView)
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "编辑")
        editMenuItem.submenu = editMenu
        editMenu.addItem(withTitle: "撤销", action: #selector(UndoManager.undo), keyEquivalent: "z")
        let redoItem = NSMenuItem(title: "重做", action: #selector(UndoManager.redo), keyEquivalent: "Z")
        editMenu.addItem(redoItem)
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        // 4. View Menu
        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "视图")
        viewMenuItem.submenu = viewMenu
        let reloadItem = NSMenuItem(title: "刷新数据", action: #selector(handleMenuRefresh), keyEquivalent: "r")
        reloadItem.target = self
        viewMenu.addItem(reloadItem)
        viewMenu.addItem(NSMenuItem.separator())
        viewMenu.addItem(withTitle: "进入全屏幕", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")

        // 5. Window Menu
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "窗口")
        windowMenuItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(NSMenuItem.separator())
        windowMenu.addItem(withTitle: "前置所有窗口", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    @objc private func handleMenuRefresh() {
        Task { @MainActor in
            await bridgeHandler.refreshVehicleState(manual: true)
        }
    }
}

// Application Entry Point
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
