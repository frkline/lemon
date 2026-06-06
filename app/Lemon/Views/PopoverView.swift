import SwiftUI
import AppKit

struct PopoverView: View {
    @Environment(Orchestrator.self) private var orchestrator
    @Environment(AppNavigation.self) private var nav
    @State private var pulse = false
    @State private var joinCopied = false
    @State private var stopConfirmingId: UUID? = nil
    @State private var stopConfirmTask: Task<Void, Never>? = nil

    var body: some View {
        VStack(spacing: 0) {
            // 2px lemon bar at the top edge signals active work — no emoji needed
            Rectangle()
                .fill(LD.lemon)
                .frame(height: 2)
                .opacity(working ? 1 : 0)
                .animation(LD.smooth, value: working)

            header
            Divider().opacity(0.4)

            ZStack {
                if let identityTarget = nav.editingIdentity {
                    IdentityEditorPane(target: identityTarget)
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .trailing).combined(with: .opacity)
                        ))
                } else if let workspaceTarget = nav.editingWorkspace {
                    WorkspaceEditorPane(target: workspaceTarget)
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .trailing).combined(with: .opacity)
                        ))
                } else if nav.showingSettings {
                    SettingsView()
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .trailing).combined(with: .opacity)
                        ))
                } else if let session = nav.selectedSession {
                    detailPane(session)
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .trailing).combined(with: .opacity)
                        ))
                } else {
                    listPane
                        .transition(.asymmetric(
                            insertion: .move(edge: .leading).combined(with: .opacity),
                            removal: .move(edge: .leading).combined(with: .opacity)
                        ))
                }
            }
            // Stable floor so the popover doesn't shrink to a sliver
            // mid-transition (the "just Quit visible" frame). Panes
            // taller than the floor get to grow. No alignment override
            // — the inner pane (listPane → emptyState) handles its
            // own vertical centering via Spacers.
            .frame(maxWidth: .infinity, minHeight: 380)
            .animation(LD.slide, value: nav.showingSettings)
            .animation(LD.slide, value: nav.selectedSession?.id)
            .animation(LD.slide, value: nav.editingIdentity)
            .animation(LD.slide, value: nav.editingWorkspace)
            .clipped()
        }
        .frame(width: 480)
        // Resize snaps instead of animating — popover height changes
        // were running through SwiftUI's implicit layout animation and
        // pulsed the window noticeably as content swapped. Wrapping the
        // outer VStack in `.animation(nil, value: ...)` for any layout
        // signals is the wrong shape; the cleanest fix is to forbid
        // implicit animation on the container's geometry directly.
        .animation(nil, value: orchestrator.sessions.active.count)
        .animation(nil, value: orchestrator.sessions.recent.count)
        .background(.regularMaterial)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.3).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }

    private var working: Bool { !orchestrator.sessions.active.isEmpty }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 0) {
            // Back chevron — shown in detail / settings / editor panes
            if nav.showingSettings || nav.selectedSession != nil
                || nav.editingIdentity != nil || nav.editingWorkspace != nil {
                Button {
                    withAnimation(LD.slide) {
                        if nav.editingIdentity != nil || nav.editingWorkspace != nil {
                            nav.popEditor()
                        } else {
                            nav.showList()
                        }
                    }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("back-button")
                Spacer().frame(width: 10)
            }

            if nav.editingIdentity != nil {
                Text("Identity")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Spacer()
            } else if nav.editingWorkspace != nil {
                Text("Workspace")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Spacer()
            } else if nav.showingSettings {
                Text("Settings")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Spacer()
            } else if let session = nav.selectedSession {
                HStack(spacing: 6) {
                    SourceGlyph(source: session.issue.source)
                        .help(session.issue.sourceTitle)
                    Text(session.issue.identifier)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .truncationMode(.middle)
                        .lineLimit(1)
                        .accessibilityIdentifier("detail-identifier")
                }
                Spacer()
                StatusPill(status: session.status)
            } else {
                // Wordmark + live dot when active
                HStack(spacing: 6) {
                    Text("Lemon")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                    if working {
                        Circle()
                            .fill(LD.lemon)
                            .frame(width: 5, height: 5)
                            .shadow(color: LD.lemon.opacity(pulse ? 0.9 : 0.1), radius: pulse ? 5 : 1)
                            .transition(.scale(scale: 0.4).combined(with: .opacity))
                    }
                }
                .animation(LD.smooth, value: working)

                Spacer()

                // Compact status indicator — no verbose text when healthy
                if orchestrator.isPolling {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 12, height: 12)
                        .padding(.trailing, 2)
                } else if let err = orchestrator.lastPollError {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(LD.coral)
                        .help(err)
                } else if working {
                    Text("\(orchestrator.sessions.active.count) active")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(LD.citrus)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(LD.lemon, in: Capsule())
                }
            }

            Spacer().frame(width: 10)
            Button {
                withAnimation(LD.slide) {
                    if nav.showingSettings { nav.showList() } else { nav.showSettings() }
                }
            } label: {
                Image(systemName: nav.showingSettings ? "gearshape.fill" : "gearshape")
                    .font(.system(size: 11))
                    .foregroundStyle(nav.showingSettings ? LD.lemon : .secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("settings-button")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - List pane

    private var listPane: some View {
        VStack(spacing: 0) {
            if orchestrator.sessions.active.isEmpty {
                // Always restore the "Original" empty state when there are no
                // active sessions, even if recent has stopped/done sessions in
                // it. Previously this only fired when BOTH active and recent
                // were empty — stopping the only session left a collapsed
                // single-row state in the popover with no clear "label
                // something to start" guidance. Recent is still surfaced in
                // the detail view if the user navigates back to it.
                emptyState
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        sectionLabel("Active")
                        ForEach(orchestrator.sessions.active) { session in
                            SessionRowView(session: session)
                                .accessibilityIdentifier("session-\(session.issue.identifier)")
                                .onTapGesture {
                                    withAnimation(LD.slide) { nav.showDetail(session) }
                                }
                        }
                        if !orchestrator.sessions.recent.isEmpty {
                            sectionLabel("Recent")
                            ForEach(orchestrator.sessions.recent.prefix(8)) { session in
                                SessionRowView(session: session)
                                    .accessibilityIdentifier("session-\(session.issue.identifier)")
                                    .onTapGesture {
                                        withAnimation(LD.slide) { nav.showDetail(session) }
                                    }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 340)
            }
            Divider().opacity(0.4)
            listFooter
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .bold))
            .kerning(1.0)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 3)
    }

    private var emptyState: some View {
        let keychain = KeychainStore.shared
        let identities = keychain.identities
        let workspaces = keychain.workspaces

        return VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(spacing: 14) {
                if identities.isEmpty || workspaces.isEmpty {
                    // Genuinely nothing connected — point at Settings.
                    unconfiguredEmptyState
                } else {
                    // Configured but no triggers yet — show what's being watched
                    // so the user knows where to tag a 🍋.
                    watchingEmptyState(identities: identities, workspaces: workspaces)
                }
            }
            Spacer(minLength: 0)
        }
        // maxHeight: .infinity makes the empty pane absorb the popover's
        // minHeight floor so the content centers vertically (instead of
        // clumping at the top with the footer floating mid-popover).
        // Quit row pins to the bottom of listPane below this view.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 18)
        .padding(.vertical, 24)
        .accessibilityIdentifier("empty-state")
    }

    private var unconfiguredEmptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.system(size: 22))
                .foregroundStyle(.quaternary)
            Text("Nothing connected yet")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Connect a tracker — Linear or GitHub — and point Lemon at a folder of work.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                withAnimation(LD.slide) { nav.showSettings() }
            } label: {
                Text("Open Settings")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(LD.citrus)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(LD.lemon, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
    }

    private func watchingEmptyState(identities: [Identity], workspaces: [Workspace]) -> some View {
        VStack(spacing: 12) {
            Text("Waiting for a 🍋")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Label an issue in any of these and Lemon picks it up next poll.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 6) {
                ForEach(workspaces.prefix(4)) { ws in
                    watchingRow(workspace: ws, identities: identities)
                }
                if workspaces.count > 4 {
                    Text("+ \(workspaces.count - 4) more")
                        .font(.system(size: 9))
                        .foregroundStyle(.quaternary)
                }
            }
            .padding(.top, 4)
        }
    }

    private func watchingRow(workspace: Workspace, identities: [Identity]) -> some View {
        let identity = identities.first { $0.id == workspace.routing.identityId }
        let surface = identity?.knownSurfaces.first { $0.id == workspace.routing.surfaceId }
        let folder = URL(fileURLWithPath: workspace.path).lastPathComponent
        return HStack(spacing: 8) {
            if let kind = identity?.kind {
                SourceGlyph(source: kind.issueSource, size: 8)
            } else {
                Text("?")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(LD.coral)
                    .padding(.horizontal, 4).padding(.vertical, 2)
                    .background(Capsule().fill(LD.coral.opacity(0.10)))
            }
            HStack(spacing: 4) {
                Text(folder.isEmpty ? "Unnamed" : folder)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("·")
                    .font(.system(size: 9))
                    .foregroundStyle(.quaternary)
                Text(surface?.key ?? workspace.routing.surfaceId)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: 340)
    }

    private var nextPollIn: Int? {
        guard let t = orchestrator.lastPolledAt else { return nil }
        let interval = orchestrator.sessions.active.isEmpty ? 45 : 15
        let remaining = interval - Int(Date().timeIntervalSince(t))
        return remaining > 0 ? remaining : nil
    }

    private var listFooter: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            HStack(spacing: 6) {
                pollDot
                pollText
                aiStatusBadge
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.borderless)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }

    // Surface AI status only when it would help — hide for .ready (green path)
    // and .notConfigured (user opted out / hasn't set up). Show starting + failed.
    @ViewBuilder
    private var aiStatusBadge: some View {
        switch orchestrator.aiState {
        case .ready, .notConfigured:
            EmptyView()
        case .starting:
            HStack(spacing: 6) {
                Text("·").font(.system(size: 10)).foregroundStyle(.quaternary)
                Text("AI: loading…")
                    .font(.system(size: 10))
                    .foregroundStyle(LD.lemon)
                    .help(Text(verbatim: "Loading Gemma into memory; can take 60-90 s on first launch."))
            }
        case .failed(let msg):
            HStack(spacing: 6) {
                Text("·").font(.system(size: 10)).foregroundStyle(.quaternary)
                Text("AI: error")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(LD.coral)
                    .help(Text(verbatim: msg))
            }
        }
    }

    private var pollDot: some View {
        Circle()
            .fill(orchestrator.isPolling ? LD.lemon : Color.secondary)
            .frame(width: 5, height: 5)
            .opacity(orchestrator.isPolling ? 1 : 0.5)
            .animation(LD.smooth, value: orchestrator.isPolling)
    }

    @ViewBuilder
    private var pollText: some View {
        if orchestrator.isPolling {
            Text("polling…")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        } else if let next = nextPollIn {
            Text("next poll in \(next)s")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        } else {
            Text(orchestrator.lastPolledAt == nil ? "connecting…" : "polling soon")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Detail pane

    @ViewBuilder
    private func detailPane(_ session: Session) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(session.issue.title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .lineLimit(2)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.primary.opacity(0.025))

            // Ready-for-review card — shown when handleComplete has
            // landed a Lemon Report and stashed cleanupInfo but the
            // user hasn't fired the cleanup yet. Sits above the console
            // so it's the first thing you see when you click in.
            if session.status == .reviewing, let info = session.cleanupInfo {
                readyForReviewCard(session: session, info: info)
            }

            // Gemma summary — shown when the local model has classified the session.
            if let summary = session.aiSummary {
                HStack(spacing: 5) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 9))
                        .foregroundStyle(LD.consoleGemma)
                    Text(summary)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .background(.primary.opacity(0.015))
            }

            // Pending Gemma action — shown for 5 s before keys are sent.
            if let pending = session.pendingAction {
                HStack(spacing: 6) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 10))
                    Text(pending)
                        .font(.system(size: 10, weight: .medium))
                    Spacer()
                    Button("Cancel") { orchestrator.cancelPendingAction(for: session) }
                        .font(.system(size: 10))
                        .buttonStyle(.borderless)
                }
                .foregroundStyle(LD.lemon)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(LD.lemon.opacity(0.08))
                .transition(.opacity.combined(with: .move(edge: .top)))
                .animation(LD.smooth, value: session.pendingAction)
            }

            inlineConsole(session)
            detailFooter(session)
        }
    }

    @ViewBuilder
    private func readyForReviewCard(session: Session, info: WorktreeCleanupInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(LD.statusDone)
                    .frame(width: 6, height: 6)
                Text("READY FOR REVIEW")
                    .font(.system(size: 9, weight: .bold))
                    .kerning(1.4)
                    .foregroundStyle(LD.statusDone)
                Spacer()
            }
            // Worktree path — monospace, selectable so the user can
            // copy it into a terminal and `cd` over.
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Text(info.sessionPath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack(spacing: 8) {
                if let pr = session.prUrl, let url = URL(string: pr) {
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
        .overlay(
            Rectangle()
                .fill(LD.statusDone.opacity(0.4))
                .frame(width: 2),
            alignment: .leading
        )
    }

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
            .frame(height: 230)
            .background(LD.consoleBackground)
            .onChange(of: session.logLines.count) { _, count in
                withAnimation(LD.smooth) { proxy.scrollTo(count - 1, anchor: .bottom) }
            }
        }
    }

    private func detailFooter(_ session: Session) -> some View {
        HStack(spacing: 10) {
            Group {
                if let t = session.endedAt {
                    Text("ended \(t, style: .relative) ago")
                } else {
                    Text("\(session.startedAt, style: .relative) running")
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)

            if let pr = session.prUrl, let url = URL(string: pr) {
                Link(destination: url) {
                    Label("PR", systemImage: "arrow.triangle.pull")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(LD.lemon)
                }
            }

            Spacer()

            if !session.status.isTerminal {
                Button(joinCopied ? "Copied!" : "Join") {
                    joinSession(session)
                }
                .buttonStyle(GhostButtonStyle())

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
                .buttonStyle(LemonButtonStyle(isDestructive: true))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial)
    }

    private func joinSession(_ session: Session) {
        let name = "lemon-\(session.issue.pathSlug)"
        // The user explicitly clicked Join — they want the window to appear AND
        // come to the front. Try iTerm2 first (tmux -CC native tabs), then
        // Terminal.app (always present), and only fall back to clipboard if
        // both osascript calls error out.
        let hasITerm = FileManager.default.fileExists(atPath: "/Applications/iTerm.app")
        if hasITerm, runOsascript("""
            tell application "iTerm"
                activate
                create window with default profile command "tmux -CC attach -t \(name)"
            end tell
            """) {
            return
        }
        if runOsascript("""
            tell application "Terminal"
                activate
                do script "tmux attach -t \(name)"
            end tell
            """) {
            return
        }
        // Last resort — copy the command for the user to paste themselves.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("tmux attach -t \(name)", forType: .string)
        joinCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { joinCopied = false }
    }

    @discardableResult
    private func runOsascript(_ script: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 }
        catch { return false }
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
