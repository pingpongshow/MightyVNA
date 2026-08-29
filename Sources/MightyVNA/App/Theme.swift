import SwiftUI

/// Colour and typography constants for the instrument look.
enum Theme {

    /// Trace colours, chosen to stay distinguishable on both light and dark grids.
    static let tracePalette: [Color] = [
        Color(red: 1.00, green: 0.78, blue: 0.20),   // amber
        Color(red: 0.31, green: 0.82, blue: 0.99),   // cyan
        Color(red: 0.52, green: 0.94, blue: 0.55),   // green
        Color(red: 1.00, green: 0.43, blue: 0.51),   // rose
        Color(red: 0.76, green: 0.62, blue: 1.00),   // violet
        Color(red: 0.99, green: 0.60, blue: 0.32),   // orange
        Color(red: 0.44, green: 0.98, blue: 0.86),   // teal
        Color(red: 0.96, green: 0.87, blue: 0.60)    // sand
    ]

    static let markerPalette: [Color] = [
        Color(red: 1.00, green: 0.95, blue: 0.55),
        Color(red: 0.60, green: 0.92, blue: 1.00),
        Color(red: 0.72, green: 1.00, blue: 0.72),
        Color(red: 1.00, green: 0.68, blue: 0.76),
        Color(red: 0.86, green: 0.78, blue: 1.00),
        Color(red: 1.00, green: 0.80, blue: 0.60),
        Color(red: 0.70, green: 1.00, blue: 0.94),
        Color(red: 1.00, green: 1.00, blue: 0.85)
    ]

    static func traceColor(_ index: Int) -> Color {
        tracePalette[((index % tracePalette.count) + tracePalette.count) % tracePalette.count]
    }

    static func markerColor(_ index: Int) -> Color {
        markerPalette[((index % markerPalette.count) + markerPalette.count) % markerPalette.count]
    }

    // Chart chrome
    static let plotBackground = Color(nsColor: .init(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedRed: 0.055, green: 0.062, blue: 0.078, alpha: 1)
            : NSColor(calibratedRed: 0.99, green: 0.99, blue: 0.995, alpha: 1)
    })

    static let gridMajor = Color.primary.opacity(0.20)
    static let gridMinor = Color.primary.opacity(0.08)
    static let gridBorder = Color.primary.opacity(0.35)
    static let axisText = Color.secondary

    static let panelBackground = Color(nsColor: .controlBackgroundColor)
    static let accent = Color(red: 0.32, green: 0.72, blue: 1.0)

    static let statusGood = Color(red: 0.38, green: 0.86, blue: 0.50)
    static let statusWarn = Color(red: 1.00, green: 0.74, blue: 0.25)
    static let statusBad = Color(red: 1.00, green: 0.42, blue: 0.42)

    static let monospaceSmall = Font.system(size: 10, weight: .regular, design: .monospaced)
    static let monospace = Font.system(size: 11, weight: .regular, design: .monospaced)
    static let readout = Font.system(size: 12, weight: .medium, design: .monospaced)
}

extension Color {
    /// Blend towards another colour, used for hover and selection states.
    func mixed(with other: Color, amount: Double) -> Color {
        let a = NSColor(self).usingColorSpace(.sRGB) ?? .white
        let b = NSColor(other).usingColorSpace(.sRGB) ?? .black
        let t = min(max(amount, 0), 1)
        return Color(nsColor: NSColor(srgbRed: a.redComponent + (b.redComponent - a.redComponent) * t,
                                      green: a.greenComponent + (b.greenComponent - a.greenComponent) * t,
                                      blue: a.blueComponent + (b.blueComponent - a.blueComponent) * t,
                                      alpha: 1))
    }
}
