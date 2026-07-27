import SwiftUI
import AppKit

@main
struct BurnTrackerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// Observed so the menu-bar label redraws whenever the pinned provider's
    /// usage changes (or the pin itself moves).
    @ObservedObject private var app = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            RootView()
                .environmentObject(app)
                .onAppear { app.onPopoverAppear() }
        } label: {
            // Template image adapts to light/dark menu bars. Carries the pinned
            // provider's 5-hour usage when one is pinned.
            Image(nsImage: MenuBarLabel.image(for: app.pinnedSummary))
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
