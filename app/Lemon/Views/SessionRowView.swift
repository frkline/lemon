import SwiftUI

struct SessionRowView: View {
    let session: Session
    @State private var hovered = false

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
                    Text(session.issue.identifier)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.tertiary)
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
        .background(hovered ? Color.primary.opacity(0.04) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .animation(LD.smooth, value: hovered)
        .overlay(alignment: .bottom) {
            Divider().padding(.leading, 28)
        }
    }
}
