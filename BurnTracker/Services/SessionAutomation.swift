import AppKit
import WebKit

/// Opens claude.ai in an embedded `WKWebView`, injects the account's session
/// cookie, then types and sends a prompt — a faithful port of the
/// `claude:startSession` handler from the original `main.js`.
///
/// NOTE: Electron used the native `webContents.insertText`, which reliably
/// drove ProseMirror. WKWebView has no equivalent, so the prompt is injected
/// via JS (execCommand + input events). This is the most fragile part of the
/// app; if claude.ai's editor stops accepting synthetic input, fall back to
/// opening the URL in the default browser.
final class SessionWindowController: NSObject, WKNavigationDelegate {
    // Retain controllers for the lifetime of their windows.
    private static var active: [SessionWindowController] = []

    private let prompt: String
    private var window: NSWindow?
    private var webView: WKWebView?

    private init(prompt: String) {
        self.prompt = prompt
    }

    @MainActor
    static func start(accountId: String, sessionKey: String, prompt: String) {
        let controller = SessionWindowController(prompt: prompt)
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

        let load: () -> Void = { [weak web] in
            web?.load(URLRequest(url: URL(string: "https://claude.ai/new")!))
        }

        if let cookie {
            config.websiteDataStore.httpCookieStore.setCookie(cookie) { load() }
        } else {
            load()
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        automate(webView)
    }

    private func automate(_ webView: WKWebView) {
        // 1. Poll for and focus the editor (≤50 attempts, 200ms apart).
        let focusJS = """
        new Promise((resolve) => {
          let attempts = 0;
          function tryFocus() {
            attempts++;
            const editor = document.querySelector('div[contenteditable="true"], .ProseMirror');
            if (editor) { editor.focus(); resolve(true); }
            else if (attempts < 50) { setTimeout(tryFocus, 200); }
            else { resolve(false); }
          }
          setTimeout(tryFocus, 500);
        });
        """

        webView.callAsyncJavaScript(focusJS, arguments: [:], in: nil, in: .page) { [weak self, weak webView] result in
            guard let self, let webView else { return }
            if case .success(let value) = result, (value as? Bool) == true {
                self.insertAndSend(webView)
            } else {
                NSLog("BurnTracker: could not find Claude editor element")
            }
        }
    }

    private func insertAndSend(_ webView: WKWebView) {
        // 2. Insert text via execCommand + input event (best-effort ProseMirror drive).
        let escaped = prompt
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")

        let insertJS = """
        (function() {
          const editor = document.querySelector('div[contenteditable="true"], .ProseMirror');
          if (!editor) return false;
          editor.focus();
          const text = `\(escaped)`;
          let ok = false;
          try { ok = document.execCommand('insertText', false, text); } catch (e) {}
          if (!ok) {
            editor.textContent = text;
            editor.dispatchEvent(new InputEvent('input', { bubbles: true, cancelable: true, data: text, inputType: 'insertText' }));
          }
          return true;
        })();
        """

        webView.evaluateJavaScript(insertJS) { [weak self, weak webView] _, _ in
            guard let self, let webView else { return }
            // Wait for React/ProseMirror to acknowledge the insertion, then send.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                let sendJS = """
                (function() {
                  const sendBtn = document.querySelector('button[aria-label="Send Message"]');
                  if (sendBtn && !sendBtn.disabled) {
                    sendBtn.click();
                  } else {
                    const editor = document.querySelector('div[contenteditable="true"], .ProseMirror');
                    if (editor) {
                      const enterEvent = new KeyboardEvent('keydown', {
                        key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true, cancelable: true
                      });
                      editor.dispatchEvent(enterEvent);
                    }
                  }
                })();
                """
                webView.evaluateJavaScript(sendJS, completionHandler: nil)
                _ = self  // retain until send fires
            }
        }
    }
}
