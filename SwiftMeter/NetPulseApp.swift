import SwiftUI
import AppKit

@main
struct SwiftMeterApp: App {
    @StateObject private var monitor = NetworkMonitor()

    init() {
        // Touch the singleton so the legacy-LaunchAgent migration runs and
        // SMAppService gets the current toggle on cold start.
        _ = AppSettings.shared
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverContentView(monitor: monitor)
                .frame(width: 340, height: 680)
        } label: {
            // Use a dedicated View so @Environment(\.colorScheme) reads
            // the status-bar button's own appearance (including desktop tinting),
            // not the app window's appearance.
            StatusBarLabel(up: monitor.uploadSpeedString,
                           down: monitor.downloadSpeedString)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }
}

// MARK: - Status Bar Label View

private struct StatusBarLabel: View {
    let up: String
    let down: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image(nsImage: StatusBarIcon.make(
            up: up,
            down: down,
            isDark: colorScheme == .dark
        ))
    }
}

// MARK: - Status Bar Icon (NSImage)
//
// • Flipped drawing context (y=0 at top, y increases downward):
//   draw(at:) places the TOP-LEFT of the text at the given point —
//   same as standard screen coordinates, no baseline-confusion.
// • Width is sized to the wider of the two actual speed strings
//   (+ a minimum so the icon stays stable at "0 B/s").
// • Text colour is passed in as white/black based on the menu-bar
//   colour scheme so it stays readable on any wallpaper.

enum StatusBarIcon {
    private static let arrowUp   = NSColor(red: 0.25, green: 0.55, blue: 1.00, alpha: 1.0)
    private static let arrowDown = NSColor(red: 0.20, green: 0.78, blue: 0.35, alpha: 1.0)

    // Cache: SwiftUI re-evaluates the menu-bar label every time *any*
    // @Published field on NetworkMonitor changes (DNS, IP, latency …),
    // not just the speed strings. Drawing two attributed strings into
    // an NSImage 30× a minute when the input is identical is pure
    // wasted CPU. Cache by the fields that actually affect the bitmap.
    private static var cacheKey: String = ""
    private static var cachedImage: NSImage?

    static func make(up: String, down: String, isDark: Bool) -> NSImage {
        let key = "\(up)|\(down)|\(isDark)"
        if key == cacheKey, let img = cachedImage { return img }
        let font      = NSFont.monospacedSystemFont(ofSize: 8.5, weight: .medium)
        let sizeAttrs: [NSAttributedString.Key: Any] = [.font: font]

        let arrowW = ("↑ " as NSString).size(withAttributes: sizeAttrs).width

        // Size the image to the wider of the two current strings.
        // Minimum avoids collapse when showing "0 B/s".
        let upW   = arrowW + (up   as NSString).size(withAttributes: sizeAttrs).width
        let downW = arrowW + (down as NSString).size(withAttributes: sizeAttrs).width
        // "999.9 KBps" has the same char count as "999.9 MBps" / "99.99 GBps"
        // so the icon width stays stable across all speed ranges.
        let minW  = ("↑ 999.9 KBps" as NSString).size(withAttributes: sizeAttrs).width
        let imgW  = ceil(max(upW, downW, minW)) + 8   // 4 pt left + 4 pt right

        let imgH: CGFloat = 22

        // Row height = ascender + |descender|; centre two rows in 22 pt.
        let asc   = font.ascender
        let lineH = asc + abs(font.descender)
        let pad   = max((imgH - 2 * lineH) / 2, 1)

        // In a FLIPPED context draw(at:) places the text TOP at the given y.
        // Row 1 top = pad from the image top; Row 2 top = pad + lineH.
        let y1 = pad          // upload row
        let y2 = pad + lineH  // download row

        let textColor = isDark ? NSColor.white : NSColor.black

        let image = NSImage(size: NSSize(width: imgW, height: imgH), flipped: true) { _ in
            let upAttrs:   [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: arrowUp]
            let downAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: arrowDown]
            let numAttrs:  [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]

            // Row 1: ↑ (blue) + upload speed
            ("↑ " as NSString).draw(at: NSPoint(x: 4, y: y1), withAttributes: upAttrs)
            (up   as NSString).draw(at: NSPoint(x: 4 + arrowW, y: y1), withAttributes: numAttrs)

            // Row 2: ↓ (green) + download speed
            ("↓ " as NSString).draw(at: NSPoint(x: 4, y: y2), withAttributes: downAttrs)
            (down as NSString).draw(at: NSPoint(x: 4 + arrowW, y: y2), withAttributes: numAttrs)

            return true
        }
        image.isTemplate = false
        cacheKey    = key
        cachedImage = image
        return image
    }
}

// MARK: - Color Extensions

extension Color {
    static let netDown = Color(red: 0.20, green: 0.78, blue: 0.35)
    static let netUp   = Color(red: 0.25, green: 0.55, blue: 1.00)
    static let cardBG  = Color.primary.opacity(0.05)
}
