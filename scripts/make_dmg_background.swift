// Draws the background of the LimitBar.dmg window and writes Resources/dmg-background.tiff.
//
//     swiftc -parse-as-library scripts/make_dmg_background.swift -o /tmp/make_dmg_background && /tmp/make_dmg_background
//
// The window is 540 × 380 pt with 128 pt icons: LimitBar centred at (140, 175) and Applications
// at (400, 175), as build.sh places them. Between them, an arrow; under them, what to do.
// The TIFF holds the 1x and 2x images, so the window is sharp on Retina screens.
import AppKit
import SwiftUI

private let size = CGSize(width: 540, height: 380)
private let iconY: CGFloat = 175

private struct Background: View {
    var body: some View {
        ZStack {
            Color(red: 0.965, green: 0.965, blue: 0.97)
            arrow.position(x: 270, y: iconY)
            Text("Drag LimitBar to Applications")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color(white: 0.42))
                .position(x: 270, y: 318)
        }
        .frame(width: size.width, height: size.height)
    }

    /// A short rounded arrow pointing right, in the gap between the two icons.
    private var arrow: some View {
        Path { path in
            path.move(to: CGPoint(x: 0, y: 16))
            path.addLine(to: CGPoint(x: 56, y: 16))
            path.move(to: CGPoint(x: 42, y: 2))
            path.addLine(to: CGPoint(x: 58, y: 16))
            path.addLine(to: CGPoint(x: 42, y: 30))
        }
        .stroke(Color(white: 0.62), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
        .frame(width: 60, height: 32)
    }
}

@main
struct MakeDMGBackground {
    @MainActor static func main() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("dmg-background")
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var pngs: [String] = []
        for (name, scale) in [("background.png", 1.0), ("background@2x.png", 2.0)] {
            let renderer = ImageRenderer(content: Background())
            renderer.scale = scale
            guard let image = renderer.cgImage,
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let url = folder.appendingPathComponent(name)
            try png.write(to: url)
            pngs.append(url.path)
        }

        let output = root.appendingPathComponent("Resources/dmg-background.tiff")
        let tiffutil = Process()
        tiffutil.executableURL = URL(fileURLWithPath: "/usr/bin/tiffutil")
        tiffutil.arguments = ["-cathidpicheck"] + pngs + ["-out", output.path]
        try tiffutil.run()
        tiffutil.waitUntilExit()
        print("Wrote \(output.path)")
        print("Preview \(pngs[1])")
    }
}
