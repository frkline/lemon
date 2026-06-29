import os
import SwiftUI

/// Small UInt16 helper for the MCP port default — guards against UserDefaults
/// returning 0 when the key has never been set.
private extension UInt16 {
    func nonZeroOr(_ fallback: UInt16) -> UInt16 {
        self == 0 ? fallback : self
    }
}

private extension Int {
    var asUInt16: UInt16 {
        guard self >= 0, self <= Int(UInt16.max) else { return 0 }
        return UInt16(self)
    }
}

@main
struct LemonApp: App {
    /// AppDelegate is always installed — in DEBUG it boots smoke-test mode;
    /// in Release it pops the menu-bar popover on first launch so the
    /// wizard is visible without the user having to hunt for the icon.
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @State private var orchestrator: Orchestrator = {
        #if DEBUG
            if KeychainStore.isMockMode { return MockAppState.shared.orchestrator }
        #endif
        let o = Orchestrator()
        // Start polling at launch when already configured — otherwise polling
        // only kicked in once the user opened the popover, which meant Lemon
        // would silently miss 🍋 issues at app startup. start() is idempotent
        // so the .task on PopoverView below is harmless redundancy.
        if KeychainStore.shared.isConfigured {
            Task { @MainActor in
                o.start()
                LemonApp.startMCPServerIfRequested(orchestrator: o)
            }
        }
        return o
    }()

    /// Bring up the MCP server when the user opted in — either via the
    /// Settings toggle (lemon-mcp-enabled UserDefault) or by setting
    /// LEMON_ENABLE_MCP=1 in the launch environment. The env var wins, so
    /// power users can flip the server on for one launch without persisting.
    @MainActor
    static func startMCPServerIfRequested(orchestrator: Orchestrator) {
        let env = ProcessInfo.processInfo.environment
        let envOn = ["1", "true", "yes", "on"].contains((env["LEMON_ENABLE_MCP"] ?? "").lowercased())
        let defaultsOn = UserDefaults.standard.bool(forKey: "lemon-mcp-enabled")
        guard envOn || defaultsOn else { return }
        let port = UserDefaults.standard.integer(forKey: "lemon-mcp-port")
            .asUInt16
            .nonZeroOr(LemonMCPServer.defaultPort)
        do {
            try LemonMCPServer.shared.start(port: port)
            LemonMCPTools.registerAll(server: LemonMCPServer.shared,
                                      orchestrator: orchestrator)
        } catch {
            Logger.orchestrator.error("MCP server failed to start on \(port): \(error.localizedDescription)")
        }
    }

    @State private var nav: AppNavigation = {
        #if DEBUG
            if KeychainStore.isMockMode { return MockAppState.shared.nav }
        #endif
        return AppNavigation()
    }()

    @State private var onboardingComplete: Bool = KeychainStore.shared.isConfigured

    var body: some Scene {
        MenuBarExtra {
            Group {
                if onboardingComplete {
                    PopoverView()
                        .environment(orchestrator)
                        .environment(nav)
                        .task {
                            guard !KeychainStore.isMockMode else { return }
                            orchestrator.start()
                        }
                } else {
                    OnboardingView(isComplete: $onboardingComplete)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .lemonRerunSetup)) { _ in
                onboardingComplete = false
                // Re-running setup pops the menu-bar popover open so the
                // user lands in the wizard immediately, in the same
                // surface they'll use once configured.
                LemonApp.openMenuBarPopover()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                // willTerminate is delivered on the main thread, so it's safe to
                // assume MainActor isolation for the now-@MainActor stop() (#70).
                MainActor.assumeIsolated { LocalLLM.shared.stop() }
                // #55: deliberately do NOT tear down -L lemon tmux/claude on
                // quit. Long-running sessions must survive a Lemon restart
                // (auto-update, crash) so a relaunch re-adopts in-flight work
                // (#35/#38). The leak is bounded instead by the startup sweep
                // (Orchestrator.reconcileOrphans). Manual escape hatch if Lemon
                // is uninstalled with the server still up: `tmux -L lemon kill-server`.
            }
            .onChange(of: onboardingComplete) { _, complete in
                // Wizard just transitioned to complete — orchestrator
                // polling will get kicked by PopoverView's .task on the
                // next render. MCP server isn't tied to that, so fire
                // it here so it comes up alongside the polling loop.
                guard complete else { return }
                LemonApp.startMCPServerIfRequested(orchestrator: orchestrator)
            }
        } label: {
            MenuBarGlyphView(glyph: orchestrator.menuBarGlyph)
        }
        .menuBarExtraStyle(.window)
    }

    /// Simulate a click on Lemon's menu bar item so the popover (containing
    /// either the wizard or the configured PopoverView) pops open. Used at
    /// launch when the user isn't configured yet — keeps the wizard in the
    /// same surface they'll meet day-to-day, no separate window. Also
    /// re-used by `.lemonRerunSetup` from Settings.
    /// Clicks the MenuBarExtra's status button to open its popover. Returns
    /// `true` once it found a status button to click, `false` if none exists
    /// yet (SwiftUI installs the `NSStatusItem` a beat after launch, so the
    /// caller should retry until this returns true). Activates the app first so
    /// the popover can become key.
    @MainActor
    @discardableResult
    static func openMenuBarPopover() -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        // NSStatusBar.system exposes its items only via the private
        // `_statusItems` KVC collection; SwiftUI's MenuBarExtra installs exactly
        // one. performClick on its button toggles the popover open.
        let items = NSStatusBar.system.value(forKey: "_statusItems") as? [NSStatusItem]
        guard let items else { return false }
        for item in items {
            if let button = item.button {
                button.performClick(nil)
                return true
            }
        }
        return false
    }
}

/// The menu-bar lemon, drawn as a vector path and baked into a *template*
/// `NSImage` so it stays razor-crisp at any backing scale and auto-tints to the
/// menu bar's foreground (light glyph in dark bars, dark in light). Replaces the
/// old low-res raster imagesets — see `Image(nsImage:)` in the `MenuBarExtra`
/// label above.
///
/// Two variants mirror the previous PNGs' distinction:
/// - `active` — a **filled** lemon (sessions running)
/// - `idle`   — the same lemon as an **outline** (nothing running)
///
/// The shape is a stylized lemon: a plump oval body with gently pointed tips
/// (two cubic arcs meeting at corners), tilted so the upper tip lifts to the
/// left, with a small leaf sprouting from the top.
/// The menu-bar label. While an agent is **working**, the solid lemon gently
/// "breathes" (opacity 1 → 0.62 → 1, ~2.4s ease-in-out) per the design handoff —
/// a calm sign of life. Other states render static. (MenuBarExtra honors the
/// label's animation where the platform supports it; static otherwise — harmless.)
struct MenuBarGlyphView: View {
    let glyph: MenuBarGlyph
    @State private var dim = false

    var body: some View {
        Image(nsImage: LemonGlyph.menuBar(for: glyph))
            .renderingMode(.template)
            .opacity(glyph == .working && dim ? 0.62 : 1)
            .animation(
                glyph == .working
                    ? .easeInOut(duration: 1.2).repeatForever(autoreverses: true)
                    : .default,
                value: dim,
            )
            .onAppear { dim = glyph == .working }
            .onChange(of: glyph) { _, new in dim = new == .working }
            .accessibilityLabel("Lemon — \(glyph.rawValue)")
    }
}

private enum LemonGlyph {
    /// Filled lemon — shown while sessions are active.
    static let active: NSImage = render(filled: true)
    /// Outlined lemon — shown while idle.
    static let idle: NSImage = render(filled: false)

    /// The status glyph template image for the aggregate menu-bar state. Uses the
    /// design-handoff `MenuLemon*` template imagesets (idle/working/waiting/done/
    /// error/disabled, with badges); falls back to the programmatic lemon if an
    /// asset is somehow missing so the menu bar never goes blank.
    static func menuBar(for glyph: MenuBarGlyph) -> NSImage {
        if let img = NSImage(named: glyph.assetName) {
            img.isTemplate = true
            return img
        }
        return (glyph == .idle || glyph == .disabled) ? idle : active
    }

    /// Point size of the rendered image. The drawing handler is resolution
    /// independent (AppKit re-invokes it per backing scale), so this is just the
    /// logical size the menu bar lays out against — the pixels are always vector.
    private static let pointSize: CGFloat = 18

    /// Design-space side length. All path coordinates are authored in a
    /// 100×100 box centered on the origin, then scaled to fit the image.
    private static let designBox: CGFloat = 100

    private static func render(filled: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: pointSize, height: pointSize),
                            flipped: false)
        { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            draw(filled: filled, in: ctx, rect: rect)
            return true
        }
        // Template => AppKit uses only the alpha mask and tints with the menu
        // bar's vibrancy. Colors painted below are therefore irrelevant.
        image.isTemplate = true
        return image
    }

    private static func draw(filled: Bool, in ctx: CGContext, rect: CGRect) {
        ctx.saveGState()
        // Map the centered design box into the image, leaving a little margin
        // (the leaf and stroke overshoot the body), and nudge the content down
        // so the leaf-heavy silhouette sits optically centered.
        let scale = (rect.width / designBox) * 0.9
        ctx.translateBy(x: rect.midX, y: rect.midY)
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: 0, y: -6)

        let body = bodyPath()
        let leaf = leafPath()

        ctx.setFillColor(NSColor.black.cgColor)
        ctx.setStrokeColor(NSColor.black.cgColor)

        if filled {
            // Two separate fills => their union, with no winding-rule holes
            // where the leaf overlaps the body.
            ctx.addPath(body)
            ctx.fillPath()
            ctx.addPath(leaf)
            ctx.fillPath()
        } else {
            ctx.setLineWidth(6) // design units -> ~1pt at menu-bar size
            ctx.setLineJoin(.round)
            ctx.setLineCap(.round)
            ctx.addPath(body)
            ctx.strokePath()
            ctx.addPath(leaf)
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    /// Plump lemon body: a horizontal oval clearly wider than tall, drawn as two
    /// cubic arcs (top + bottom) that meet at the left/right tips. The near-tip
    /// control points sit well inboard (`tipRun`) so the curve flattens as it
    /// reaches each tip, forming the small but visible pointed nubs that read as
    /// a lemon rather than a pebble. Tilted a touch (`tilt`) so the left tip
    /// lifts and the right dips. Tunables: `a`/`b` set the oval (wider = more
    /// lemon), larger `tipRun` = sharper points, `tilt` = lean.
    private static func bodyPath() -> CGPath {
        let a: CGFloat = 46 // half-length (horizontal / major axis)
        let b: CGFloat = 30 // half-width  (vertical / minor axis)
        let tipRun: CGFloat = 27 // inboard offset of near-tip controls (↑ = sharper tips)
        let tipRise: CGFloat = b * 4 / 3 // control bulge ≈ b / 0.75 to reach full height
        let tilt: CGFloat = -8 // degrees of lean
        let body = CGMutablePath()
        body.move(to: CGPoint(x: -a, y: 0))
        body.addCurve(to: CGPoint(x: a, y: 0),
                      control1: CGPoint(x: -a + tipRun, y: tipRise),
                      control2: CGPoint(x: a - tipRun, y: tipRise))
        body.addCurve(to: CGPoint(x: -a, y: 0),
                      control1: CGPoint(x: a - tipRun, y: -tipRise),
                      control2: CGPoint(x: -a + tipRun, y: -tipRise))
        body.closeSubpath()
        var transform = CGAffineTransform(rotationAngle: tilt * .pi / 180)
        return body.copy(using: &transform) ?? body
    }

    /// Curved almond leaf sprouting from the body's top-left shoulder: pointed at
    /// both ends with a full belly and a gentle midrib bend, so it reads as a
    /// real leaf and not a thin stem. Tunables: `len`/`w` set leaf size,
    /// `angle` its lean (≈124° points up-left), `tx`/`ty` nestle it against the
    /// body's shoulder.
    private static func leafPath() -> CGPath {
        let len: CGFloat = 15 // half-length
        let w: CGFloat = 11 // half-width
        let angle: CGFloat = 124 // degrees (up-left lean)
        let tx: CGFloat = -24
        let ty: CGFloat = 27
        let leaf = CGMutablePath()
        leaf.move(to: CGPoint(x: -len, y: 0))
        // Outer (convex) edge — full belly sweeping to the far tip.
        leaf.addCurve(to: CGPoint(x: len, y: 0),
                      control1: CGPoint(x: -len * 0.45, y: w * 1.5),
                      control2: CGPoint(x: len * 0.55, y: w * 1.2))
        // Inner edge back to base — a touch shallower for a gentle leaf bend.
        leaf.addCurve(to: CGPoint(x: -len, y: 0),
                      control1: CGPoint(x: len * 0.55, y: -w * 0.9),
                      control2: CGPoint(x: -len * 0.45, y: -w * 1.2))
        leaf.closeSubpath()
        var transform = CGAffineTransform(rotationAngle: angle * .pi / 180)
            .concatenating(CGAffineTransform(translationX: tx, y: ty))
        return leaf.copy(using: &transform) ?? leaf
    }
}
