import AppKit
import SwiftUI

/// The expanded session view: title, optional review/Gemma/pending strips, the
/// opaque live console, and the actions footer. Ported to the Lemon design
/// system — warm token ramp + glass chrome around the ONE surface that stays
/// solid: the console (ethos #4, machine truth). The single yellow on this
/// screen is the primary action (Join / Open terminal); everything else is
/// neutral-warm or coral-quiet.
struct SessionDetailView: View {
    let session: Session

    @Environment(Orchestrator.self) private var orchestrator
    @Environment(AppNavigation.self) private var nav
    @State private var joinCopied = false
    @State private var stopConfirmingId: UUID? = nil
    @State private var stopConfirmTask: Task<Void, Never>? = nil

    var body: some View {
        VStack(spacing: 0) {
            // Title heading — quiet warm strip, system stack (no rounded).
            HStack {
                Text(session.issue.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .tracking(-0.1)
                    .foregroundStyle(LD.textPrimary)
                    .lineLimit(2)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(LD.textPrimary.opacity(0.03))

            // Plan gate — Claude proposed a plan; awaiting human approval.
            if session.status == .planReview {
                planReviewCard(session: session)
            }

            // Result gate — build done; awaiting human go to open the PR.
            if session.status == .resultReview {
                resultReviewCard(session: session)
            }

            // Ready-for-review card — landed Lemon Report awaiting cleanup.
            if session.status == .reviewing, let info = session.cleanupInfo {
                readyForReviewCard(session: session, info: info)
            }

            // Gemma summary — local-model classification of the session.
            if let summary = session.aiSummary {
                HStack(spacing: 5) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 9))
                        .foregroundStyle(LD.consoleGemma)
                    Text(summary)
                        .font(.system(size: 10))
                        .foregroundStyle(LD.textSecondary)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .background(LD.textPrimary.opacity(0.02))
            }

            // Gemma idle countdown — when the next classify fires (#50).
            GemmaIdleIndicator(session: session)
                .padding(.horizontal, 14)
                .padding(.vertical, 4)

            // Pending Gemma action — shown for 5 s before keys are sent. Carries
            // the Gemma teal accent, not the yellow (yellow belongs to the CTA).
            if let pending = session.pendingAction {
                HStack(spacing: 6) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 10))
                        .foregroundStyle(LD.consoleGemma)
                    Text(pending)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(LD.textSecondary)
                    Spacer()
                    Button("Cancel") { orchestrator.cancelPendingAction(for: session) }
                        .font(.system(size: 10))
                        .buttonStyle(.borderless)
                        .foregroundStyle(LD.textTertiary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(LD.textPrimary.opacity(0.05))
                .transition(.opacity.combined(with: .move(edge: .top)))
                .animation(LD.smooth, value: session.pendingAction)
            }

            inlineConsole(session)
            detailFooter(session)
        }
    }

    // MARK: - Plan gate (the human approval before any code is written)

    private func planReviewCard(session: Session) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(LD.statusWaiting)
                    .frame(width: 6, height: 6)
                Text("PLAN — AWAITING APPROVAL")
                    .font(.system(size: 9, weight: .bold))
                    .kerning(1.4)
                    .foregroundStyle(LD.statusWaiting)
                Spacer()
            }
            // The proposed plan, captured from the ExitPlanMode hook. Scrolls
            // inside a short window so the card stays compact.
            ScrollView(showsIndicators: true) {
                Text(session.planMarkdown ?? "Drafting plan…")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(LD.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 132)
            HStack(spacing: 7) {
                // The one yellow on the gate: approve and let it build.
                Button("Approve & run") {
                    orchestrator.resolveGate(session: session, decision: .approve)
                }
                .buttonStyle(DetailPrimaryButtonStyle())
                Button("Request changes") {
                    orchestrator.resolveGate(session: session, decision: .requestChanges)
                }
                .buttonStyle(GhostButtonStyle())
                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(LD.statusWaiting.opacity(0.06))
        .overlay(alignment: .top) {
            Rectangle().fill(LD.hairlineDivider).frame(height: LD.hairlineWidth)
        }
    }

    // MARK: - Result gate (approve before the PR opens)

    private func resultReviewCard(session: Session) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(LD.statusReviewing)
                    .frame(width: 6, height: 6)
                Text("RESULT — READY TO OPEN PR")
                    .font(.system(size: 9, weight: .bold))
                    .kerning(1.4)
                    .foregroundStyle(LD.statusReviewing)
                Spacer()
            }
            if let info = session.cleanupInfo {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 10))
                        .foregroundStyle(LD.textTertiary)
                    Text("lemon/\(info.slug)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(LD.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            HStack(spacing: 7) {
                Button("Open PR") {
                    orchestrator.resolveGate(session: session, decision: .approve)
                }
                .buttonStyle(DetailPrimaryButtonStyle())
                Button("Request changes") {
                    orchestrator.resolveGate(session: session, decision: .requestChanges)
                }
                .buttonStyle(GhostButtonStyle())
                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(LD.statusReviewing.opacity(0.06))
        .overlay(alignment: .top) {
            Rectangle().fill(LD.hairlineDivider).frame(height: LD.hairlineWidth)
        }
    }

    // MARK: - Ready for review

    private func readyForReviewCard(session: Session, info: WorktreeCleanupInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(LD.statusDone)
                    .frame(width: 6, height: 6)
                Text(session.prMerged ? "MERGED — READY TO CLEAN UP" : "READY FOR REVIEW")
                    .font(.system(size: 9, weight: .bold))
                    .kerning(1.4)
                    .foregroundStyle(LD.statusDone)
                Spacer()
            }
            // Worktree path — monospace, selectable to copy into a terminal.
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.system(size: 10))
                    .foregroundStyle(LD.textTertiary)
                Text(info.sessionPath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(LD.textSecondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack(spacing: 8) {
                if let pr = session.prUrl, let url = URL(string: pr) {
                    // The one yellow on the reviewing screen: open the shipped PR.
                    Link(destination: url) {
                        Label("Open PR", systemImage: "arrow.up.right.square")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(LD.lemon)
                }
                Spacer()
                Button {
                    orchestrator.cleanupSession(session)
                    withAnimation(LD.slide) { nav.showList() }
                } label: {
                    Label("Cleanup worktree", systemImage: "trash")
                        .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(GhostButtonStyle())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(LD.statusDone.opacity(0.06))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(LD.hairlineDivider)
                .frame(height: LD.hairlineWidth)
        }
    }

    // MARK: - Console (the ONE opaque surface — ethos #4)

    private func inlineConsole(_ session: Session) -> some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if session.logLines.isEmpty {
                        Text("Starting…")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(LD.consoleText.opacity(0.3))
                            .padding(12)
                    } else {
                        ForEach(Array(session.logLines.enumerated()), id: \.offset) { index, line in
                            ConsoleLineView(line: line).id(index)
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Flexible filler with a bounded max: the console prefers up to 360
            // (so short sessions stay compact, not a giant void) but shrinks down
            // to minHeight when a tall session (reviewing card + summary + console
            // + footer) would otherwise overflow the 620 cap and clip the footer.
            .frame(minHeight: 160, maxHeight: 360)
            .frame(maxWidth: .infinity)
            // Solid, no blur — the machine surface needs visual gravity. r6 box
            // with a faint inset hairline, clipped so output respects the corner.
            .background(LD.consoleBackground)
            .clipShape(RoundedRectangle(cornerRadius: LD.r6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: LD.r6, style: .continuous)
                    .strokeBorder(LD.hairlineOpaque, lineWidth: LD.hairlineWidth),
            )
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .onChange(of: session.logLines.count) { _, count in
                withAnimation(LD.smooth) { proxy.scrollTo(count - 1, anchor: .bottom) }
            }
        }
    }

    // MARK: - Actions footer

    private func detailFooter(_ session: Session) -> some View {
        // Spec `.acts`: actions lead, elapsed pushed to the trailing edge
        // (margin-left:auto). CTAs first so the primary chip anchors the row.
        HStack(spacing: 7) {
            if !session.status.isTerminal {
                // Primary action — the one yellow on this screen. Compact chip
                // (30pt / pad 0-13 / 12-600) so the yellow stays a small,
                // earned moment rather than a loud block. At a gate, the gate
                // card owns the yellow, so Join steps down to a ghost chip to
                // keep one earned yellow per screen.
                if session.status.isGate {
                    Button(joinCopied ? "Copied cmd" : "Join") { joinSession(session) }
                        .buttonStyle(GhostButtonStyle())
                } else {
                    Button(joinCopied ? "Copied cmd" : "Join") { joinSession(session) }
                        .buttonStyle(DetailPrimaryButtonStyle())
                }

                // Quiet-but-unmistakable: coral text on a faint neutral fill,
                // not a loud filled coral block (spec `.btn.stop`).
                Button(stopConfirmingId == session.id ? "Confirm Stop" : "Stop") {
                    if stopConfirmingId == session.id {
                        stopConfirmTask?.cancel()
                        stopConfirmingId = nil
                        orchestrator.stopSession(session)
                        withAnimation(LD.slide) { nav.showList() }
                    } else {
                        withAnimation(LD.snappy) { stopConfirmingId = session.id }
                        stopConfirmTask?.cancel()
                        let sessionId = session.id
                        stopConfirmTask = Task { @MainActor in
                            try? await Task.sleep(for: .seconds(3))
                            guard !Task.isCancelled,
                                  stopConfirmingId == sessionId else { return }
                            withAnimation(LD.smooth) { stopConfirmingId = nil }
                        }
                    }
                }
                .buttonStyle(StopButtonStyle())
            }

            if let pr = session.prUrl, let url = URL(string: pr) {
                Link(destination: url) {
                    Label("PR", systemImage: "arrow.triangle.pull")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(LD.textSecondary)
                }
            }

            Spacer()

            // Elapsed pushed to the trailing edge (spec margin-left:auto).
            Group {
                if let t = session.endedAt {
                    Text("ended \(t, style: .relative) ago")
                } else {
                    Text("\(session.startedAt, style: .relative) running")
                }
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(LD.textTertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(LD.textPrimary.opacity(0.03))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(LD.hairlineDivider)
                .frame(height: LD.hairlineWidth)
        }
    }

    // MARK: - Join (attach to the tmux session)

    private func joinSession(_ session: Session) {
        let name = "lemon-\(session.issue.pathSlug)"
        // Open a real terminal attached to the tmux session. We write a small
        // `.command` launcher and `open` it: this goes through LaunchServices, so
        // it needs NO Automation/AppleEvents TCC permission and brings the
        // terminal to the front. The old `osascript … do script` path required
        // "control Terminal" automation consent — when that wasn't granted it
        // silently failed and dropped to the clipboard, leaving the user staring
        // at a confusing "Copied!" with no window (and no window at all now that
        // sessions launch headless).
        let cmdPath = "/tmp/lemon-join-\(session.issue.pathSlug).command"
        let script = "#!/bin/bash\nexec \(WorktreeRunner.tmuxBase) attach -t \(name)\n"
        if (try? script.write(toFile: cmdPath, atomically: true, encoding: .utf8)) != nil {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: cmdPath,
            )
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = [cmdPath]
            if (try? p.run()) != nil { return }
        }
        // Last resort — copy the attach command so the user can paste it.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("\(WorktreeRunner.tmuxBase) attach -t \(name)", forType: .string)
        joinCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { joinCopied = false }
    }
}

// MARK: - Detail action chips

/// The detail's primary action as a compact chip (spec `.btn.primary`): height
/// 30, pad 0/13, 12pt/600, `LD.lemon` fill + `LD.citrus` text. Scoped here so
/// the shared `LemonButtonStyle` proportions (onboarding / empty-state) stay
/// untouched. Keeps the one yellow small and earned, not a loud block.
struct DetailPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(LD.citrus)
            .frame(height: 30)
            .padding(.horizontal, 13)
            .background(LD.lemon, in: RoundedRectangle(cornerRadius: LD.r6, style: .continuous))
            .opacity(configuration.isPressed ? 0.82 : isEnabled ? 1 : 0.35)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(LD.snappy, value: configuration.isPressed)
    }
}

// MARK: - Stop button style

/// Quiet destructive action: coral *text* on a faint neutral fill + hairline
/// ring (spec `.btn.stop`) — unmistakable but never a loud filled block, so the
/// coral hue stays scarce.
struct StopButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(LD.coral)
            .frame(height: 30)
            .padding(.horizontal, 13)
            .background(LD.textPrimary.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: LD.r6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: LD.r6, style: .continuous)
                    .strokeBorder(LD.textPrimary.opacity(0.11), lineWidth: LD.hairlineWidth),
            )
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(LD.snappy, value: configuration.isPressed)
    }
}

// MARK: - Console line

struct ConsoleLineView: View {
    let line: String

    var body: some View {
        Text(attributedLine)
            .font(.system(size: 11, design: .monospaced))
            .textSelection(.enabled)
            .padding(.vertical, 1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var attributedLine: AttributedString {
        var str = AttributedString(line)
        str.foregroundColor = LD.consoleText

        if line.hasPrefix("[lemon]") {
            if let r = str.range(of: "[lemon]") {
                str[r].foregroundColor = LD.consoleLemon
                str[r].font = .system(size: 11, weight: .semibold, design: .monospaced)
            }
        }
        if line.hasPrefix("[gemma]") {
            if let r = str.range(of: "[gemma]") {
                str[r].foregroundColor = LD.consoleGemma
                str[r].font = .system(size: 11, weight: .semibold, design: .monospaced)
            }
        }
        if line.lowercased().contains("[error]") || line.lowercased().contains("error:") {
            str.foregroundColor = LD.coral
        }
        if line.contains("✓") || line.lowercased().contains("successfully") {
            str.foregroundColor = LD.consoleSage
        }
        return str
    }
}
