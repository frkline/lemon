import SwiftUI

// MARK: - Design tokens

enum LD {
    // Brand
    static let lemon = Color(r: 0.969, g: 0.784, b: 0.259) // #F7C842
    static let lemondrop = Color(r: 0.996, g: 0.957, b: 0.800) // pale yellow tint
    static let coral = Color(r: 1.000, g: 0.420, b: 0.275) // #FF6B46
    static let citrus = Color(r: 0.176, g: 0.290, b: 0.118) // deep citrus green (use on light)

    // Source marks — bright enough to read on the warm-dark chrome. Linear
    // gets a honey-amber that nods to lemon without competing with the
    // primary-action yellow; GitHub gets the status-done green so the source
    // identifier is consistent with the "complete" semantics across views.
    static let linearMark = Color(r: 0.918, g: 0.682, b: 0.227) // #EAAE3A — warmer than lemon, distinct
    static let githubMark = Color(r: 0.420, g: 0.820, b: 0.500) // brightened statusDone for chip glyphs

    /// Linear's real brand ink — periwinkle. Source of truth for both the
    /// SourceFavicon Linear mark and the selected-Linear-card tint + ring, so
    /// the favicon and the card wash read as one coherent hue. (linearMark above
    /// stays amber — it's the typographic SourceGlyph/IssueSource.accent, separate.)
    static let linearInk = Color(r: 157 / 255, g: 164 / 255, b: 245 / 255) // #9DA4F5

    // Status palette
    static let statusPlanning = Color(r: 0.38, g: 0.59, b: 0.98)
    static let statusExecuting = lemon
    static let statusWaiting = coral
    static let statusReviewing = Color(r: 0.40, g: 0.78, b: 0.56)
    static let statusDone = Color(r: 0.27, g: 0.76, b: 0.48)
    static let statusFailed = Color(r: 0.95, g: 0.27, b: 0.27)

    // Console
    static let consoleBackground = Color(r: 0.102, g: 0.078, b: 0.031) // warm near-black
    static let consoleText = Color(r: 0.910, g: 0.878, b: 0.800) // warm off-white
    static let consoleLemon = lemon
    static let consoleSage = Color(r: 0.553, g: 0.671, b: 0.529)
    static let consoleGemma = Color(r: 0.420, g: 0.710, b: 0.580) // teal-green for [gemma] lines

    // Radius
    static let r3: CGFloat = 3
    static let r6: CGFloat = 6
    static let r10: CGFloat = 10
    static let r14: CGFloat = 14
    static let r20: CGFloat = 20

    // Animation
    static let snappy = Animation.spring(duration: 0.28, bounce: 0.15)
    static let smooth = Animation.easeInOut(duration: 0.22)
    static let slide = Animation.easeInOut(duration: 0.30)

    // MARK: Glass material fills

    //
    // Warm-dark glass at four thicknesses (see design/ui_kits/lemon/materials.html).
    // Each is a baked Color carried at the design's opacity; the SwiftUI Material
    // substrate underneath supplies the actual backdrop blur where applicable.
    static let glassThinFill = Color(r: 34 / 255, g: 28 / 255, b: 18 / 255, a: 0.50) // resting rows, chips
    static let glassRegularFill = Color(r: 46 / 255, g: 38 / 255, b: 24 / 255, a: 0.72) // hover, focus, selected
    static let glassThickFill = Color(r: 33 / 255, g: 27 / 255, b: 17 / 255, a: 0.50) // popover root, panels — lower alpha = more desktop bleed
    // Warm tint laid OVER the behind-window vibrancy backdrop (lemonWindowGlass).
    // Keep it low-alpha — past ~0.3 it occludes the desktop bleed and the popover
    // reads as a flat panel again. Tune against a real wallpaper.
    static let glassWindowTint = Color(r: 33 / 255, g: 27 / 255, b: 17 / 255, a: 0.08) // faint warm cast over the vibrancy — brand warmth without killing bleed
    static let glassOpaqueFill = consoleBackground // console / terminal — solid, no blur
    /// Warm tinted floor for a footer/action bar — the onboarding footer's
    /// `.foot` fill. A touch lighter + warmer than the thick root so the action
    /// row reads as a distinct shelf without a stroke.
    static let footerFill = Color(r: 44 / 255, g: 36 / 255, b: 23 / 255, a: 0.42)

    // MARK: Hairlines

    //
    // Half-pixel catches of light, never a 1px border. Brighten thin → regular as
    // a surface advances. Dividers are a warm near-white at low alpha.
    static let hairlineThin = Color.white.opacity(0.07)
    static let hairlineRegular = Color.white.opacity(0.12)
    // Warm + dim on the thick tier: the popover root is the one edge that meets
    // the bright desktop, so a stark white ring reads as a hard 1px border. A
    // warm near-white at low alpha keeps it a whisper-thin light catch, on-ethos.
    static let hairlineThick = Color(r: 236 / 255, g: 230 / 255, b: 216 / 255, a: 0.06)
    static let hairlineOpaque = Color.white.opacity(0.05)
    static let hairlineDivider = Color(r: 236 / 255, g: 230 / 255, b: 216 / 255, a: 0.12)
    static let hairlineWidth: CGFloat = 0.5

    // MARK: Popover shadow (the only shadow — cast by the window, not its parts)

    static let popoverShadowColor = Color.black.opacity(0.55)
    static let popoverShadowRadius: CGFloat = 28
    static let popoverShadowY: CGFloat = 22

    // MARK: Source-tint washes + selected-ring overrides

    //
    // Saturation only ever appears at wash scale on a selected surface. The ring
    // override lifts the selected hairline to the source hue at low alpha.
    static let tintLemon = lemon.opacity(0.04)
    static let tintLinear = linearInk.opacity(0.036)
    static let tintGithub = Color(r: 107 / 255, g: 209 / 255, b: 128 / 255, a: 0.03)
    static let tintCoral = coral.opacity(0.04)
    static let tintLinearRing = linearInk.opacity(0.35)
    static let tintGithubRing = Color(r: 107 / 255, g: 209 / 255, b: 128 / 255, a: 0.35)
    static let tintCoralRing = coral.opacity(0.35)

    // MARK: Warm text ramp (one hue, stepped down in opacity — never a new color)

    static let textPrimary = Color(r: 236 / 255, g: 230 / 255, b: 216 / 255) // #ECE6D8
    static let textSecondary = textPrimary.opacity(0.66)
    static let textTertiary = textPrimary.opacity(0.50)
    static let textQuaternary = textPrimary.opacity(0.30)

    // MARK: Spacing rhythm (4 · 6/8 · 10–14 · 18–22)

    static let spaceHairline: CGFloat = 4
    static let spaceInlineTight: CGFloat = 6
    static let spaceInline: CGFloat = 8
    static let spaceBlock: CGFloat = 12
    static let spaceSection: CGFloat = 20

    // MARK: Motion — entrance + micro-state (see design/ui_kits/lemon/motion.html)

    static let riseDistance: CGFloat = 7
    static let riseDuration: Double = 0.52
    static let riseCurve = Animation.timingCurve(0.2, 0.75, 0.2, 1.0, duration: 0.52)
    static let staggerStep: Double = 0.06
    static let chevronSpin = Animation.easeInOut(duration: 0.2)
}

// MARK: - Color initialiser

extension Color {
    init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.init(red: r, green: g, blue: b, opacity: a)
    }

    init(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var rgb: UInt64 = 0
        Scanner(string: h).scanHexInt64(&rgb)
        self.init(
            r: Double((rgb >> 16) & 0xFF) / 255,
            g: Double((rgb >> 8) & 0xFF) / 255,
            b: Double(rgb & 0xFF) / 255,
        )
    }
}

// MARK: - Session status helpers

extension SessionStatus {
    var color: Color {
        switch self {
        case .planning: LD.statusPlanning
        case .planReview: LD.statusWaiting
        case .executing: LD.statusExecuting
        case .waiting: LD.statusWaiting
        case .resultReview: LD.statusReviewing
        case .reviewing: LD.statusReviewing
        case .done: LD.statusDone
        case .failed: LD.statusFailed
        }
    }

    var symbol: String {
        switch self {
        case .planning: "brain"
        case .planReview: "list.clipboard"
        case .executing: "hammer.fill"
        case .waiting: "pause.circle.fill"
        case .resultReview: "checklist"
        case .reviewing: "checklist"
        case .done: "checkmark"
        case .failed: "xmark"
        }
    }
}

// MARK: - Reusable components

/// Quiet polling indicator — a comet-trail arc (angular gradient fading to clear)
/// that spins continuously. Replaces the stock `ProgressView()`, whose tiny
/// indeterminate spinner reads muddy/low-contrast on the warm-dark glass. Tinted
/// `textTertiary`, never `lemon` (the one yellow is reserved for the primary
/// action), so it stays a calm background signal.
struct LemonSpinner: View {
    var size: CGFloat = 12
    @State private var spinning = false

    var body: some View {
        Circle()
            .stroke(
                AngularGradient(
                    gradient: Gradient(colors: [LD.textTertiary.opacity(0), LD.textTertiary]),
                    center: .center,
                ),
                style: StrokeStyle(lineWidth: 1.6, lineCap: .round),
            )
            .frame(width: size - 1, height: size - 1)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(.linear(duration: 0.85).repeatForever(autoreverses: false), value: spinning)
            .frame(width: size, height: size)
            .onAppear { spinning = true }
            .accessibilityLabel("Polling")
    }
}

/// The standalone tinted-capsule status badge (detail header / standalone use).
/// One tinted capsule per state — color-matched label over a 15% fill with a
/// 36% hairline ring. No dot: the hue alone reads at a glance, and in a row the
/// dot+label form carries the signal instead. See status-pill.html.
struct StatusPill: View {
    let status: SessionStatus

    var body: some View {
        Text(status.displayLabel)
            .font(.system(size: 11, weight: .semibold))
            .tracking(-0.1)
            .foregroundStyle(status.color)
            .frame(height: 21)
            .padding(.horizontal, 11)
            .background(status.color.opacity(0.15), in: Capsule())
            .overlay(
                Capsule().strokeBorder(status.color.opacity(0.36),
                                       lineWidth: LD.hairlineWidth),
            )
    }
}

/// The lemon-yellow primary button style.
struct LemonButtonStyle: ButtonStyle {
    var isDestructive = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(isDestructive ? .white : LD.citrus)
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .background(
                isDestructive ? LD.coral : LD.lemon,
                in: RoundedRectangle(cornerRadius: LD.r6),
            )
            .opacity(configuration.isPressed ? 0.82 : isEnabled ? 1 : 0.35)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(LD.snappy, value: configuration.isPressed)
    }
}

/// Ghosted secondary button. Warm-ramp label over a warm neutral fill — never
/// the cool system gray.
struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(LD.textSecondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(LD.textPrimary.opacity(configuration.isPressed ? 0.08 : 0.05),
                        in: RoundedRectangle(cornerRadius: LD.r6))
            .animation(LD.snappy, value: configuration.isPressed)
    }
}

// MARK: - Glass material

/// The four glass thicknesses. Hierarchy is blur + fill opacity — a surface
/// advances by thickening, not by gaining a border or a shadow. Only `.thick`
/// (the popover root) casts a shadow; `.opaque` is the solid machine surface.
enum GlassElevation {
    case thin, regular, thick, opaque

    /// Baked warm fill carried over the material substrate (or alone, for opaque).
    var fill: Color {
        switch self {
        case .thin: LD.glassThinFill
        case .regular: LD.glassRegularFill
        case .thick: LD.glassThickFill
        case .opaque: LD.glassOpaqueFill
        }
    }

    /// Half-pixel hairline ring colour for this tier.
    var hairline: Color {
        switch self {
        case .thin: LD.hairlineThin
        case .regular: LD.hairlineRegular
        case .thick: LD.hairlineThick
        case .opaque: LD.hairlineOpaque
        }
    }

    /// Only the popover root drops a shadow.
    var hasShadow: Bool {
        self == .thick
    }

    /// The opaque console surface does not blur the desktop behind it.
    var blursBackdrop: Bool {
        self != .opaque
    }

    /// SwiftUI material substrate for the blurred tiers.
    var material: Material {
        switch self {
        case .thin: .ultraThinMaterial
        case .regular, .thick: .regularMaterial
        case .opaque: .regularMaterial // unused — blursBackdrop is false
        }
    }
}

/// Applies a Lemon glass surface: material substrate → warm fill → optional tint
/// wash → half-pixel hairline ring on top → continuous-corner clip → popover
/// shadow (thick only). Use `.lemonGlass(_:)` rather than this type directly.
struct LemonGlass: ViewModifier {
    let elevation: GlassElevation
    var tint: Color?
    var cornerRadius: CGFloat = LD.r10
    var ringOverride: Color?

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return content
            .background {
                shape
                    .fill(elevation.fill)
                    .background {
                        // Material substrate sits *under* the warm fill so the
                        // blur reads through it. Opaque skips it entirely.
                        if elevation.blursBackdrop {
                            shape.fill(elevation.material)
                        }
                    }
                    .overlay {
                        // Source-tint wash over the fill, under the ring.
                        if let tint {
                            shape.fill(tint)
                        }
                    }
                    .overlay {
                        // Hairline ring is the topmost layer — strokeBorder insets
                        // the 0.5pt line inside the bounds so it never clips.
                        shape.strokeBorder(ringOverride ?? elevation.hairline,
                                           lineWidth: LD.hairlineWidth)
                    }
                    .clipShape(shape)
                    .modifier(PopoverShadow(active: elevation.hasShadow))
            }
    }
}

/// Conditionally attaches the popover shadow — applying a zero-radius shadow
/// would still cost a layer, so non-thick tiers get nothing at all.
private struct PopoverShadow: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        if active {
            content.shadow(color: LD.popoverShadowColor,
                           radius: LD.popoverShadowRadius, x: 0, y: LD.popoverShadowY)
        } else {
            content
        }
    }
}

extension View {
    /// Wrap a view in a Lemon glass surface at the given elevation.
    func lemonGlass(_ elevation: GlassElevation,
                    tint: Color? = nil,
                    cornerRadius: CGFloat = LD.r10,
                    ring: Color? = nil) -> some View
    {
        modifier(LemonGlass(elevation: elevation, tint: tint,
                            cornerRadius: cornerRadius, ringOverride: ring))
    }
}

// MARK: - Rise (staggered entrance)

/// The popover's one entrance: a short, staggered rise (translateY 7 → 0,
/// opacity 0 → 1) on `LD.riseCurve`, children delayed by `index * staggerStep`.
/// The visible end-state IS the base style, so reduced-motion and smoke
/// screenshots render settled — never stuck at opacity 0.
struct Rise: ViewModifier {
    let index: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    func body(content: Content) -> some View {
        // Smoke screenshots and reduced-motion both want the settled end-state
        // immediately, with no animation in flight.
        let animate = !reduceMotion && !KeychainStore.isSmokeTesting
        return content
            .opacity(animate ? (shown ? 1 : 0) : 1)
            .offset(y: animate ? (shown ? 0 : LD.riseDistance) : 0)
            .onAppear {
                guard animate else { return }
                withAnimation(LD.riseCurve.delay(Double(index) * LD.staggerStep)) {
                    shown = true
                }
            }
    }
}

extension View {
    /// Staggered entrance rise; `index` orders the stagger top-to-bottom.
    func rise(_ index: Int) -> some View {
        modifier(Rise(index: index))
    }
}

// MARK: - Source surfacing

//
// `SourceGlyph` is the canonical way to indicate which provider (Linear or
// GitHub) backs an `IssueRef` or `WorkspacePair`. Typographic, not chromatic —
// quiet enough to live next to an identifier without stealing the headline.
//
// Rendered as a small monospace letter inside a hairline border, tinted with
// the source's accent. Tooltip exposes the full source + matchKey.

extension IssueSource {
    /// Compact two-character marker for chips and badges.
    var glyph: String {
        switch self {
        case .linear: "L"
        case .github: "gh"
        }
    }

    /// Editorial accent — used for source glyphs, dots, micro-borders.
    /// LD.lemon stays reserved for primary actions per the discipline rule;
    /// `linearMark` is a warmer honey-amber that reads cleanly on the warm-dark
    /// chrome without competing with the lemon CTA. GitHub gets the bright
    /// statusDone green so its mark is consistent with the "complete" hue
    /// the user already learned.
    var accent: Color {
        switch self {
        case .linear: LD.linearMark
        case .github: LD.githubMark
        }
    }
}

/// Favicon-style provider tile: a rounded square with a source-tinted fill,
/// a 0.5pt ring, and the provider's geometric mark inset to ~68% of the tile.
/// Width-stable across Linear / GitHub. See design/ui_kits/lemon/source-glyph.html.
struct SourceFavicon: View {
    let source: IssueSource
    var size: CGFloat = 16

    var body: some View {
        let radius = min(6, max(5, size * 0.30)) // 16 → 5, 22 → 6 (matches the kit)
        let inner = size * 0.68
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        shape
            .fill(tileBackground)
            .overlay {
                mark
                    .frame(width: inner, height: inner)
            }
            .overlay {
                shape.strokeBorder(tileRing, lineWidth: 0.5)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    @ViewBuilder private var mark: some View {
        switch source {
        case .linear: LinearMark()
        case .github:
            GitHubCatMark()
                .fill(SourceFavicon.githubInk)
        }
    }

    // Linear: light-purple family tile (#5E6AD2 @ .22) + brighter ring.
    // GitHub: cool-grey tile + faint near-white ring.
    private var tileBackground: Color {
        switch source {
        case .linear: Color(r: 94 / 255, g: 106 / 255, b: 210 / 255, a: 0.22)
        case .github: Color(r: 150 / 255, g: 152 / 255, b: 168 / 255, a: 0.22)
        }
    }

    private var tileRing: Color {
        switch source {
        case .linear: Color(r: 124 / 255, g: 134 / 255, b: 232 / 255, a: 0.48)
        case .github: Color(r: 214 / 255, g: 216 / 255, b: 228 / 255, a: 0.30)
        }
    }

    static let linearInk = LD.linearInk // #9DA4F5 — single source of truth in LD
    static let githubInk = Color(r: 242 / 255, g: 239 / 255, b: 233 / 255) // #F2EFE9
}

/// Linear's three diagonal bars. Each is a rounded bar from the 12-unit viewBox
/// (x 0.6→11.4, height 1.5, rx .75) rotated 45° about centre (6,6) — exactly the
/// SVG in source-glyph.html, ported to a ZStack of `RoundedRectangle`s.
private struct LinearMark: View {
    var body: some View {
        GeometryReader { geo in
            let scale = geo.size.width / 12 // square frame
            ZStack {
                ForEach(0 ..< 3, id: \.self) { i in
                    // Bar centres post-rotation, as offsets from viewBox centre (6,6):
                    // (+1.662,-1.662), (0,0), (-1.662,+1.662) — see derivation in PR notes.
                    let off: CGFloat = (CGFloat(i) - 1) * -1.662
                    RoundedRectangle(cornerRadius: 0.75 * scale, style: .continuous)
                        .fill(SourceFavicon.linearInk)
                        .frame(width: 10.8 * scale, height: 1.5 * scale)
                        .rotationEffect(.degrees(45))
                        .offset(x: off * scale, y: -off * scale)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// GitHub's cat silhouette, ported from the `<path d=…>` in source-glyph.html on
/// a 16-unit viewBox. The bottom SVG arc (rx 5.5, ry 5.2) is approximated with
/// two quarter-ellipse cubics (k = 0.5523) for a faithful rounded chin.
private struct GitHubCatMark: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 16
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * s, y: rect.minY + y * s)
        }
        var path = Path()
        path.move(to: p(3.7, 5.4))
        path.addLine(to: p(5.5, 2.4)) // left ear
        path.addLine(to: p(7.1, 4.6))
        path.addCurve(to: p(8.9, 4.6), control1: p(7.7, 4.5), control2: p(8.3, 4.5))
        path.addLine(to: p(10.5, 2.4)) // right ear
        path.addLine(to: p(12.3, 5.4))
        path.addCurve(to: p(13.5, 9), control1: p(13.2, 6.7), control2: p(13.5, 7.9))
        // Bottom arc (13.5,9) → (8,14.2) → (2.5,9), two 90° cubics:
        path.addCurve(to: p(8, 14.2), control1: p(13.5, 11.872), control2: p(11.038, 14.2))
        path.addCurve(to: p(2.5, 9), control1: p(4.962, 14.2), control2: p(2.5, 11.872))
        path.addCurve(to: p(3.7, 5.4), control1: p(2.5, 7.9), control2: p(2.8, 6.7))
        path.closeSubpath()
        return path
    }
}

/// Source marker. Renders a `SourceFavicon` (real provider vector mark) at a
/// tile scaled from `size`, with an optional matchKey-style sublabel. The outer
/// API is unchanged so existing call sites are untouched.
struct SourceGlyph: View {
    let source: IssueSource
    var size: CGFloat = 9
    var label: String? // optional matchKey-style sublabel for inline use

    var body: some View {
        HStack(spacing: 4) {
            // The legacy `size` was a font point size (~8–11); doubling lands the
            // favicon tile in the design's 16–22 range (8→16, 9→18, 11→22).
            SourceFavicon(source: source, size: size * 2)
            if let label {
                Text(label)
                    .font(.system(size: size + 1, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .help(tooltipText)
    }

    private var tooltipText: String {
        switch source {
        case .linear: "Linear" + (label.map { " · \($0)" } ?? "")
        case .github: "GitHub" + (label.map { " · \($0)" } ?? "")
        }
    }
}

extension IssueRef {
    /// Human-readable source label used in hover tooltips + a11y.
    var sourceTitle: String {
        switch scope {
        case .linearTeam:
            "Linear · \(identifierPrefix)"
        case let .githubRepo(owner, repo, _):
            "GitHub · \(owner)/\(repo)"
        }
    }
}

/// High-emphasis brand mark — uses the actual Linear / GitHub logos shipped
/// in the asset catalog. Use in places where the source is the headline of
/// the surface (segmented picker, identity card eyebrow). For inline labels
/// + chips, keep `SourceGlyph` (typographic, more editorial restraint).
struct SourceMark: View {
    let source: IssueSource
    var size: CGFloat = 16

    var body: some View {
        Group {
            switch source {
            case .linear:
                Image("LinearMark")
                    .resizable()
                    .scaledToFit()
            case .github:
                // Octicon is a template-rendering SVG — takes the current
                // foreground color so it composes against any background.
                Image("GitHubMark")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.primary)
            }
        }
        .frame(width: size, height: size)
        // Lock the intrinsic size — without .fixedSize() a SourceMark
        // used as a SwiftUI Menu label can be re-stretched by the
        // borderless menu style and balloon to fill the popover.
        .fixedSize()
        .accessibilityHidden(true)
    }
}

// MARK: - Step rail (finite-sequence position marker)

/// A quiet progress marker for a finite, ordered sequence. It sits in the
/// header's right slot — the exact position the live "N running" count pill
/// occupies once configured — so the day-one (onboarding) and day-two (daily)
/// headers share one anatomy. Position is encoded with the warm opacity ramp,
/// never a new hue: completed steps are `secondary` dots, the current step a
/// `primary` 14×5 capsule, upcoming steps `quaternary` outlines.
/// See design/ui_kits/lemon/onboarding.html (`.rail`).
struct StepRail: View {
    let total: Int
    let current: Int // 0-based index of the active step

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0 ..< total, id: \.self) { i in
                marker(for: i)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Step \(current + 1) of \(total)")
    }

    @ViewBuilder
    private func marker(for i: Int) -> some View {
        let shape = Capsule(style: .continuous)
        if i == current {
            shape.fill(LD.textPrimary).frame(width: 14, height: 5)
        } else if i < current {
            shape.fill(LD.textSecondary).frame(width: 5, height: 5)
        } else {
            shape.strokeBorder(LD.textQuaternary, lineWidth: 1).frame(width: 5, height: 5)
        }
    }
}

// MARK: - Segmented control (two-option toggle)

/// A segmented selector. The track is thin glass at r10; the selected segment
/// thickens to the regular tier at r6 — depth by material, not by a moving
/// accent. Replaces SwiftUI's `.pickerStyle(.segmented)`, whose system-accent
/// blue clashes with the closed warm palette. `content` renders each option's
/// interior given its selected state (e.g. a `SourceFavicon` + label, or a
/// size + footprint hint). See design/ui_kits/lemon/onboarding.html (`.seg`).
struct LemonSegmented<Value: Hashable, Content: View>: View {
    let values: [Value]
    @Binding var selection: Value
    var height: CGFloat = 30
    @ViewBuilder let content: (Value, Bool) -> Content

    var body: some View {
        HStack(spacing: 3) {
            ForEach(values, id: \.self) { value in
                let selected = value == selection
                Button {
                    withAnimation(LD.snappy) { selection = value }
                } label: {
                    content(value, selected)
                        .frame(maxWidth: .infinity)
                        .frame(height: height)
                        .contentShape(RoundedRectangle(cornerRadius: LD.r6, style: .continuous))
                        .modifier(SegmentSelection(selected: selected))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .lemonGlass(.thin, cornerRadius: LD.r10)
    }
}

/// The selected segment lifts to the regular glass tier; unselected segments
/// stay bare so the track shows through.
private struct SegmentSelection: ViewModifier {
    let selected: Bool
    func body(content: Content) -> some View {
        if selected {
            content.lemonGlass(.regular, cornerRadius: LD.r6)
        } else {
            content
        }
    }
}

// MARK: - Editable field chrome

extension View {
    /// Wraps an input control in the editable-field chrome: resting thin glass
    /// at r6, thickening to the regular tier with a brighter neutral ring (`.20`)
    /// when `focused`. The lemondrop caret comes from `.tint` applied here; pair
    /// with a mono font on the value for keys / paths / identifiers and a
    /// tertiary placeholder. The system-only counterpart to the read-only masked
    /// credential the daily UI shows. See onboarding.html (`.field`).
    func lemonField(focused: Bool, height: CGFloat = 34) -> some View {
        modifier(LemonFieldChrome(focused: focused, height: height))
    }
}

struct LemonFieldChrome: ViewModifier {
    let focused: Bool
    var height: CGFloat = 34

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: height)
            .lemonGlass(focused ? .regular : .thin, cornerRadius: LD.r6,
                        ring: focused ? LD.textPrimary.opacity(0.20) : nil)
            .tint(LD.lemondrop)
            .animation(LD.smooth, value: focused)
    }
}

// MARK: - Dependency chip

/// A `.cap`-style pill with a status-coloured leading dot — `tmux ✓`, `hf ✓`,
/// `hf · sign in`. A small extension of the resting chip: the dot carries the
/// state at dot scale (color is earned), the label stays warm-neutral. The
/// loading variant shows a mini spinner in the dot's place.
/// See design/ui_kits/lemon/onboarding.html (`.chip`).
struct DependencyChip: View {
    let label: String
    let status: Status

    enum Status: Equatable { case loading, ok, attention }

    var body: some View {
        HStack(spacing: 5) {
            switch status {
            case .loading:
                ProgressView().controlSize(.mini).frame(width: 8, height: 8)
            case .ok:
                Circle().fill(LD.statusDone).frame(width: 6, height: 6)
            case .attention:
                Circle().fill(LD.coral).frame(width: 6, height: 6)
            }
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(status == .attention ? LD.textTertiary : LD.textSecondary)
        }
        .padding(.horizontal, 9)
        .frame(height: 24)
        .lemonGlass(.thin, cornerRadius: 999)
    }
}

// MARK: - Inline link

/// The standard inline link treatment — "create one ↗" rendered in warm
/// `LD.textSecondary`, never the platform blue, to keep the palette closed.
struct InlineLink: View {
    let title: String
    let url: URL

    var body: some View {
        Link(destination: url) {
            HStack(spacing: 3) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(LD.textSecondary)
        }
        .buttonStyle(.plain)
    }
}
