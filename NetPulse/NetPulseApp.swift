import SwiftUI
import AppKit

@main
struct SwiftMeterApp: App {
    @StateObject private var monitor = NetworkMonitor()

    var body: some Scene {
        MenuBarExtra {
            PopoverContentView(monitor: monitor)
                .frame(width: 340, height: 590)
        } label: {
            Image(nsImage: StatusBarIcon.make(
                up:   monitor.uploadSpeedString,
                down: monitor.downloadSpeedString
            ))
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Status Bar Icon
// Two-line "↑ upload / ↓ download" NSImage with coloured arrows
// matching the app palette: ↑ = blue, ↓ = green.
// Speed numbers use NSColor.labelColor so they adapt to light/dark mode.

enum StatusBarIcon {
    // Mirror the Color extensions so AppKit drawing uses the same tones.
    private static let arrowUp   = NSColor(red: 0.25, green: 0.55, blue: 1.00, alpha: 1.0)
    private static let arrowDown = NSColor(red: 0.20, green: 0.78, blue: 0.35, alpha: 1.0)

    static func make(up: String, down: String) -> NSImage {
        let font = NSFont.monospacedSystemFont(ofSize: 8.5, weight: .medium)

        // Metric attrs (color irrelevant for size measurement)
        let metricAttrs: [NSAttributedString.Key: Any] = [.font: font]

        // Fixed image width — based on the widest realistic string so the icon
        // never shifts as speed values change (e.g., "0 B/s" vs "999.9 MBps").
        let refW  = ("↑ 999.9 MBps" as NSString).size(withAttributes: metricAttrs).width
        let imgW  = ceil(refW) + 6      // 3 pt left + 3 pt right margin
        let imgH: CGFloat = 22

        // Precise baselines via actual font metrics.
        // In non-flipped AppKit coords: y = 0 at bottom, y = 22 at top.
        // draw(at:) places the TEXT BASELINE at the given y; ascenders go up.
        let asc   = font.ascender           // ≈  +7 pt
        let desc  = abs(font.descender)     // ≈   2 pt
        let lineH = asc + desc              // ≈   9 pt
        let pad   = max((imgH - 2 * lineH) / 2, 1)
        let base2 = pad + desc              // ↓ download baseline
        let base1 = base2 + lineH           // ↑ upload   baseline

        // Pre-compute arrow width (same for ↑ and ↓ in monospaced font)
        let arrowW = ("↑ " as NSString).size(withAttributes: metricAttrs).width

        let image = NSImage(size: NSSize(width: imgW, height: imgH), flipped: false) { _ in
            // Use performAsCurrentDrawingAppearance (macOS 12+) so that
            // NSColor.labelColor resolves to the correct light/dark tone.
            let doDrawing: () -> Void = {
                let textColor = NSColor.labelColor
                let upAttrs:   [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: arrowUp]
                let downAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: arrowDown]
                let numAttrs:  [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]

                // Row 1 (top):    ↑ in blue  + upload speed
                ("↑ " as NSString).draw(at: NSPoint(x: 3, y: base1), withAttributes: upAttrs)
                (up   as NSString).draw(at: NSPoint(x: 3 + arrowW, y: base1), withAttributes: numAttrs)

                // Row 2 (bottom): ↓ in green + download speed
                ("↓ " as NSString).draw(at: NSPoint(x: 3, y: base2), withAttributes: downAttrs)
                (down as NSString).draw(at: NSPoint(x: 3 + arrowW, y: base2), withAttributes: numAttrs)
            }

            if let appearance = NSApp?.effectiveAppearance {
                appearance.performAsCurrentDrawingAppearance(doDrawing)
            } else {
                doDrawing()
            }
            return true
        }
        // isTemplate = false: preserves the blue/green arrow colours.
        image.isTemplate = false
        return image
    }
}

// MARK: - Color Extensions

extension Color {
    static let netDown = Color(red: 0.20, green: 0.78, blue: 0.35)
    static let netUp   = Color(red: 0.25, green: 0.55, blue: 1.00)
    static let cardBG  = Color.primary.opacity(0.05)
}
