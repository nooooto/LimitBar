// Draws the LimitBar app icon and writes Resources/AppIcon.icns.
//
//     swiftc -parse-as-library scripts/make_icon.swift -o /tmp/make_icon && /tmp/make_icon
//
// Follows the macOS icon grid: a 824 pt continuous-corner squircle centred on a 1024 pt canvas.
// Shapes are drawn by hand (SF Symbols may not be used in app icons). Glass is imitated with
// translucent white fills and rims, since materials don't render offscreen.
import AppKit
import SwiftUI

private let canvas: CGFloat = 1024
private let squircleSize: CGFloat = 824
private let bodyRadius: CGFloat = 185

private struct Icon: View {
    var body: some View {
        ZStack {
            squircle
            menuBarItem.offset(y: -228)
            panel.offset(y: 78)
        }
        .frame(width: canvas, height: canvas)
    }

    // MARK: Background

    /// Warm orange into violet into blue: Claude's and Codex's colours meeting.
    private var squircle: some View {
        let shape = RoundedRectangle(cornerRadius: bodyRadius, style: .continuous)
        return shape
            .fill(LinearGradient(colors: [Color(red: 1.00, green: 0.56, blue: 0.36),
                                          Color(red: 0.80, green: 0.32, blue: 0.62),
                                          Color(red: 0.27, green: 0.26, blue: 0.86)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(
                shape.fill(RadialGradient(colors: [.white.opacity(0.30), .clear],
                                          center: UnitPoint(x: 0.28, y: 0.04), startRadius: 0, endRadius: 640))
            )
            // Glass rim: bright along the top edge, fading out towards the bottom.
            .overlay(
                shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.6), .white.opacity(0.06)],
                                                  startPoint: .top, endPoint: .bottom), lineWidth: 5)
            )
            .frame(width: squircleSize, height: squircleSize)
            .shadow(color: .black.opacity(0.25), radius: 14, y: 8)
    }

    // MARK: Glass

    /// Frosted glass slab: translucent body, light rim, soft shadow underneath.
    private func glass<S: InsettableShape>(_ shape: S, opacity: Double = 0.2) -> some View {
        shape
            .fill(LinearGradient(colors: [.white.opacity(opacity + 0.1), .white.opacity(opacity - 0.06)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay(
                shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.85), .white.opacity(0.15)],
                                                  startPoint: .top, endPoint: .bottom), lineWidth: 4)
            )
            .shadow(color: Color(red: 0.12, green: 0.05, blue: 0.35).opacity(0.35), radius: 26, y: 16)
    }

    // MARK: Menu bar item

    /// The status item the panel hangs from: two little glyphs and their numbers.
    private var menuBarItem: some View {
        ZStack {
            glass(Capsule(), opacity: 0.24)
            HStack(spacing: 22) {
                ForEach(0..<2, id: \.self) { _ in
                    HStack(spacing: 12) {
                        Circle().fill(.white).frame(width: 30, height: 30)
                        Capsule().fill(.white.opacity(0.9)).frame(width: 34, height: 18)
                    }
                }
            }
        }
        .frame(width: 280, height: 78)
    }

    // MARK: Panel

    private var panel: some View {
        ZStack {
            glass(RoundedRectangle(cornerRadius: 70, style: .continuous), opacity: 0.26)
            VStack(alignment: .leading, spacing: 58) {
                usageRow(fill: 0.72, colors: [Color(red: 1.00, green: 0.72, blue: 0.42),
                                              Color(red: 1.00, green: 0.45, blue: 0.30)])
                usageRow(fill: 0.38, colors: [Color(red: 0.55, green: 0.85, blue: 1.00),
                                              Color(red: 0.35, green: 0.50, blue: 1.00)])
            }
            .padding(.horizontal, 62)
        }
        .frame(width: 590, height: 380)
    }

    /// A label stub over a usage bar, like a row in the real panel.
    private func usageRow(fill: CGFloat, colors: [Color]) -> some View {
        let width: CGFloat = 466
        return VStack(alignment: .leading, spacing: 26) {
            HStack(spacing: 16) {
                Circle().fill(colors[1]).frame(width: 34, height: 34)
                    .overlay(Circle().strokeBorder(.white.opacity(0.7), lineWidth: 3))
                Capsule().fill(.white.opacity(0.85)).frame(width: 150, height: 22)
            }
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.28))
                Capsule()
                    .fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                    .frame(width: width * fill)
                    .shadow(color: colors[1].opacity(0.6), radius: 10)
            }
            .frame(width: width, height: 40)
        }
    }
}

@main
enum MakeIcon {
    @MainActor
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
        let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
        try? FileManager.default.removeItem(at: iconset)
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

        // Each size is rendered from the vector drawing, so small sizes stay sharp.
        let sizes: [(String, CGFloat)] = [
            ("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64),
            ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512),
            ("512x512", 512), ("512x512@2x", 1024),
        ]
        for (name, pixels) in sizes {
            let renderer = ImageRenderer(content: Icon())
            renderer.scale = pixels / canvas
            guard let image = renderer.cgImage,
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try png.write(to: iconset.appendingPathComponent("icon_\(name).png"))
        }

        let resources = root.appendingPathComponent("Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let preview = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-preview.png")
        try? FileManager.default.removeItem(at: preview)
        try FileManager.default.copyItem(at: iconset.appendingPathComponent("icon_512x512@2x.png"), to: preview)

        let iconutil = Process()
        iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        iconutil.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon.icns").path]
        try iconutil.run()
        iconutil.waitUntilExit()
        print("Wrote \(resources.appendingPathComponent("AppIcon.icns").path)")
        print("Preview \(preview.path)")
    }
}
