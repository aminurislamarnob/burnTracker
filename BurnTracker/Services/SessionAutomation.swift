import AppKit
import WebKit

/// Opens claude.ai in an embedded `WKWebView` with the account's session cookie
/// injected, in an isolated (non-persistent) data store. The chat opens ready
/// for input — the user types and sends their own message.
final class SessionWindowController: NSObject {
    // Retain controllers for the lifetime of their windows.
    private static var active: [SessionWindowController] = []

    private var window: NSWindow?
    private var webView: WKWebView?

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

        let load: () -> Void = { [weak web] in
            web?.load(URLRequest(url: URL(string: "https://claude.ai/new")!))
        }

        if let cookie {
            config.websiteDataStore.httpCookieStore.setCookie(cookie) { load() }
        } else {
            load()
        }
    }
}
