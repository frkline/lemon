import SwiftUI

// The "Gemma idle countdown" (#50). Surfaces the silence-detector state so a
// building session reads as alive: how long the pane has been quiet and when
// Gemma will next classify. Honest by design — a number appears only once
// silence is actually accumulating. The silence timer resets on every pane
// line, so a fill-to-100% ring would jitter backward and read as broken; the
// model is "listening" → a committed countdown only when the pane goes quiet.

/// Full indicator for the session detail view.
struct GemmaIdleIndicator: View {
    let session: Session

    var body: some View {
        if session.status == .executing, let lastActivity = session.lastPaneActivityAt {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let phase = GemmaIdlePhase.resolve(
                    now: context.date,
                    lastActivity: lastActivity,
                    lastGemma: session.lastGemmaClassifyAt,
                )
                HStack(spacing: 6) {
                    Circle()
                        .fill(phase.accent)
                        .frame(width: 5, height: 5)
                        .opacity(phase.dotOpacity)
                    Text(phase.label)
                        .font(.system(size: 10))
                        .foregroundStyle(LD.textSecondary)
                    if let clock = phase.clock {
                        Text(clock)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(phase.accent)
                    }
                    Spacer()
                }
            }
        }
    }
}

/// Compact form for the session row — a single trailing line.
struct GemmaIdleBadge: View {
    let session: Session

    var body: some View {
        if session.status == .executing, let lastActivity = session.lastPaneActivityAt {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let phase = GemmaIdlePhase.resolve(
                    now: context.date,
                    lastActivity: lastActivity,
                    lastGemma: session.lastGemmaClassifyAt,
                )
                HStack(spacing: 4) {
                    Text(phase.shortLabel)
                        .font(.system(size: 9))
                        .foregroundStyle(LD.textTertiary)
                    if let clock = phase.clock {
                        Text(clock)
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(phase.accent)
                    }
                }
            }
        }
    }
}

/// The honest state derived from the silence-detector timing. Mirrors the
/// thresholds in `WorktreeRunner.shouldInvokeGemma` so the UI never lies.
private struct GemmaIdlePhase {
    var label: String
    var shortLabel: String
    var clock: String?
    var accent: Color
    var dotOpacity: Double

    static func resolve(now: Date, lastActivity: Date, lastGemma: Date?) -> GemmaIdlePhase {
        let threshold = WorktreeRunner.gemmaSilenceThreshold
        let cooldown = WorktreeRunner.gemmaCooldown
        let silence = now.timeIntervalSince(lastActivity)

        // Cooling down: Gemma classified recently and won't re-fire until cooldown.
        if let g = lastGemma {
            let since = now.timeIntervalSince(g)
            if since < cooldown {
                return GemmaIdlePhase(
                    label: "Gemma looked just now · ready in",
                    shortLabel: "Gemma ready in",
                    clock: clock(cooldown - since),
                    accent: LD.textTertiary,
                    dotOpacity: 0.4,
                )
            }
        }
        // Pane recently active: listening. No digits — a countdown here would
        // just reset on the next line and read as broken.
        if silence < 15 {
            return GemmaIdlePhase(
                label: "Listening — pane active",
                shortLabel: "Listening",
                clock: nil,
                accent: LD.textTertiary,
                dotOpacity: 0.7,
            )
        }
        // Silence accumulating toward the threshold: the countdown is now honest.
        if silence < threshold {
            let remaining = threshold - silence
            // Lemon ramps in as Gemma is about to act — the one accent here.
            let accent = remaining <= 20 ? LD.lemon : LD.textSecondary
            return GemmaIdlePhase(
                label: "Gemma checks in",
                shortLabel: "Gemma in",
                clock: clock(remaining),
                accent: accent,
                dotOpacity: 1,
            )
        }
        // Past the threshold: Gemma is about to read (or is reading) the screen.
        return GemmaIdlePhase(
            label: "Gemma is reading the screen…",
            shortLabel: "Gemma reading…",
            clock: nil,
            accent: LD.lemon,
            dotOpacity: 1,
        )
    }

    private static func clock(_ interval: TimeInterval) -> String {
        let secs = max(0, Int(interval.rounded()))
        return String(format: "%d:%02d", secs / 60, secs % 60)
    }
}
