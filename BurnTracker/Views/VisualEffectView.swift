import SwiftUI
import AppKit

/// A SwiftUI wrapper around `NSVisualEffectView`, giving native macOS vibrancy
/// ("glass") — the same effect that backs system menus and popovers.
///
/// - `.behindWindow` blends with whatever is behind the popover (the desktop /
///   other apps) for true translucency; used for the window background.
/// - `.withinWindow` frosts the app's own content behind it; used for the
///   layered cards so they read as frosted panels over the window glass.
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blending: NSVisualEffectView.BlendingMode
    var emphasized: Bool = false

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .active          // stay vibrant even when the app isn't key
        view.isEmphasized = emphasized
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        // Only assign when something actually changed. Re-setting `material`
        // rebuilds the backing effect, so writing it unconditionally makes the
        // vibrancy flicker on views that re-render every frame (e.g. a card
        // being dragged).
        if view.material != material { view.material = material }
        if view.blendingMode != blending { view.blendingMode = blending }
        if view.isEmphasized != emphasized { view.isEmphasized = emphasized }
    }
}
