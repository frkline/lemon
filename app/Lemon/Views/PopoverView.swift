import SwiftUI
import AppKit

struct PopoverView: View {
    @Environment(Orchestrator.self) private var orchestrator
    @Environment(AppNavigation.self) private var nav
    @State private var pulse = false
    @State private var joinCopied = false

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
                if nav.showingSettings {
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
            .animation(LD.slide, value: nav.showingSettings)
            .animation(LD.slide, value: nav.selectedSession?.id)
            .clipped()
        }
        .frame(width: 480)
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
            // Back chevron — shown in detail or settings panes
            if nav.showingSettings || nav.selectedSession != nil {
                Button {
                    withAnimation(LD.slide) { nav.showList() }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("back-button")
                Spacer().frame(width: 10)
            }

            if nav.showingSettings {
                Text("Settings")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Spacer()
            } else if let session = nav.selectedSession {
                Text(session.issue.identifier)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("detail-identifier")
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
            if orchestrator.sessions.active.isEmpty && orchestrator.sessions.recent.isEmpty {
                emptyState
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        if !orchestrator.sessions.active.isEmpty {
                            sectionLabel("Active")
                            ForEach(orchestrator.sessions.active) { session in
                                SessionRowView(session: session)
                                    .accessibilityIdentifier("session-\(session.issue.identifier)")
                                    .onTapGesture {
                                        withAnimation(LD.slide) { nav.showDetail(session) }
                                    }
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
        VStack(spacing: 5) {
            Text("No active sessions")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Label an issue with 🍋 in Linear to start")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
        .accessibilityIdentifier("empty-state")
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

                Button("Stop") {
                    orchestrator.stopSession(session)
                    withAnimation(LD.slide) { nav.showList() }
                }
                .buttonStyle(LemonButtonStyle(isDestructive: true))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial)
    }

    private func joinSession(_ session: Session) {
        let name = "lemon-\(session.issue.identifier.lowercased())"
        let hasITerm = FileManager.default.fileExists(atPath: "/Applications/iTerm.app")
        if hasITerm {
            let script = "tell application \"iTerm\" to create window with default profile command \"tmux -CC attach -t \(name)\""
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", script]
            try? p.run()
        } else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("tmux attach -t \(name)", forType: .string)
            joinCopied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { joinCopied = false }
        }
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
