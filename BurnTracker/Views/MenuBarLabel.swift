import AppKit

/// Builds the menu-bar status item's image.
///
/// With nothing pinned this is just the template glyph. With a provider pinned
/// it composites the glyph and the provider's 5-hour usage into a **single**
/// `NSImage` — `MenuBarExtra`'s label does not reliably lay out a multi-view
/// hierarchy, so drawing one image keeps the result predictable.
///
/// The result stays a template image, so macOS recolors it for light and dark
/// menu bars exactly as it does the plain glyph.
enum MenuBarLabel {
    private static let glyphSize: CGFloat = 16
    private static let gap: CGFloat = 3

    static func image(for summary: PinnedSummary?) -> NSImage {
        let glyph = NSImage(named: "MenuBarIcon")

        guard let summary else {
            return glyph ?? NSImage(systemSymbolName: "flame", accessibilityDescription: "BurnTracker")
                ?? NSImage(size: NSSize(width: glyphSize, height: glyphSize))
        }

        let text = "\(max(0, min(100, summary.percent)))%" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            // Ignored under template rendering — only the alpha channel matters.
            .foregroundColor: NSColor.black
        ]
        let textSize = text.size(withAttributes: attrs)
        let width = glyphSize + gap + ceil(textSize.width)

        let composite = NSImage(size: NSSize(width: width, height: glyphSize))
        composite.lockFocus()
        glyph?.draw(in: NSRect(x: 0, y: 0, width: glyphSize, height: glyphSize))
        text.draw(at: NSPoint(x: glyphSize + gap, y: (glyphSize - textSize.height) / 2),
                  withAttributes: attrs)
        composite.unlockFocus()
        composite.isTemplate = true
        return composite
    }
}
