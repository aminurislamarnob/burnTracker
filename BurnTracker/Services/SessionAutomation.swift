import AppKit
import WebKit
import os.log

/// Opens claude.ai in an embedded `WKWebView` with the account's session cookie
/// injected, in an isolated (non-persistent) data store. The chat opens ready
/// for input — the user types and sends their own message.
final class SessionWindowController: NSObject {
    // Retain controllers for the lifetime of their windows.
    private static var active: [SessionWindowController] = []

    private var window: NSWindow?
    private var webView: WKWebView?
    private var loadRetries = 0
    private let maxLoadRetries = 3
    private static let log = Logger(subsystem: "com.burntracker", category: "SessionWindow")

    @MainActor
    static func start(accountId: String, sessionKey: String) {
        let controller = SessionWindowController()
        active.append(controller)
        controller.open(accountId: accountId, sessionKey: sessionKey)
    }

    @MainActor
    private func open(accountId: String, sessionKey: String) {
        // Per-account non-persistent data store so cookies stay isolated.
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()

        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1024, height: 768), configuration: config)
        web.navigationDelegate = self
        self.webView = web

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1024, height: 768),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        win.title = "Claude Chat"
        win.backgroundColor = NSColor(red: 0x16/255, green: 0x16/255, blue: 0x1a/255, alpha: 1)
        win.center()
        win.contentView = web
        win.isReleasedWhenClosed = false
        win.delegate = nil
        self.window = win

        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)

        // Set the session cookie, then load claude.ai/new.
        let cookie = HTTPCookie(properties: [
            .domain: "claude.ai",
            .path: "/",
            .name: "sessionKey",
            .value: sessionKey,
            .secure: true,
            .init(rawValue: "HttpOnly"): true
        ])

        guard let cookie else {
            loadChat()
            return
        }

        // Set the cookie on the web view's *own* data store. A configuration is
        // copied when handed to `WKWebView`, so `config.websiteDataStore` is not
        // guaranteed to be the store the web view navigates with — writing the
        // cookie there let claude.ai/new load unauthenticated (no chatbox).
        web.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) { [weak self] in
            self?.loadChat()
        }
    }

    @MainActor
    private func loadChat() {
        webView?.load(URLRequest(url: URL(string: "https://claude.ai/new")!))
    }
}

extension SessionWindowController: WKNavigationDelegate {
    // Retry transient load failures (network hiccup, slow cookie propagation)
    // instead of leaving a blank window.
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Self.log.error("provisional navigation failed: \(error.localizedDescription, privacy: .public)")
        retryLoad(after: error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Self.log.error("navigation failed: \(error.localizedDescription, privacy: .public)")
        retryLoad(after: error)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadRetries = 0
    }

    // The WebContent (renderer) process can be killed under memory pressure or
    // by a crash, leaving the window blank with no automatic recovery. Reload
    // the chat when that happens — the common cause of an intermittent blank window.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Self.log.error("web content process terminated — reloading")
        loadChat()
    }

    private func retryLoad(after error: Error) {
        // Ignore user-initiated cancellations (e.g. redirects superseding a load).
        if (error as NSError).code == NSURLErrorCancelled { return }
        guard loadRetries < maxLoadRetries else { return }
        loadRetries += 1
        let delay = 0.5 * Double(loadRetries)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.loadChat()
        }
    }
}
