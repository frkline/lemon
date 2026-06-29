import AppKit
import SwiftUI

struct PopoverView: View {
    @Environment(Orchestrator.self) private var orchestrator
    @Environment(AppNavigation.self) private var nav

    var body: some View {
        VStack(spacing: 0) {
            // Active work is signalled by the header count badge's done-green
            // dot, not a lemon bar — yellow stays reserved for the one CTA.
            header
            hairline

            ZStack {
                if let identityTarget = nav.editingIdentity {
                    IdentityEditorPane(target: identityTarget)
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .trailing).combined(with: .opacity),
                        ))
                } else if let workspaceTarget = nav.editingWorkspace {
                    WorkspaceEditorPane(target: workspaceTarget)
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .trailing).combined(with: .opacity),
                        ))
                } else if nav.showingSettings {
                    SettingsView()
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .trailing).combined(with: .opacity),
                        ))
                } else if let session = nav.selectedSession {
                    SessionDetailView(session: session)
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .trailing).combined(with: .opacity),
                        ))
                } else {
                    listPane
                        .transition(.asymmetric(
                            insertion: .move(edge: .leading).combined(with: .opacity),
                            removal: .move(edge: .leading).combined(with: .opacity),
                        ))
                }
            }
            // Stable floor so the popover doesn't shrink to a sliver
            // mid-transition (the "just Quit visible" frame). Panes
            // taller than the floor get to grow. No alignment override
            // — the inner pane (listPane → emptyState) handles its
            // own vertical centering via Spacers.
            // minHeight keeps a floor; maxHeight caps the popover so it never
            // grows past the screen and clips under the menu bar. Panes taller
            // than the cap scroll internally (Settings + both editor panes).
            .frame(maxWidth: .infinity, minHeight: 380, maxHeight: 620)
            .animation(LD.slide, value: nav.showingSettings)
            .animation(LD.slide, value: nav.selectedSession?.id)
            .animation(LD.slide, value: nav.editingIdentity)
            .animation(LD.slide, value: nav.editingWorkspace)
            .clipped()
        }
        // Width narrows to the design's single-column popover (was 480).
        // Everything below re-fits to this 340pt column.
        .frame(width: 340)
        // Resize snaps instead of animating — popover height changes
        // were running through SwiftUI's implicit layout animation and
        // pulsed the window noticeably as content swapped. Wrapping the
        // outer VStack in `.animation(nil, value: ...)` for any layout
        // signals is the wrong shape; the cleanest fix is to forbid
        // implicit animation on the container's geometry directly.
        .animation(nil, value: orchestrator.sessions.active.count)
        .animation(nil, value: orchestrator.sessions.recent.count)
        // Popover root = window-level Lemon glass: a behind-window vibrancy
        // backdrop (the only thing that bleeds the desktop on macOS 26) under a
        // low warm tint + hairline + the one shadow. Replaces the opaque
        // material+fill stack that read near-solid.
        .lemonWindowGlass(cornerRadius: LD.r14)
        // Force dark appearance for the whole ported surface tree (detail,
        // settings, both editor panes all descend from here) so native controls
        // — TextField/SecureField text, caret, selection — render light-on-dark.
        // Safe with the transparent backdrop: no opaque background is introduced.
        .environment(\.colorScheme, .dark)
    }

    private var working: Bool {
        !orchestrator.sessions.active.isEmpty
    }

    /// Half-pixel warm divider — the design's `.hr`. Replaces `Divider()`,
    /// which renders a 1pt cool system line.
    private var hairline: some View {
        Rectangle()
            .fill(LD.hairlineDivider)
            .frame(height: LD.hairlineWidth)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 0) {
            // Back chevron — shown in detail / settings / editor panes
            if nav.showingSettings || nav.selectedSession != nil
                || nav.editingIdentity != nil || nav.editingWorkspace != nil
            {
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
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(LD.textTertiary)
                        // ≥28pt hit target, clear of the r14 corner — the bare
                        // 11pt glyph was unhittable jammed against the rounded edge.
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("back-button")
                Spacer().frame(width: 2)
            }

            if nav.editingIdentity != nil {
                titleLabel("Identity")
                Spacer()
            } else if nav.editingWorkspace != nil {
                titleLabel("Workspace")
                Spacer()
            } else if nav.showingSettings {
                titleLabel("Settings")
                Spacer()
            } else if let session = nav.selectedSession {
                HStack(spacing: LD.spaceInlineTight) {
                    SourceFavicon(source: session.issue.source, size: 16)
                        .help(session.issue.sourceTitle)
                    Text(session.issue.identifier)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(LD.textTertiary)
                        .truncationMode(.middle)
                        .lineLimit(1)
                        .accessibilityIdentifier("detail-identifier")
                }
                Spacer()
                StatusPill(status: session.status)
            } else {
                // Logo emoji + wordmark, then the count badge (margin-left auto).
                Text(verbatim: "🍋")
                    .font(.system(size: 15))
                    .padding(.trailing, 6) // breathing room before the wordmark (HStack spacing is 0)
                Text("Lemon")
                    .font(.system(size: 13, weight: .bold))
                    .tracking(-0.1)
                    .foregroundStyle(LD.textPrimary)

                Spacer()

                // Compact status indicator — quiet count badge when healthy.
                if orchestrator.isPolling {
                    LemonSpinner()
                } else if let err = orchestrator.lastPollError {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(LD.coral)
                        .help(err)
                } else if working {
                    countBadge
                }
            }

            Spacer().frame(width: 8)
            Button {
                withAnimation(LD.slide) {
                    if nav.showingSettings { nav.showList() } else { nav.showSettings() }
                }
            } label: {
                Image(systemName: nav.showingSettings ? "gearshape.fill" : "gearshape")
                    .font(.system(size: 11))
                    .foregroundStyle(nav.showingSettings ? LD.lemon : LD.textTertiary)
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("settings-button")
        }
        .padding(.leading, 14)
        .padding(.trailing, 14)
        .padding(.top, 13)
        .padding(.bottom, 11)
        .rise(0)
    }

    private func titleLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .bold))
            .tracking(-0.1)
            .foregroundStyle(LD.textPrimary)
    }

    /// Quiet count badge — warm near-white fill + hairline ring + a done-green
    /// dot. Carries the "N running" signal without spending the yellow.
    private var countBadge: some View {
        let n = orchestrator.sessions.active.count
        return HStack(spacing: 5) {
            Circle()
                .fill(LD.statusDone)
                .frame(width: 5, height: 5)
            Text("\(n) running")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(LD.textSecondary)
        }
        .padding(.horizontal, 9)
        .frame(height: 19)
        .background(LD.textPrimary.opacity(0.07), in: Capsule())
        .overlay(Capsule().strokeBorder(LD.textPrimary.opacity(0.13), lineWidth: LD.hairlineWidth))
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
                        ForEach(Array(orchestrator.sessions.active.enumerated()), id: \.element.id) { idx, session in
                            SessionRowView(session: session)
                                .accessibilityIdentifier("session-\(session.issue.identifier)")
                                .onTapGesture {
                                    withAnimation(LD.slide) { nav.showDetail(session) }
                                }
                                .rise(idx + 1)
                        }
                        if !orchestrator.sessions.recent.isEmpty {
                            sectionLabel("Recent")
                            ForEach(Array(orchestrator.sessions.recent.prefix(8).enumerated()), id: \.element.id) { idx, session in
                                SessionRowView(session: session)
                                    .accessibilityIdentifier("session-\(session.issue.identifier)")
                                    .onTapGesture {
                                        withAnimation(LD.slide) { nav.showDetail(session) }
                                    }
                                    .rise(orchestrator.sessions.active.count + idx + 1)
                            }
                        }
                    }
                    .padding(.vertical, LD.spaceHairline)
                }
                .frame(maxHeight: 340)
            }
            hairline
            listFooter
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .bold))
            .kerning(1.3)
            .foregroundStyle(LD.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.top, LD.spaceHairline)
            .padding(.bottom, 7)
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
                .foregroundStyle(LD.textQuaternary)
            Text("Nothing connected yet")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LD.textSecondary)
            Text("Connect a tracker — Linear or GitHub — and point Lemon at a folder of work.")
                .font(.system(size: 10))
                .foregroundStyle(LD.textTertiary)
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
                .foregroundStyle(LD.textSecondary)
            Text("Label an issue in any of these and Lemon picks it up next poll.")
                .font(.system(size: 10))
                .foregroundStyle(LD.textTertiary)
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
                        .foregroundStyle(LD.textQuaternary)
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
                    .foregroundStyle(LD.textPrimary)
                Text("·")
                    .font(.system(size: 9))
                    .foregroundStyle(LD.textQuaternary)
                Text(surface?.key ?? workspace.routing.surfaceId)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(LD.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .lemonGlass(.thin, cornerRadius: LD.r6)
        .frame(maxWidth: 300)
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
                    .foregroundStyle(LD.textTertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
    }

    /// Surface AI status only when it would help — hide for .ready (green path)
    /// and .notConfigured (user opted out / hasn't set up). Show starting + failed.
    @ViewBuilder
    private var aiStatusBadge: some View {
        switch orchestrator.aiState {
        case .ready, .notConfigured, .idle:
            // .idle = dormant after idle unload (#70); not an error, don't nag.
            EmptyView()
        case .starting:
            HStack(spacing: 6) {
                Text("·").font(.system(size: 10)).foregroundStyle(LD.textQuaternary)
                Text("AI: loading…")
                    .font(.system(size: 10))
                    .foregroundStyle(LD.textSecondary)
                    .help(Text(verbatim: "Loading Gemma into memory; can take 60-90 s on first launch."))
            }
        case let .failed(msg):
            HStack(spacing: 6) {
                Text("·").font(.system(size: 10)).foregroundStyle(LD.textQuaternary)
                Text("AI: error")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(LD.coral)
                    .help(Text(verbatim: msg))
            }
        }
    }

    private var pollDot: some View {
        Circle()
            .fill(orchestrator.isPolling ? LD.statusDone : LD.textTertiary)
            .frame(width: 5, height: 5)
            .opacity(orchestrator.isPolling ? 1 : 0.6)
            .animation(LD.smooth, value: orchestrator.isPolling)
    }

    @ViewBuilder
    private var pollText: some View {
        if orchestrator.isPolling {
            Text("polling…")
                .font(.system(size: 10))
                .foregroundStyle(LD.textSecondary)
        } else if let next = nextPollIn {
            Text("next poll in \(next)s")
                .font(.system(size: 10))
                .foregroundStyle(LD.textTertiary)
        } else {
            Text(orchestrator.lastPolledAt == nil ? "connecting…" : "polling soon")
                .font(.system(size: 10))
                .foregroundStyle(LD.textTertiary)
        }
    }
}

/// Behind-window vibrancy backdrop — the only thing that bleeds the desktop
/// through a macOS-26 `MenuBarExtra(.window)` popover. An `NSVisualEffectView`
/// in `.behindWindow` mode samples the desktop/windows behind the panel;
/// `state = .active` keeps it live when the popover isn't key. It also
/// re-asserts the panel's transparency on every relayout — MenuBarExtra ships an
/// opaque panel and repaints its backing, so a one-shot clear doesn't stick.
struct VibrantBackdrop: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var cornerRadius: CGFloat = LD.r14

    func makeNSView(context _: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.material = material
        view.state = .active
        // Round via maskImage, NOT a SwiftUI .clipShape. System vibrancy
        // materials paint their own bright edge-highlight ("rim"); a SwiftUI clip
        // just moves that rim to the rounded edge (the white line). An alpha
        // maskImage shapes the material before it highlights, so the rim is
        // anti-aliased away. (Research: NSVisualEffectView reverse-engineering +
        // Apple's maskImage docs.)
        view.maskImage = Self.roundedMask(radius: cornerRadius)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context _: Context) {
        view.material = material
        view.maskImage = Self.roundedMask(radius: cornerRadius)
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            // Kill any CALayer border the system panel's content view carries —
            // a second source of the edge line independent of the material rim.
            window.contentView?.wantsLayer = true
            window.contentView?.layer?.borderWidth = 0
        }
    }

    /// Resizable rounded-rect alpha mask for the vibrancy view, with cap insets
    /// so it stretches cleanly to any popover size.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let d = radius * 2 + 1
        let image = NSImage(size: NSSize(width: d, height: d), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

extension View {
    /// Window-level Lemon glass for the popover/onboarding root: a behind-window
    /// vibrancy backdrop (desktop bleed) under a low warm tint, a 0.5pt hairline,
    /// and the one drop shadow — clipped to a continuous rounded rect. Inner
    /// cards keep `.lemonGlass(...)`; this is only for the surface that fills the
    /// panel and meets the desktop.
    func lemonWindowGlass(cornerRadius: CGFloat = LD.r14,
                          material: NSVisualEffectView.Material = .menu) -> some View
    {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        // The vibrancy backdrop rounds ITSELF at the layer (cornerRadius/mask) so
        // its material rim is alpha-clipped — no SwiftUI .clipShape on the material,
        // which would re-introduce a bright edge line. The warm tint is a plain
        // rounded fill (no material → no rim). Drop shadow defines the soft edge.
        return background {
            VibrantBackdrop(material: material, cornerRadius: cornerRadius)
                .overlay(shape.fill(LD.glassWindowTint))
        }
        .shadow(color: LD.popoverShadowColor, radius: LD.popoverShadowRadius, x: 0, y: LD.popoverShadowY)
    }
}
