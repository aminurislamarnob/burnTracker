import SwiftUI
import AppKit

@main
struct BurnTrackerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            RootView()
                .environmentObject(AppState.shared)
                .onAppear { AppState.shared.onPopoverAppear() }
        } label: {
            // Template glyph adapts to light/dark menu bars.
            if let img = NSImage(named: "MenuBarIcon") {
                Image(nsImage: img)
            } else {
                Image(systemName: "flame")
            }
        }
        .menuBarExtraStyle(.window)
    }
}

/// Runs the app as a menu-bar accessory (no Dock icon) and kicks off the
/// initial load so background sync/notifications work before the first open.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        MainActor.assumeIsolated {
            AppState.shared.onLaunch()
        }
    }
}
