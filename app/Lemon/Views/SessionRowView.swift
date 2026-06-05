import SwiftUI

struct SessionRowView: View {
    let session: Session
    @State private var hovered = false

    /// Source-cast glass tint for the row. Linear / GitHub each get a faint
    /// hue under the material so the chrome whispers "where this came from"
    /// — the existing left-edge status strip stays as the loud signal.
    private var sourceTint: Color {
        switch session.issue.source {
        case .linear: return LD.glassTintLinear.opacity(0.6)
        case .github: return LD.glassTintGitHub.opacity(0.6)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left accent strip — status color
            RoundedRectangle(cornerRadius: 2)
                .fill(session.status.color)
                .frame(width: 3)
                .padding(.vertical, 8)

            Spacer().frame(width: 11)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    SourceGlyph(source: session.issue.source)
                        .help(session.issue.sourceTitle)
                    Text(session.issue.identifier)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .truncationMode(.middle)
                        .lineLimit(1)
                    Spacer()
                    StatusPill(status: session.status)
                }
                Text(session.issue.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let pr = session.prUrl {
                    Text(pr)
                        .font(.system(size: 10))
                        .foregroundStyle(LD.lemon)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, 10)
            .padding(.trailing, 14)

            if !session.status.isTerminal {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.quaternary)
                    .padding(.trailing, 10)
            }
        }
        // Resting → thinMaterial with a source-tint cast under it.
        // Hover → regularMaterial + lemon highlight; the row lifts as the
        // material thickens. Depth comes from the material swap, not a
        // heavier stroke. Rectangle shapes (not the LemonGlass roundrect
        // variant) because the row sits inside a continuous list.
        .background {
            if hovered {
                Rectangle().fill(.regularMaterial)
                    .overlay(LD.glassTintLemon)
            } else {
                Rectangle().fill(.thinMaterial)
                    .overlay(sourceTint)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .animation(LD.smooth, value: hovered)
        .overlay(alignment: .bottom) {
            Divider().padding(.leading, 28).opacity(0.5)
        }
    }
}
