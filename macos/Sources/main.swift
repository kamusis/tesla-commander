import AppKit
import Foundation
import WebKit

/// Main application delegate coordinating the window, WKWebView, native bridge, and telemetry stream.
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private var webView: WKWebView!
    private var bridgeHandler: BridgeHandler!
    private var telemetryStream: TelemetryStream!
    private var client: TessieClient!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let config = Config.shared
        print("[TeslaCommander] Initializing with VIN: \(config.vin), Token present: \(!config.token.isEmpty)")

        // 0. Set Application Icon
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") ?? Bundle.module.url(forResource: "AppIcon", withExtension: "icns") {
            NSApp.applicationIconImage = NSImage(contentsOf: iconURL)
        }

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
        let windowRect = NSRect(x: 0, y: 0, width: 1280, height: 860)
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

        // Check SPM Bundle.module
        if let moduleURL = Bundle.module.url(forResource: "tesla_dashboard", withExtension: "html") {
            return moduleURL
        }

        // Check App Bundle
        if let mainURL = Bundle.main.url(forResource: "tesla_dashboard", withExtension: "html") {
            return mainURL
        }

        // Check filesystem relative paths
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
}

// Application Entry Point
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
