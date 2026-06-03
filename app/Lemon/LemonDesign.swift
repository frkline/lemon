import SwiftUI

// MARK: - Design tokens

enum LD {
    // Brand
    static let lemon      = Color(r: 0.969, g: 0.784, b: 0.259)  // #F7C842
    static let lemondrop  = Color(r: 0.996, g: 0.957, b: 0.800)  // pale yellow tint
    static let coral      = Color(r: 1.000, g: 0.420, b: 0.275)  // #FF6B46
    static let citrus     = Color(r: 0.176, g: 0.290, b: 0.118)  // deep citrus green

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
