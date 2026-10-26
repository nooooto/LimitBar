import AppKit

enum Logo {
    case claude, codex, opencode
}

enum Icons {
    static let claudeOrange = NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1)
    /// The violet of the Codex cloud icon, between its deep (#636FF7) and light (#A09EF9) ends.
    static let codexViolet = NSColor(srgbRed: 0x6B / 255, green: 0x66 / 255, blue: 0xF7 / 255, alpha: 1)
    /// OpenCode's icon is black and white, so it gets a colour of its own: pink (#EC4899).
    static let openCodePink = NSColor(srgbRed: 0xEC / 255, green: 0x48 / 255, blue: 0x99 / 255, alpha: 1)

    // MARK: Official artwork, read from the installed apps (never copied into LimitBar)

    private static func appURL(_ bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    private static let claudeApp = appURL("com.anthropic.claudefordesktop")
    private static let codexApp = appURL("com.openai.codex")
    private static let openCodeApp = appURL("ai.opencode.desktop")

    /// Claude's own menu bar glyph (a template image with @2x/@3x variants).
    private static let claudeTrayGlyph: Trimmed? = claudeApp
        .flatMap { Bundle(url: $0) }
        .flatMap { $0.image(forResource: "TrayIconTemplate") }
        .map(Trimmed.init)

    /// The cloud of the official Codex icon without its white tile, for the menu bar while Codex
    /// works. Pixels keep their colour and get an alpha from their saturation, which clears the
    /// grey tile; the ">_" inside the cloud is just as grey, so it's then filled with solid white.
    /// Nil when the Codex app isn't installed.
    static let codexCloudArtwork: NSImage? = {
        guard let file = codexApp?.appendingPathComponent("Contents/Resources/icon-codex-light.png"),
              let source = NSImage(contentsOf: file) else { return nil }
        let side = 512
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return nil }
        var rect = NSRect(x: 0, y: 0, width: side, height: side)
        guard let cg = source.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        ctx.draw(cg, in: rect)

        let p = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        let count = side * side
        // Pass 1: how much of each pixel belongs to the cloud, from its saturation:
        // none below 12%, all above 30%, a soft edge in between.
        var coverage = [Double](repeating: 0, count: count)
        var colour = [(r: Double, g: Double, b: Double)](repeating: (0, 0, 0), count: count)
        for i in 0..<count {
            let alpha = Double(p[i * 4 + 3]) / 255
            guard alpha > 0 else { continue }
            let r = Double(p[i * 4]) / 255 / alpha, g = Double(p[i * 4 + 1]) / 255 / alpha, b = Double(p[i * 4 + 2]) / 255 / alpha
            let high = max(r, g, b), low = min(r, g, b)
            let saturation = high > 0 ? (high - low) / high : 0
            coverage[i] = min(max((saturation - 0.12) / 0.18, 0), 1) * alpha
            colour[i] = (r, g, b)
        }

        // Pass 2: what lies outside the cloud is the clear area reachable from the image's border.
        // Everything else that isn't fully cloud (the ">_" and the pale highlight on top of the
        // cloud) is laid over white, as it sits over the white tile in the icon.
        var outside = [Bool](repeating: false, count: count)
        var queue: [Int] = []
        for x in 0..<side { queue.append(x); queue.append((side - 1) * side + x) }
        for y in 0..<side { queue.append(y * side); queue.append(y * side + side - 1) }
        while let i = queue.popLast() {
            guard !outside[i], coverage[i] < 0.05 else { continue }
            outside[i] = true
            let x = i % side, y = i / side
            if x > 0 { queue.append(i - 1) }
            if x < side - 1 { queue.append(i + 1) }
            if y > 0 { queue.append(i - side) }
            if y < side - 1 { queue.append(i + side) }
        }

        // Pass 3: a thin band along the outer edge keeps its own colour and softness; laying it
        // over white too would leave a pale rim around the cloud on a dark menu bar.
        let edgeBand = 3
        var distance = [Int](repeating: Int.max, count: count)
        var frontier = (0..<count).filter { outside[$0] }
        for i in frontier { distance[i] = 0 }
        for step in 1...edgeBand {
            var next: [Int] = []
            for i in frontier {
                let x = i % side, y = i / side
                for j in [x > 0 ? i - 1 : -1, x < side - 1 ? i + 1 : -1, y > 0 ? i - side : -1, y < side - 1 ? i + side : -1]
                where j >= 0 && distance[j] == Int.max {
                    distance[j] = step
                    next.append(j)
                }
            }
            frontier = next
        }

        var minX = side, minY = side, maxX = -1, maxY = -1
        for i in 0..<count {
            var a = coverage[i]
            var (r, g, b) = colour[i]
            if !outside[i], a < 1, distance[i] > edgeBand {
                // Inside the cloud: lay the pixel over white, which fills the ">_".
                r = r * a + (1 - a); g = g * a + (1 - a); b = b * a + (1 - a)
                a = 1
            }
            p[i * 4] = UInt8(r * a * 255); p[i * 4 + 1] = UInt8(g * a * 255); p[i * 4 + 2] = UInt8(b * a * 255)
            p[i * 4 + 3] = UInt8(a * 255)
            if a > 0.5 {
                let x = i % side, y = i / side
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        // Bitmap rows run top to bottom, as CGImage cropping expects.
        guard maxX >= minX, let full = ctx.makeImage(),
              let cloud = full.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))
        else { return nil }
        return NSImage(cgImage: cloud, size: NSSize(width: cloud.width, height: cloud.height))
    }()

    /// App icons shown next to each provider in the panel.
    /// The source images carry different transparent margins, so each is trimmed to what's visible.
    static func panelLogo(_ logo: Logo) -> NSImage {
        let size = NSSize(width: 36, height: 36)
        switch logo {
        case .claude:
            if let app = claudeApp {
                let icon = Trimmed(NSWorkspace.shared.icon(forFile: app.path))
                return NSImage(size: size, flipped: false) { rect in
                    icon.draw(in: rect)
                    return true
                }
            }
            return image(.claude, size: size.width, color: claudeOrange)
        case .codex:
            // Always the light tile: the dark variant's near-black tile vanishes against the dark
            // glass, leaving just the cloud, which reads as a smaller icon than Claude's tile.
            let file = codexApp?.appendingPathComponent("Contents/Resources/icon-codex-light.png")
            if let light = file.flatMap({ NSImage(contentsOf: $0) }) {
                let icon = Trimmed(light)
                return NSImage(size: size, flipped: false) { rect in
                    icon.draw(in: rect)
                    return true
                }
            }
            return image(.codex, size: size.width, color: .labelColor)
        case .opencode:
            if let app = openCodeApp {
                let icon = Trimmed(NSWorkspace.shared.icon(forFile: app.path))
                return NSImage(size: size, flipped: false) { rect in
                    icon.draw(in: rect)
                    return true
                }
            }
            return image(.opencode, size: size.width, color: openCodePink)
        }
    }

    /// An image cropped to its visible shape, so different artwork can be drawn at the same size.
    /// The source is rasterized once at a fixed size: icon files hold several representations
    /// with different margins, and drawing small would otherwise pick a different one.
    private struct Trimmed {
        private static let side = 256
        /// Alpha cutoff that skips soft drop shadows and keeps the actual icon shape.
        private static let alphaThreshold: UInt8 = 128

        let image: NSImage

        init(_ source: NSImage) {
            image = Self.crop(source) ?? source
            image.isTemplate = source.isTemplate
        }

        func draw(in rect: NSRect) {
            let size = image.size
            guard size.width > 0, size.height > 0 else { return }
            let scale = min(rect.width / size.width, rect.height / size.height)
            let fitted = NSSize(width: size.width * scale, height: size.height * scale)
            let target = NSRect(x: rect.midX - fitted.width / 2, y: rect.midY - fitted.height / 2,
                                width: fitted.width, height: fitted.height)
            image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1)
        }

        private static func crop(_ source: NSImage) -> NSImage? {
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: side * 4, bitsPerPixel: 32
            ) else { return nil }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            source.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
            NSGraphicsContext.restoreGraphicsState()
            guard let pixels = rep.bitmapData, let raster = rep.cgImage else { return nil }

            // Rows run top to bottom, which is also what CGImage cropping expects.
            var minX = side, minY = side, maxX = -1, maxY = -1
            for row in 0..<side {
                for col in 0..<side where pixels[(row * side + col) * 4 + 3] >= alphaThreshold {
                    minX = min(minX, col); maxX = max(maxX, col)
                    minY = min(minY, row); maxY = max(maxY, row)
                }
            }
            guard maxX >= minX, maxY >= minY,
                  let cropped = raster.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))
            else { return nil }
            return NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
        }
    }

    // MARK: Drawn glyphs (menu bar, and fallback when the apps aren't installed)

    static func image(_ logo: Logo, size: CGFloat, color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            draw(logo, in: rect, color: color)
            return true
        }
    }

    static func draw(_ logo: Logo, in rect: NSRect, color: NSColor) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = min(rect.width, rect.height) / 2
        ctx.saveGState()
        ctx.translateBy(x: rect.midX, y: rect.midY)
        ctx.setFillColor(color.cgColor)
        ctx.setStrokeColor(color.cgColor)

        switch logo {
        case .claude:
            // Starburst: 12 rounded rays of alternating length.
            let width = r * 0.2
            for i in 0..<12 {
                ctx.saveGState()
                ctx.rotate(by: CGFloat(i) * .pi / 6 + .pi / 2)
                let length = (i % 2 == 0 ? 1.0 : 0.8) * r
                let ray = CGRect(x: r * 0.08, y: -width / 2, width: length - r * 0.08, height: width)
                ctx.addPath(CGPath(roundedRect: ray, cornerWidth: width / 2, cornerHeight: width / 2, transform: nil))
                ctx.fillPath()
                ctx.restoreGState()
            }
        case .codex:
            // The Codex cloud (a scalloped blob) with the ">_" prompt cut out of it.
            ctx.addEllipse(in: CGRect(x: -r * 0.66, y: -r * 0.66, width: r * 1.32, height: r * 1.32))
            for i in 0..<8 {
                let angle = CGFloat(i) * .pi / 4
                let center = CGPoint(x: cos(angle) * r * 0.6, y: sin(angle) * r * 0.6)
                ctx.addEllipse(in: CGRect(x: center.x - r * 0.4, y: center.y - r * 0.4, width: r * 0.8, height: r * 0.8))
            }
            ctx.fillPath()

            ctx.setBlendMode(.clear)
            ctx.setLineWidth(r * 0.17)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.move(to: CGPoint(x: -r * 0.42, y: r * 0.26))
            ctx.addLine(to: CGPoint(x: -r * 0.14, y: 0))
            ctx.addLine(to: CGPoint(x: -r * 0.42, y: -r * 0.26))
            ctx.move(to: CGPoint(x: r * 0.04, y: -r * 0.28))
            ctx.addLine(to: CGPoint(x: r * 0.42, y: -r * 0.28))
            ctx.strokePath()
        case .opencode:
            // OpenCode's mark, from the app's own SVG (512 units, the frame 256 × 320): a tall
            // frame with a grey block filling the lower part of its opening.
            ctx.addRect(CGRect(x: -r * 0.8, y: -r, width: r * 1.6, height: r * 2))
            ctx.addRect(CGRect(x: -r * 0.4, y: -r * 0.6, width: r * 0.8, height: r * 1.2))
            ctx.fillPath(using: .evenOdd)
            ctx.setFillColor(color.withAlphaComponent(color.alphaComponent * 0.4).cgColor)
            ctx.fill(CGRect(x: -r * 0.4, y: -r * 0.6, width: r * 0.8, height: r * 0.8))
        }
        ctx.restoreGState()
    }

    /// Full-colour artwork fitted into the glyph's square.
    private static func drawArtwork(_ artwork: NSImage, in rect: NSRect, fraction: CGFloat) {
        let scale = min(rect.width / artwork.size.width, rect.height / artwork.size.height)
        let size = NSSize(width: artwork.size.width * scale, height: artwork.size.height * scale)
        artwork.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                                width: size.width, height: size.height),
                     from: .zero, operation: .sourceOver, fraction: fraction)
    }

    /// Draws `body` as one layer at `alpha`, so overlapping strokes don't add up.
    private static func drawFaded(alpha: CGFloat, _ body: () -> Void) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return body() }
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        body()
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    private static func drawPlainGlyph(_ logo: Logo, in rect: NSRect, color: NSColor) {
        if logo == .claude, let glyph = claudeTrayGlyph {
            glyph.draw(in: rect)
            // The tray glyph is black template art: recolour just what was drawn in its rect.
            NSGraphicsContext.saveGraphicsState()
            color.set()
            rect.fill(using: .sourceAtop)
            NSGraphicsContext.restoreGraphicsState()
        } else {
            draw(logo, in: rect, color: color)
        }
    }

    /// One service in the menu bar label: `alert` colours the number when its limit is running
    /// out; `glyph` or `glyphArtwork` mark the service as working. Only work colours the glyph,
    /// so a coloured glyph always means the agent is working (in red when its limit is nearly gone,
    /// see UsageStore.statusLabel), never just that its limit is at 80%.
    struct StatusPart {
        let logo: Logo
        let text: String
        let alert: NSColor?
        var glyph: NSColor? = nil
        /// Full-colour artwork drawn in place of the glyph (the real Codex cloud).
        var glyphArtwork: NSImage? = nil
        /// How far the glyph has grown, 0 at rest to 1 while working, for the in-between frames
        /// of the animation. Nil: fully grown when coloured, at rest otherwise.
        var growth: CGFloat? = nil
        /// How much of the working colour (or artwork) shows, 0 to 1, so it fades in and out
        /// with the growth instead of switching. Nil: all of it.
        var tint: CGFloat? = nil

        var currentGrowth: CGFloat { growth ?? (glyph != nil || glyphArtwork != nil ? 1 : 0) }
    }

    /// Glyph size at rest and while its service is working, large enough for the Codex cloud to
    /// read. The image keeps one height for both, so the label doesn't jump when it grows.
    static let restingGlyph: CGFloat = 14
    static let workingGlyph: CGFloat = 19

    /// The menu bar label, "[claude] 6%  [codex] 0%", as two layers of the same size drawn on top
    /// of each other:
    /// - `base`, a template image with everything in the menu bar's own colour, which macOS tints
    ///   like the system items;
    /// - `colour`, a plain image with only what carries colour (a working agent's glyph, numbers
    ///   in alert), or nil when nothing does.
    /// The base never stops being a template. Switching the whole label between template and plain
    /// changed how its other parts were drawn, which showed as a flash at the end of an animation.
    struct StatusLabel {
        let base: NSImage
        let colour: NSImage?
    }

    /// `height` is the status item button's: an image as tall as the button needs no centring,
    /// which the button and the colour layer over it rounded differently, half a point apart.
    static func statusLabel(_ parts: [StatusPart], workingGlyph: CGFloat = workingGlyph, height: CGFloat? = nil) -> StatusLabel {
        // Digits all as wide, so the label keeps its width as the numbers change.
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        let gap: CGFloat = 3, spacing: CGFloat = 8
        let height = max(height ?? 0, 18, workingGlyph + 2)
        let icons = parts.map { restingGlyph + (workingGlyph - restingGlyph) * $0.currentGrowth }
        let widths = parts.map { ceil(NSAttributedString(string: $0.text, attributes: [.font: font]).size().width) }
        let width = zip(icons, widths).reduce(0) { $0 + $1.0 + gap + $1.1 } + spacing * CGFloat(max(parts.count - 1, 0))
        let size = NSSize(width: max(width, 1), height: height)
        // The digits (as tall as the capitals) centred on the glyphs, not the font's line box,
        // whose room for descenders pushed them up; on the pixel grid, so they stay sharp.
        let baseline = ((height - font.capHeight) / 2 * 2).rounded() / 2

        /// How much of a part's working colour shows (0 when it isn't working).
        func workingTint(_ part: StatusPart) -> CGFloat {
            part.glyph == nil && part.glyphArtwork == nil ? 0 : min(max(part.tint ?? 1, 0), 1)
        }

        func layer(colour: Bool) -> NSImage {
            NSImage(size: size, flipped: false) { _ in
                var x: CGFloat = 0
                for ((part, textWidth), icon) in zip(zip(parts, widths), icons) {
                    let rect = NSRect(x: x, y: (height - icon) / 2, width: icon, height: icon)
                    let tint = workingTint(part)
                    // The plain glyph, in the base layer, fades out as the working one fades in.
                    if colour {
                        if tint > 0 {
                            if let artwork = part.glyphArtwork {
                                drawArtwork(artwork, in: rect, fraction: tint)
                            } else if let glyph = part.glyph {
                                drawFaded(alpha: tint) { drawPlainGlyph(part.logo, in: rect, color: glyph) }
                            }
                        }
                    } else if tint < 1 {
                        drawFaded(alpha: 1 - tint) { drawPlainGlyph(part.logo, in: rect, color: .black) }
                    }
                    x += icon + gap
                    if (part.alert != nil) == colour, let context = NSGraphicsContext.current?.cgContext {
                        let color = part.alert ?? NSColor.black
                        let text = NSAttributedString(string: part.text, attributes: [
                            .font: font, .foregroundColor: color,
                            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor,
                        ])
                        context.textMatrix = .identity
                        context.textPosition = CGPoint(x: x, y: baseline)
                        CTLineDraw(CTLineCreateWithAttributedString(text), context)
                    }
                    x += textWidth + spacing
                }
                return true
            }
        }

        let base = layer(colour: false)
        base.isTemplate = true
        let hasColour = parts.contains { $0.alert != nil || workingTint($0) > 0 }
        return StatusLabel(base: base, colour: hasColour ? layer(colour: true) : nil)
    }
}
