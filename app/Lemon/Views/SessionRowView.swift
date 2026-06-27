import SwiftUI

struct SessionRowView: View {
    let session: Session
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 0) {
            // Body — meta line + title (+ optional PR subtitle). Padding 11/0/12/14
            // per session-row.html. No left accent bar: the status reads from a
            // single colored dot + neutral label so yellow and red stay scarce.
            VStack(alignment: .leading, spacing: 0) {
                metaLine
                    .padding(.bottom, 5)

                Text(session.issue.title)
                    .font(.system(size: 12, weight: .medium))
                    .tracking(-0.1)
                    .foregroundStyle(LD.textPrimary)
                    .lineLimit(1)

                if let pr = session.prUrl {
                    // PR link is NOT lemon — yellow is spent once per screen on
                    // the primary action only. Neutral warm secondary, monospace.
                    Text(pr)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(LD.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.top, 4)
                }
            }
            .padding(EdgeInsets(top: 11, leading: 14, bottom: 12, trailing: 0))

            Spacer(minLength: 0)

            // Chevron owns the right edge — centered, quaternary, pad 0/12.
            if !session.status.isTerminal {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LD.textQuaternary)
                    .padding(.horizontal, 12)
            }
        }
        // Resting leans on the popover's thick glass; hover thickens to the
        // regular-glass warm fill — depth from the material swap, not a stroke.
        .background(hovered ? LD.glassRegularFill : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .animation(LD.smooth, value: hovered)
        // 0.5pt warm hairline between rows (the design's `.hr`), not a 1pt
        // cool system Divider.
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(LD.hairlineDivider)
                .frame(height: LD.hairlineWidth)
        }
    }

    // Meta order: [status dot + neutral label] · favicon(16) · mono id. Gap 7.
    private var metaLine: some View {
        HStack(spacing: 7) {
            statusTag
            SourceFavicon(source: session.issue.source, size: 16)
                .help(session.issue.sourceTitle)
            Text(session.issue.identifier)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(LD.textTertiary)
                .truncationMode(.middle)
                .lineLimit(1)
        }
    }

    // 6px status-colored dot with a soft halo + an 11px/600 label in the
    // neutral warm secondary (NOT the status hue) so the dot carries the color.
    private var statusTag: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(session.status.color)
                .frame(width: 6, height: 6)
                .background(
                    Circle()
                        .fill(session.status.color.opacity(0.18))
                        .frame(width: 11, height: 11),
                )
            Text(session.status.displayLabel)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(LD.textSecondary)
                .fixedSize()
        }
    }
}
