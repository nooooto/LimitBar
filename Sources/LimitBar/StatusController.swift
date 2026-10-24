import AppKit
import Combine
import QuartzCore
import SwiftUI

/// Menu bar item plus a borderless panel. We draw the panel ourselves (instead of using
/// MenuBarExtra's window) so it gets proper Liquid Glass with rounded, concentric corners.
@MainActor
final class StatusController: NSObject {
    private static let cornerRadius: CGFloat = 18
    private static let gapBelowMenuBar: CGFloat = 6

    private let store = UsageStore()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let panel = GlassPanel()
    private let hosting: NSHostingView<PanelView>
    private var storeObserver: AnyCancellable?
    /// Each service's glyph growth, 0 at rest to 1 while working (a spring may briefly pass them).
    private var growth: [ProviderID: CGFloat] = [:]
    private var motions: [ProviderID: GlyphMotion] = [:]
    private var displayLink: CADisplayLink?
    /// The label's coloured parts, laid over the button's template image (see Icons.StatusLabel).
    private let colourLayer = PassthroughImageView()
    /// Redraws the label while it counts down to a reset (see UsageStore.blockedUntil).
    private var countdownTimer: Timer?
    private var outsideClickMonitor: Any?
    private var lastClosed = Date.distantPast

    override init() {
        hosting = NSHostingView(rootView: PanelView(store: store))
        super.init()

        if let button = statusItem.button {
            // Same bounds and centring as the button's own image, so the two layers line up.
            colourLayer.frame = button.bounds
            colourLayer.autoresizingMask = [.width, .height]
            colourLayer.imageScaling = .scaleNone
            colourLayer.imageAlignment = .alignCenter
            button.addSubview(colourLayer)
        }
        updateStatusImage()
        if #available(macOS 27.0, *) {
            // The menu bar system opens/closes us and draws the item's selected state itself.
            statusItem.expandedInterfaceDelegate = self
        } else {
            statusItem.button?.target = self
            statusItem.button?.action = #selector(togglePanel)
        }

        panel.setContent(hosting, cornerRadius: Self.cornerRadius)
        panel.onResignKey = { [weak self] in self?.dismiss() }
        ICloudExport.write(store.states)

        // objectWillChange fires before the new value lands, so read it on the next turn.
        storeObserver = store.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.updateStatusImage()
                if self.panel.isVisible { self.positionPanel() }
                ICloudExport.write(self.store.states)
            }
        }
    }

    // MARK: Glyph animation

    /// One glyph's move between sizes: from a value, toward a target, started at a time.
    private struct GlyphMotion {
        var from: CGFloat
        var to: CGFloat
        var start: CFTimeInterval
    }

    /// Redraws the label and, when a service starts or stops working, animates its glyph to
    /// its new size and colour.
    private func updateStatusImage() {
        updateCountdownTimer()
        let targets = targetGrowth()
        if growth.isEmpty || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            // First draw, or "Riduci movimento" is on: go straight to the end state.
            growth = targets
            motions.removeAll()
            stopDisplayLink()
            drawStatusImage()
            return
        }
        let now = CACurrentMediaTime()
        for (id, target) in targets where motions[id]?.to ?? growth[id] != target {
            // Start from wherever the glyph is, so a turn that ends mid-animation reverses smoothly.
            motions[id] = GlyphMotion(from: growth[id] ?? target, to: target, start: now)
        }
        drawStatusImage()
        if !motions.isEmpty, displayLink == nil, let button = statusItem.button {
            // Frames come from the menu bar's own screen, at its refresh rate (120 Hz on ProMotion).
            let link = button.displayLink(target: self, selector: #selector(displayFrame(_:)))
            link.add(to: .main, forMode: .common)  // keeps running while a click is being tracked
            displayLink = link
        }
    }

    /// The countdown changes once a minute; half a minute keeps it at most that far behind.
    private func updateCountdownTimer() {
        if !store.showsCountdown {
            countdownTimer?.invalidate()
            countdownTimer = nil
        } else if countdownTimer == nil {
            let timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateStatusImage() }
            }
            timer.tolerance = 5
            countdownTimer = timer
        }
    }

    private func targetGrowth() -> [ProviderID: CGFloat] {
        Dictionary(uniqueKeysWithValues: ProviderID.allCases.map { ($0, store.activity.isWorking($0) ? 1 : 0) })
    }

    @objc private func displayFrame(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        for (id, motion) in motions {
            let elapsed = now - motion.start
            if elapsed >= Self.springSettle {
                growth[id] = motion.to
                motions[id] = nil
            } else {
                growth[id] = motion.from + (motion.to - motion.from) * Self.spring(elapsed)
            }
        }
        drawStatusImage()
        if motions.isEmpty { stopDisplayLink() }
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    /// A spring like SwiftUI's (response 0.35 s, damping 0.78): quick, with a barely visible
    /// overshoot before it settles, as system animations do. 0 at the start, 1 once settled.
    static func spring(_ t: CFTimeInterval) -> CGFloat {
        let omega = 2 * Double.pi / 0.35, damping = 0.78
        let damped = omega * (1 - damping * damping).squareRoot()
        let decay = exp(-damping * omega * t)
        return CGFloat(1 - decay * (cos(damped * t) + damping * omega / damped * sin(damped * t)))
    }

    /// By then the spring is within a thousandth of its target.
    private static let springSettle: CFTimeInterval = 0.6

    private func drawStatusImage() {
        let label = store.statusLabel(growth: growth)
        statusItem.button?.image = label.base
        colourLayer.image = label.colour
    }

    private var usesExpandedInterface: Bool {
        if #available(macOS 27.0, *) { return true }
        return false
    }

    /// Pre-macOS 27: the button's own click toggles the panel.
    @objc private func togglePanel() {
        if panel.isVisible {
            closePanel()
        } else if Date().timeIntervalSince(lastClosed) > 0.25 {
            // Clicking the icon while open first resigns the panel; don't reopen it right away.
            showPanel()
        }
    }

    /// Closing initiated by us (outside click, Esc, focus loss): on macOS 27 the session must
    /// be cancelled so the menu bar drops the item's selected state too.
    private func dismiss() {
        if #available(macOS 27.0, *), let session = statusItem.expandedInterfaceSession {
            session.cancel()
        }
        closePanel()
    }

    fileprivate func showPanel() {
        store.refreshIfStale()
        positionPanel()
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1
        }
        if !usesExpandedInterface { setButtonHighlighted(true) }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
    }

    fileprivate func closePanel() {
        guard panel.isVisible else { return }
        lastClosed = Date()
        panel.orderOut(nil)
        if !usesExpandedInterface { setButtonHighlighted(false) }
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }

    /// Pre-macOS 27 approximation of the selected look. The button clears its own highlight
    /// on mouse-up, so set it on the next turn.
    private func setButtonHighlighted(_ highlighted: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.statusItem.button?.highlight(highlighted)
        }
    }

    /// Hangs the panel under the status item, kept inside the screen's visible area.
    private func positionPanel() {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let size = hosting.fittingSize
        let screen = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame ?? .zero

        var x = anchor.midX - size.width / 2
        x = min(max(x, screen.minX + 8), screen.maxX - size.width - 8)
        let y = anchor.minY - Self.gapBelowMenuBar - size.height
        // The window extends past the glass by a transparent margin that holds its shadow.
        let glass = NSRect(x: x, y: y, width: size.width, height: size.height)
        let margin = GlassPanel.shadowMargin
        panel.setFrame(glass.insetBy(dx: -margin, dy: -margin), display: true)
    }
}

@available(macOS 27.0, *)
extension StatusController: NSStatusItemExpandedInterfaceDelegate {
    nonisolated func statusItem(
        _ statusItem: NSStatusItem, didBegin expandedInterfaceSession: NSStatusItemExpandedInterfaceSession
    ) {
        MainActor.assumeIsolated { showPanel() }
    }

    nonisolated func statusItemDidEndExpandedInterfaceSession(_ statusItem: NSStatusItem, animated: Bool) {
        MainActor.assumeIsolated { closePanel() }
    }
}

/// Transparent, non-activating panel whose only visible surface is the glass view.
private final class GlassPanel: NSPanel {
    /// Room around the glass for the shadow we draw ourselves.
    static let shadowMargin: CGFloat = 30

    var onResignKey: (() -> Void)?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        // The system shadow and hairline border follow the window's rectangular frame, which
        // shows as square corners behind the glass; ShadowContainer draws a rounded one instead.
        hasShadow = false
        level = .statusBar
        isMovable = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    }

    override var canBecomeKey: Bool { true }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }

    override func cancelOperation(_ sender: Any?) {
        onResignKey?()
    }

    func setContent(_ view: NSView, cornerRadius: CGFloat) {
        let surface: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = cornerRadius
            glass.tintColor = Self.legibilityTint
            // The content sits on a tint that thins out from top to bottom (see GradientBackdrop).
            glass.contentView = GradientBackdrop(content: view, cornerRadius: cornerRadius)
            surface = glass
        } else {
            let effect = NSVisualEffectView()
            effect.material = .popover
            effect.state = .active
            effect.blendingMode = .behindWindow
            effect.maskImage = Self.roundedMask(radius: cornerRadius)
            view.translatesAutoresizingMaskIntoConstraints = false
            effect.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
                view.topAnchor.constraint(equalTo: effect.topAnchor),
                view.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            ])
            surface = effect
        }
        let container = ShadowContainer(surface: surface, cornerRadius: cornerRadius, margin: Self.shadowMargin)
        container.onClickOutsideSurface = { [weak self] in self?.onResignKey?() }
        contentView = container
    }

    /// What the glass tints its backdrop toward. The panel holds a lot of small text, coloured
    /// lines and charts; over a light window plain glass let too much through and they lost
    /// contrast. Toward the appearance's own background colour, it stays glass but reads. This
    /// is the floor at the bottom of the panel; GradientBackdrop adds more toward the top.
    private static let legibilityTint = NSColor(name: "LimitBarGlassTint") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 0.06, alpha: 0.4)
            : NSColor(white: 1, alpha: 0.4)
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// Holds the glass inset by `margin` and casts a shadow shaped like its rounded rectangle.
private final class ShadowContainer: NSView {
    private let surface: NSView
    private let cornerRadius: CGFloat
    private let margin: CGFloat
    var onClickOutsideSurface: (() -> Void)?

    init(surface: NSView, cornerRadius: CGFloat, margin: CGFloat) {
        self.surface = surface
        self.cornerRadius = cornerRadius
        self.margin = margin
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.28
        layer?.shadowRadius = 16
        layer?.shadowOffset = CGSize(width: 0, height: -6)
        addSubview(surface)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        surface.frame = bounds.insetBy(dx: margin, dy: margin)
        layer?.shadowPath = CGPath(roundedRect: surface.frame, cornerWidth: cornerRadius,
                                   cornerHeight: cornerRadius, transform: nil)
    }

    /// The transparent margin still belongs to the window, so treat a click there as outside.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if surface.frame.contains(point) {
            super.mouseDown(with: event)
        } else {
            onClickOutsideSurface?()
        }
    }
}

/// An image view that lets clicks through to the status item's button underneath.
private final class PassthroughImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The glass's content on a layer of the appearance's background colour that fades from top to
/// bottom: denser behind the header, clearer toward the menu items. The glass's own blur can't
/// vary across the panel through public API, so the gradient is in the tint.
private final class GradientBackdrop: NSView {
    private let gradient = CAGradientLayer()

    init(content: NSView, cornerRadius: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        gradient.startPoint = CGPoint(x: 0.5, y: 1)  // the layer's y runs up: 1 is the top
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        layer?.addSublayer(gradient)
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        addSubview(content)
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        gradient.frame = bounds
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let tone: CGFloat = dark ? 0.06 : 1
        gradient.colors = [NSColor(white: tone, alpha: 0.45).cgColor, NSColor(white: tone, alpha: 0).cgColor]
        gradient.locations = [0, 1]
    }
}
