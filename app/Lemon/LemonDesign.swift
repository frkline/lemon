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
        case .executing: LD.statusExecuting
        case .waiting: LD.statusWaiting
        case .reviewing: LD.statusReviewing
        case .done: LD.statusDone
        case .failed: LD.statusFailed
        }
    }

    var symbol: String {
        switch self {
        case .planning: "brain"
        case .executing: "hammer.fill"
        case .waiting: "pause.circle.fill"
        case .reviewing: "checklist"
        case .done: "checkmark"
        case .failed: "xmark"
        }
    }
}

// MARK: - Reusable components

/// A pill-shaped status badge.
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
        .background(status.color.opacity(0.12), in: Capsule())
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
                in: RoundedRectangle(cornerRadius: LD.r6),
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

/// Tiny typographic source marker. Width-stable across Linear / GitHub.
struct SourceGlyph: View {
    let source: IssueSource
    var size: CGFloat = 9
    var label: String? // optional matchKey-style sublabel for inline use

    var body: some View {
        HStack(spacing: 4) {
            Text(source.glyph)
                .font(.system(size: size, weight: .bold, design: .monospaced))
                .kerning(0.4)
                .foregroundStyle(source.accent)
                .frame(minWidth: 14)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(
                    Capsule()
                        .fill(source.accent.opacity(0.10)),
                )
                .overlay(
                    Capsule().strokeBorder(source.accent.opacity(0.25), lineWidth: 0.5),
                )
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
