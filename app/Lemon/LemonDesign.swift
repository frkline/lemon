import SwiftUI

// MARK: - Design tokens

enum LD {
    // Brand
    static let lemon      = Color(r: 0.969, g: 0.784, b: 0.259)  // #F7C842
    static let lemondrop  = Color(r: 0.996, g: 0.957, b: 0.800)  // pale yellow tint
    static let coral      = Color(r: 1.000, g: 0.420, b: 0.275)  // #FF6B46
    static let citrus     = Color(r: 0.176, g: 0.290, b: 0.118)  // deep citrus green (use on light)

    // Source marks — bright enough to read on the warm-dark chrome. Linear
    // gets a honey-amber that nods to lemon without competing with the
    // primary-action yellow; GitHub gets the status-done green so the source
    // identifier is consistent with the "complete" semantics across views.
    static let linearMark = Color(r: 0.918, g: 0.682, b: 0.227)  // #EAAE3A — warmer than lemon, distinct
    static let githubMark = Color(r: 0.420, g: 0.820, b: 0.500)  // brightened statusDone for chip glyphs

    // Status palette
    static let statusPlanning  = Color(r: 0.38, g: 0.59, b: 0.98)
    static let statusExecuting = lemon
    static let statusWaiting   = coral
    static let statusReviewing = Color(r: 0.40, g: 0.78, b: 0.56)
    static let statusDone      = Color(r: 0.27, g: 0.76, b: 0.48)
    static let statusFailed    = Color(r: 0.95, g: 0.27, b: 0.27)

    // Console
    static let consoleBackground = Color(r: 0.102, g: 0.078, b: 0.031)  // warm near-black
    static let consoleText       = Color(r: 0.910, g: 0.878, b: 0.800)  // warm off-white
    static let consoleLemon      = lemon
    static let consoleSage       = Color(r: 0.553, g: 0.671, b: 0.529)
    static let consoleGemma      = Color(r: 0.420, g: 0.710, b: 0.580)  // teal-green for [gemma] lines

    // Radius
    static let r3:  CGFloat = 3
    static let r6:  CGFloat = 6
    static let r10: CGFloat = 10
    static let r14: CGFloat = 14
    static let r20: CGFloat = 20

    // Animation
    static let snappy  = Animation.spring(duration: 0.28, bounce: 0.15)
    static let smooth  = Animation.easeInOut(duration: 0.22)
    static let slide   = Animation.easeInOut(duration: 0.30)

    // MARK: - Liquid Glass tokens (macOS 26)
    //
    // Additive overlays painted on top of the system material to give each
    // surface an editorial cast — a hint of brand without flooding the chrome.
    // Tint amounts are deliberately small; the system material is doing most
    // of the work, the tint is the colour temperature.
    static let glassTintLemon  = lemon.opacity(0.04)
    static let glassTintCoral  = coral.opacity(0.04)
    static let glassTintLinear = linearMark.opacity(0.06)
    static let glassTintGitHub = githubMark.opacity(0.05)

    // Quiet inner-edge highlight that gives glass surfaces depth without
    // a visible stroke. White carries the macOS 26 lensing language better
    // than primary.opacity, which reads as a sharp pen line on glass.
    static let glassEdge       = Color.white.opacity(0.07)
    static let glassEdgeHover  = Color.white.opacity(0.12)

    /// Elevation drives the glass treatment for a surface.
    ///
    /// `.resting`   thin material, soft edge — the default card / pill state.
    /// `.hover`     regular material + lemon-tinted overlay — the row *lifts*.
    /// `.selected`  source-tinted material — the mark glows under the glass.
    /// `.floating`  macOS-26 `.glassEffect()` — for chrome that should feel
    ///              like it floats over its parent (action rows, capsules).
    enum GlassElevation { case resting, hover, selected, floating }
}

// MARK: - LemonGlass view modifier
//
// Single source of truth for the liquid-glass treatment. Every chrome surface
// in Lemon — cards, panels, panes, pills — consumes this via `lemonGlass(_:)`
// or `lemonGlassCapsule(_:)`. Console / log surfaces are deliberately
// excluded — those stay solid (`LD.consoleBackground`) so the workspace has
// visual gravity against the surrounding chrome.

struct LemonGlass<S: InsettableShape>: ViewModifier {
    let elevation: LD.GlassElevation
    let tint: Color?
    let shape: S

    func body(content: Content) -> some View {
        switch elevation {
        case .resting:
            content
                .background(.thinMaterial, in: shape)
                .overlay(shape.fill(tint ?? Color.clear))
                .overlay(shape.strokeBorder(LD.glassEdge, lineWidth: 0.5))

        case .hover:
            content
                .background(.regularMaterial, in: shape)
                .overlay(shape.fill(tint ?? LD.glassTintLemon))
                .overlay(shape.strokeBorder(LD.glassEdgeHover, lineWidth: 0.5))

        case .selected:
            // Source-tinted glass — the provider mark whispers under the
            // material instead of stroking a border around it.
            content
                .background(.regularMaterial, in: shape)
                .overlay(shape.fill(tint ?? LD.glassTintLemon))
                .overlay(
                    shape.strokeBorder(
                        (tint ?? LD.lemon).opacity(0.35),
                        lineWidth: 0.5
                    )
                )

        case .floating:
            // For surfaces that should read as hovering over the parent
            // (action rows in editor panes, pills/capsules). Uses
            // ultraThinMaterial + a tinted glaze + a brighter top edge —
            // composes correctly in both the production menubar popover
            // *and* the smoke-test NSHostingView. (Plain `.glassEffect()`
            // requires a window context with Liquid Glass support and
            // renders as opaque white otherwise.)
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.fill(tint ?? Color.clear))
                .overlay(shape.strokeBorder(LD.glassEdgeHover, lineWidth: 0.5))
        }
    }
}

extension View {
    /// Compose a Lemon liquid-glass background for any rounded-rectangle
    /// surface (cards, panels, panes). Defaults to the project's r10 radius
    /// and the resting elevation; pass a tint to source-cast (linearMark,
    /// githubMark, lemon, coral) for selected/connected states.
    func lemonGlass(
        _ elevation: LD.GlassElevation,
        tint: Color? = nil,
        cornerRadius: CGFloat = LD.r10
    ) -> some View {
        modifier(LemonGlass(
            elevation: elevation,
            tint: tint,
            shape: RoundedRectangle(cornerRadius: cornerRadius)
        ))
    }

    /// Capsule-shaped lemon glass — for chips, pills, source glyphs, and
    /// other pill-shaped affordances.
    func lemonGlassCapsule(
        _ elevation: LD.GlassElevation,
        tint: Color? = nil
    ) -> some View {
        modifier(LemonGlass(
            elevation: elevation,
            tint: tint,
            shape: Capsule()
        ))
    }
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
            g: Double((rgb >>  8) & 0xFF) / 255,
            b: Double( rgb        & 0xFF) / 255
        )
    }
}

// MARK: - Session status helpers

extension SessionStatus {
    var color: Color {
        switch self {
        case .planning:  return LD.statusPlanning
        case .executing: return LD.statusExecuting
        case .waiting:   return LD.statusWaiting
        case .reviewing: return LD.statusReviewing
        case .done:      return LD.statusDone
        case .failed:    return LD.statusFailed
        }
    }

    var symbol: String {
        switch self {
        case .planning:  return "brain"
        case .executing: return "hammer.fill"
        case .waiting:   return "pause.circle.fill"
        case .reviewing: return "checklist"
        case .done:      return "checkmark"
        case .failed:    return "xmark"
        }
    }
}

// MARK: - Reusable components

/// A pill-shaped status badge. Reads as a thin sheet of glass with the
/// status colour glowing under it — replaces the old flat opacity-0.12 fill.
struct StatusPill: View {
    let status: SessionStatus

    var body: some View {
        HStack(spacing: 4) {
            if !status.isTerminal {
                Circle()
                    .fill(status.color)
                    .frame(width: 5, height: 5)
                    .modifier(PulseModifier(color: status.color))
            }
            Text(status.displayLabel)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(status.color)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .lemonGlassCapsule(.floating, tint: status.color.opacity(0.12))
    }
}

private struct PulseModifier: ViewModifier {
    let color: Color
    @State private var pulsing = false

    func body(content: Content) -> some View {
        content
            .shadow(color: color.opacity(pulsing ? 0.8 : 0.2), radius: pulsing ? 4 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                    pulsing = true
                }
            }
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
                in: RoundedRectangle(cornerRadius: LD.r6)
            )
            .opacity(configuration.isPressed ? 0.82 : isEnabled ? 1 : 0.35)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(LD.snappy, value: configuration.isPressed)
    }
}

/// Ghosted secondary button.
struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.primary.opacity(configuration.isPressed ? 0.08 : 0.05),
                        in: RoundedRectangle(cornerRadius: LD.r6))
            .animation(LD.snappy, value: configuration.isPressed)
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
        case .linear: return "L"
        case .github: return "gh"
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
        case .linear: return LD.linearMark
        case .github: return LD.githubMark
        }
    }
}

/// Tiny typographic source marker. Width-stable across Linear / GitHub.
struct SourceGlyph: View {
    let source: IssueSource
    var size: CGFloat = 9
    var label: String? = nil  // optional matchKey-style sublabel for inline use

    var body: some View {
        HStack(spacing: 4) {
            Text(source.glyph)
                .font(.system(size: size, weight: .bold, design: .monospaced))
                .kerning(0.4)
                .foregroundStyle(source.accent)
                .frame(minWidth: 14)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .lemonGlassCapsule(.floating, tint: source.accent.opacity(0.10))
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
        case .linear: return "Linear" + (label.map { " · \($0)" } ?? "")
        case .github: return "GitHub" + (label.map { " · \($0)" } ?? "")
        }
    }
}

extension IssueRef {
    /// Human-readable source label used in hover tooltips + a11y.
    var sourceTitle: String {
        switch scope {
        case .linearTeam:
            return "Linear · \(identifierPrefix)"
        case .githubRepo(let owner, let repo, _):
            return "GitHub · \(owner)/\(repo)"
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
