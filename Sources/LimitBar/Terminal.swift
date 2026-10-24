import AppKit
import CoreText
import SwiftUI

/// The panel's look: a terminal. One monospaced font, JetBrains Mono Nerd Font (bundled in the
/// app's Resources/Fonts, SIL Open Font License), on a solid background, with text in two tones;
/// colour marks each service (its own signature colour) and limits running out. Bars and charts are drawn with block characters, so everything
/// lines up on the same character grid.
enum Terminal {
    // MARK: Font

    private static let faces: [Font.Weight: String] = [
        .regular: "JetBrainsMonoNFM-Regular", .semibold: "JetBrainsMonoNFM-SemiBold", .bold: "JetBrainsMonoNFM-Bold",
    ]

    /// The app registers the bundled fonts through ATSApplicationFontsPath (see build.sh); a
    /// binary run outside the bundle (renders, tests) registers them here, or falls back to the
    /// system's monospaced font.
    private static let registered: Bool = {
        if NSFont(name: faces[.regular]!, size: 12) != nil { return true }
        let folder = Bundle.main.resourceURL?.appendingPathComponent("Fonts")
        let files = folder.flatMap { try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) } ?? []
        for file in files where file.pathExtension == "ttf" {
            CTFontManagerRegisterFontsForURL(file as CFURL, .process, nil)
        }
        return NSFont(name: faces[.regular]!, size: 12) != nil
    }()

    static func nsFont(_ size: CGFloat = 12, weight: Font.Weight = .regular) -> NSFont {
        let nsWeight: NSFont.Weight = weight == .bold ? .bold : weight == .semibold ? .semibold : .regular
        guard registered, let name = faces[weight] ?? faces[.regular], let font = NSFont(name: name, size: size) else {
            return .monospacedSystemFont(ofSize: size, weight: nsWeight)
        }
        return font
    }

    static func font(_ size: CGFloat = 12, weight: Font.Weight = .regular) -> Font {
        Font(nsFont(size, weight: weight))
    }

    /// The width of one character at the panel's size, the unit of every column.
    static let cell: CGFloat = ceil(("0" as NSString).size(withAttributes: [.font: nsFont(12)]).width * 10) / 10

    /// The panel is this many characters wide.
    static let columns = 46
    static let padding: CGFloat = 14
    static let width = CGFloat(columns) * cell + padding * 2

    static func cols(_ count: Int) -> CGFloat { CGFloat(count) * cell }

    // MARK: Colours

    private static func tone(_ name: String, dark: NSColor, light: NSColor) -> NSColor {
        NSColor(name: name) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
    }

    static let background = tone("TerminalBackground", dark: NSColor(white: 0.08, alpha: 1), light: NSColor(white: 0.98, alpha: 1))
    static let border = tone("TerminalBorder", dark: NSColor(white: 1, alpha: 0.14), light: NSColor(white: 0, alpha: 0.14))
    private static let foregroundColor = tone("TerminalForeground", dark: NSColor(white: 0.9, alpha: 1), light: NSColor(white: 0.1, alpha: 1))
    private static let dimColor = tone("TerminalDim", dark: NSColor(white: 0.55, alpha: 1), light: NSColor(white: 0.42, alpha: 1))
    private static let amberColor = tone("TerminalAmber", dark: NSColor(srgbRed: 0.85, green: 0.65, blue: 0.25, alpha: 1),
                                         light: NSColor(srgbRed: 0.68, green: 0.45, blue: 0.0, alpha: 1))
    private static let redColor = tone("TerminalRed", dark: NSColor(srgbRed: 0.93, green: 0.38, blue: 0.36, alpha: 1),
                                       light: NSColor(srgbRed: 0.78, green: 0.16, blue: 0.14, alpha: 1))

    static let foreground = Color(nsColor: foregroundColor)
    static let dim = Color(nsColor: dimColor)
    static let amber = Color(nsColor: amberColor)
    static let red = Color(nsColor: redColor)

    /// Orange-ish from 80%, red from 90%, as in the menu bar; `normal` otherwise (plain text, or
    /// a service's colour for its bars).
    static func level(_ percent: Double, normal: Color = foreground) -> Color {
        percent >= 90 ? red : percent >= 80 ? amber : normal
    }

    // MARK: Characters

    /// "━━━━━━╾───────": `percent` of `width` characters as a heavy line, to half a character,
    /// on a light one. Box-drawing characters join up, so the bar reads as one line.
    static func bar(_ percent: Double, width: Int) -> (filled: String, empty: String) {
        let halves = Int((min(max(percent, 0), 100) / 100 * Double(width * 2)).rounded())
        let filled = String(repeating: "━", count: halves / 2) + (halves % 2 == 1 ? "╾" : "")
        return (filled, String(repeating: "─", count: width - halves / 2 - halves % 2))
    }

    /// "▁▂▃▅▇": one character per value, 0 to 100.
    static func sparkline(_ values: [Double]) -> String {
        let blocks = Array("▁▂▃▄▅▆▇█")
        return String(values.map { blocks[min(Int(min(max($0, 0), 100) / 100 * 7.999), 7)] })
    }

    /// A string cut or padded to exactly `count` characters.
    static func fit(_ text: String, _ count: Int) -> String {
        text.count > count ? String(text.prefix(count - 1)) + "…" : text + String(repeating: " ", count: count - text.count)
    }
}
