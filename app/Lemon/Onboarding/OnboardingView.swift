import AppKit
import os
import ServiceManagement
import SwiftUI

// MARK: - Step enum

//
// `trackers` collapses the old `linear` + `workspace` steps into a single
// pane where you pick a source, paste a credential, point at a workspace,
// then optionally "Add another". For repeat passes, an already-verified
// identity becomes a reusable option in the routing list — no need to
// re-paste a credential the user already authenticated.

private enum OnboardingStep: Int, CaseIterable {
    case trackers = 0
    case lemonMd
    case localAI
    case ready
}

// MARK: - Draft pair model

struct DraftPair: Identifiable, Equatable {
    let id = UUID()
    var sourceKind: IssueSource = .linear
    var identityRef: UUID? // existing identity to route through (nil = create new)
    var newIdentityToken: String = ""
    var newIdentityHost: String = ""
    var newIdentityVerified: VerifiedSnapshot?
    var surfaceId: String = ""
    var path: String = ""
    var allReposInFolder: Bool = false
    var homeRepo: String = ""
    var lockdown: Bool = false // #13 trust boundary; recommended for public repos

    struct VerifiedSnapshot: Equatable {
        let identityId: UUID // ID assigned at verify time so later Add-anothers can route back to it
        let handle: String
        let label: String
        let principalId: String
        let surfaces: [Surface]
        let assignedIssueCount: Int
    }

    var isSavable: Bool {
        guard !path.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        guard !surfaceId.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if identityRef != nil { return true }
        return newIdentityVerified != nil
    }
}

// MARK: - Wizard host

struct OnboardingView: View {
    @Binding var isComplete: Bool
    @State private var step: OnboardingStep = .trackers
    @State private var direction: Int = 1

    // Trackers step state — accumulator pattern.
    @State private var savedPairs: [DraftPair] = []
    @State private var verifiedIdentities: [DraftPair.VerifiedSnapshot] = []

    // Legacy state kept only so the smoke-test forced-step initializer +
    // the LemonMd / Ready downstream steps keep working unchanged.
    @State private var linearApiKey = KeychainStore.shared.linearApiKey
    @State private var linearUserId = KeychainStore.shared.linearUserId
    @State private var linearUserName = ""

    @State private var repos: [WorkspaceRepo] = {
        let saved = KeychainStore.shared.workspaceRepos
        return saved.isEmpty ? [WorkspaceRepo(issuePrefix: "", path: "")] : saved
    }()

    var body: some View {
        VStack(spacing: 0) {
            // Persistent header — identical anatomy to the daily popover:
            // 🍋 wordmark on the left, the step rail in the slot the live
            // "N running" count pill occupies once configured. Held fixed
            // outside the content transition so only the body slides.
            header
            hairline

            // Only the step content animates between steps; the shell stays put.
            ZStack {
                stepView
                    .transition(slideTransition)
                    .id(step.rawValue)
            }
            .animation(LD.slide, value: step)
        }
        // 340pt single-column popover — inherits the warm-glass shell instead
        // of the old 520pt light panel, so nothing resizes or recolors when
        // OnboardingView is swapped for PopoverView on finish. A fixed height is
        // required: OnboardingView is shown directly by LemonApp (it does NOT
        // route through PopoverView's min/max-height ZStack), and StepShell's
        // ScrollView is greedy — without a height floor the real menu-bar popover
        // collapses to just the header + footer (the smoke harness forces a fixed
        // window, so it couldn't surface this).
        .frame(width: 340, height: 600)
        // Popover root = window-level Lemon glass (behind-window vibrancy that
        // bleeds the desktop + low warm tint + hairline + shadow). Mirrors
        // PopoverView so onboarding and the daily popover read identically.
        .lemonWindowGlass(cornerRadius: LD.r14)
        // Dark appearance so native fields render light-on-dark; safe with the
        // transparent backdrop (no opaque background introduced).
        .environment(\.colorScheme, .dark)
    }

    /// Persistent wordmark + step rail header.
    private var header: some View {
        HStack(spacing: 8) {
            Text(verbatim: "🍋")
                .font(.system(size: 15))
            Text("Lemon")
                .font(.system(size: 13, weight: .bold))
                .tracking(-0.1)
                .foregroundStyle(LD.textPrimary)
            Spacer()
            StepRail(total: OnboardingStep.allCases.count, current: step.rawValue)
        }
        .padding(.leading, 14)
        .padding(.trailing, 14)
        .padding(.top, 13)
        .padding(.bottom, 11)
        .rise(0)
    }

    /// Half-pixel warm divider — the design's `.hr`.
    private var hairline: some View {
        Rectangle()
            .fill(LD.hairlineDivider)
            .frame(height: LD.hairlineWidth)
    }

    @ViewBuilder
    private var stepView: some View {
        switch step {
        case .trackers:
            TrackersStep(
                savedPairs: $savedPairs,
                verifiedIdentities: $verifiedIdentities,
                onNext: { advance() },
            )
        case .lemonMd:
            LemonMdStep(
                repos: synthesizedRepos,
                onNext: { advance() },
                onBack: { back() },
            )
        case .localAI:
            LocalAIStep(
                onNext: { advance() },
                onBack: { back() },
            )
        case .ready:
            ReadyStep(
                apiKey: linearApiKey,
                onFinish: { finish() },
                onBack: { back() },
            )
        }
    }

    /// Adapter: project the accumulated DraftPairs into the legacy
    /// `[WorkspaceRepo]` shape so LemonMdStep can keep its existing
    /// surface (one LEMON.md per workspace path) without reshuffling.
    private var synthesizedRepos: [WorkspaceRepo] {
        savedPairs.map { pair in
            WorkspaceRepo(
                issuePrefix: pair.surfaceId,
                path: pair.path,
                allReposInFolder: pair.allReposInFolder,
                homeRepo: pair.homeRepo,
            )
        }
    }

    private var slideTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: direction > 0 ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: direction > 0 ? .leading : .trailing).combined(with: .opacity),
        )
    }

    private func advance() {
        // Persist progress for the step we're leaving
        if step == .trackers { persistTrackers() }

        direction = 1
        if let next = OnboardingStep(rawValue: step.rawValue + 1) {
            withAnimation(LD.slide) { step = next }
        } else {
            finish()
        }
    }

    /// Translate the accumulated DraftPairs + verified identities into the
    /// new (Identity, Workspace) storage model. Each verified snapshot
    /// becomes an Identity with its secret in Keychain; each pair becomes
    /// a Workspace pointing at the right identity's UUID. Also seeds the
    /// legacy linearApiKey field so downstream Ready/LemonMd steps that
    /// still read it find something.
    private func persistTrackers() {
        let k = KeychainStore.shared

        // Stamp the migration sentinel up front so the (legacy) workspace
        // → pairs migration doesn't fire and overwrite us on first read.
        k.workspaces = k.workspaces // touches the getter, triggers no-op migration if any

        var identities: [Identity] = []
        for snap in verifiedIdentities {
            // Only persist identities that are actually referenced by at
            // least one saved pair — verified-but-unused gets dropped.
            guard savedPairs.contains(where: { $0.identityRef == snap.identityId
                    || $0.newIdentityVerified?.identityId == snap.identityId
            })
            else { continue }
            let kind: IdentityKind = snap.label.lowercased().contains("github") ? .github : .linear
            let identity = Identity(
                id: snap.identityId,
                kind: kind,
                label: snap.label,
                handle: snap.handle,
                principalId: snap.principalId,
                host: nil,
                knownSurfaces: snap.surfaces,
                surfacesFetchedAt: Date(),
            )
            identities.append(identity)
        }
        k.identities = identities

        // Secrets: only set if we have a fresh token (verifiedIdentities
        // stores the snapshot but tokens live in the DraftPair until save).
        for pair in savedPairs {
            guard let snap = pair.newIdentityVerified else { continue }
            if !pair.newIdentityToken.isEmpty {
                k.setIdentitySecret(pair.newIdentityToken, for: snap.identityId)
            }
        }

        let workspaces: [Workspace] = savedPairs.compactMap { pair in
            let identityId = pair.identityRef ?? pair.newIdentityVerified?.identityId
            guard let identityId else { return nil }
            return Workspace(
                path: pair.path,
                allReposInFolder: pair.allReposInFolder,
                homeRepo: pair.homeRepo,
                routing: Routing(identityId: identityId, surfaceId: pair.surfaceId),
                lockdown: pair.lockdown,
            )
        }
        k.workspaces = workspaces

        // Legacy fallback for code paths that haven't migrated yet.
        if let firstLinear = identities.first(where: { $0.kind == .linear }) {
            k.linearApiKey = k.identitySecret(for: firstLinear.id)
            k.linearUserId = firstLinear.principalId
            linearApiKey = k.linearApiKey
        }
        if let firstGithub = identities.first(where: { $0.kind == .github }) {
            k.githubToken = k.identitySecret(for: firstGithub.id)
            k.githubUser = firstGithub.handle
        }
    }

    private func back() {
        direction = -1
        if let prev = OnboardingStep(rawValue: step.rawValue - 1) {
            withAnimation(LD.slide) { step = prev }
        }
    }

    private func finish() {
        // Trackers already persisted on advance; nothing else to flush.
        withAnimation(LD.smooth) { isComplete = true }
    }
}

#if DEBUG
    extension OnboardingView {
        // stepIndex: 0=trackers, 1=lemonMd, 2=localAI, 3=ready
        init(isComplete: Binding<Bool>, forcedStep stepIndex: Int) {
            // Legacy 5-step indices map cleanly onto the new 4-step shape: 0+1
            // both went into Trackers; 2/3/4 shift down by one.
            let target: OnboardingStep = switch stepIndex {
            case 0, 1: .trackers
            case 2: .lemonMd
            case 3: .localAI
            case 4: .ready
            default: OnboardingStep(rawValue: stepIndex) ?? .trackers
            }
            self._isComplete = isComplete
            self._step = State(initialValue: target)
            self._direction = State(initialValue: 1)
            self._savedPairs = State(initialValue: [])
            self._verifiedIdentities = State(initialValue: [])
            self._linearApiKey = State(initialValue: "lin_api_smoke_key")
            self._linearUserId = State(initialValue: "u_smoke")
            self._linearUserName = State(initialValue: "")
            self._repos = State(initialValue: [WorkspaceRepo(issuePrefix: "LEM", path: "/Users/you/Projects/lemon")])
        }
    }
#endif

// MARK: - Shared shell

//
// The per-step body, rendered inside the persistent OnboardingView header.
// Eyebrow ("SET UP · N OF 4") + SF Pro title + warm-ramp subtitle, then the
// step's controls in a scroll view (panes are scrollable now), then a footer
// shelf with the ghost Back/Quit row and the one lemon CTA.

private struct StepShell<Content: View>: View {
    let stepNumber: Int // 1-based, for the eyebrow
    let title: String
    let subtitle: String
    var backAction: (() -> Void)?
    var nextLabel: String = "Continue"
    var nextEnabled: Bool = true
    // When true the primary CTA renders in ghost style — used when the step's
    // real lemon already lives in the body (e.g. LEMON.md's "Draft with Claude"),
    // so the page never shows two yellows.
    var nextGhost: Bool = false
    var nextAction: () -> Void
    // Optional secondary action — renders adjacent to the primary CTA in the
    // footer in ghost style. Used by TrackersStep ("Add another") + LemonMdStep
    // ("Skip for now") so the action lives in the same row as Continue.
    var addAnotherLabel: String?
    var addAnotherEnabled: Bool = false
    var addAnotherAction: (() -> Void)?
    @ViewBuilder let content: Content

    private var totalSteps: Int {
        OnboardingStep.allCases.count
    }

    var body: some View {
        VStack(spacing: 0) {
            // Scroll the body — tall steps (Ready, Local AI) exceed the
            // popover height; the footer stays pinned below.
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Set up · \(stepNumber) of \(totalSteps)".uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .kerning(1.3)
                        .foregroundStyle(LD.textTertiary)
                        .padding(.bottom, 7)
                        .rise(1)
                    Text(title)
                        .font(.system(size: 16, weight: .bold))
                        .tracking(-0.3)
                        .foregroundStyle(LD.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .rise(1)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(LD.textSecondary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 5)
                        .rise(1)

                    content
                        .padding(.top, 14)
                        .rise(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 14)
            }

            footer
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(LD.hairlineRegular)
                .frame(height: LD.hairlineWidth)
            HStack(spacing: 9) {
                if let back = backAction {
                    Button("Back", action: back)
                        .buttonStyle(GhostButtonStyle())
                } else {
                    Button("Quit") { NSApp.terminate(nil) }
                        .buttonStyle(GhostButtonStyle())
                }
                Spacer()
                if let addLabel = addAnotherLabel, let addAction = addAnotherAction {
                    Button(addLabel, action: addAction)
                        .buttonStyle(GhostButtonStyle())
                        .disabled(!addAnotherEnabled)
                }
                // The single lemon CTA. When disabled it reads as a neutral
                // glass pill (the design's `.btn.disabled`) rather than a faded
                // yellow — so the page's one yellow is only ever spent on a
                // live action.
                if nextGhost {
                    Button(nextLabel, action: nextAction)
                        .buttonStyle(GhostButtonStyle())
                        .disabled(!nextEnabled)
                        .keyboardShortcut(.return, modifiers: .command)
                } else if nextEnabled {
                    Button(nextLabel, action: nextAction)
                        .buttonStyle(LemonButtonStyle())
                        .keyboardShortcut(.return, modifiers: .command)
                } else {
                    Text(nextLabel)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(LD.textTertiary)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .lemonGlass(.thin, cornerRadius: LD.r6)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(LD.footerFill)
        }
        .rise(3)
    }
}

// MARK: - Trackers (replaces Linear + Workspace as one combined step)

//
// One pane, repeatable. Each pass: pick a source (or re-use an identity
// already verified earlier this session), enter the credential the first
// time you connect that source, choose the surface + local path, then
// Add another or Continue.
//
// Identity reuse is the keystone — once you've verified Linear once, the
// second pair shows your existing Linear identity at the top of the
// "Route through" list and skips the credential field entirely.

private struct TrackersStep: View {
    @Binding var savedPairs: [DraftPair]
    @Binding var verifiedIdentities: [DraftPair.VerifiedSnapshot]
    let onNext: () -> Void

    @State private var draft = DraftPair()
    @State private var verifyState: VerifyState = .idle
    @State private var typingCustomSurface = false
    /// Once a pair has been saved this session, the editor collapses into
    /// an "Add another pair" affordance so the page reads as a tidy list
    /// rather than a saved row with a half-filled form below it.
    /// `editorOpen` reflects whether the editor is currently expanded.
    @State private var editorOpen: Bool = true
    @FocusState private var focus: Field?

    enum Field: Hashable { case token, host, path, homeRepo }

    enum VerifyState: Equatable {
        case idle, verifying, ok, failed(String)
    }

    /// Continue advances if EITHER:
    ///   • there's at least one already-saved pair, OR
    ///   • the current draft is complete (Save-on-Continue: nobody should
    ///     have to click "Add another" before "Continue" for the single-pair
    ///     happy path).
    private var canContinue: Bool {
        !savedPairs.isEmpty || draft.isSavable
    }

    private var canAddCurrent: Bool {
        draft.isSavable
    }

    /// Editor is implicitly open whenever there's nothing saved yet —
    /// there's no list to show, the form is the whole page. Once the
    /// first pair lands, the user can collapse it back.
    private var isEditorVisible: Bool {
        savedPairs.isEmpty || editorOpen
    }

    var body: some View {
        StepShell(
            stepNumber: 1,
            title: "Connect your workspace",
            subtitle: "Link where your issues live, then point that identity at the repo it routes on this Mac.",
            nextLabel: continueLabel,
            nextEnabled: canContinue,
            nextAction: { commitDraftIfReadyAndContinue() },
            addAnotherLabel: addAnotherLabelText,
            addAnotherEnabled: addAnotherEnabledFlag,
            addAnotherAction: { handleAddAnother() },
        ) {
            VStack(alignment: .leading, spacing: 18) {
                if !savedPairs.isEmpty { savedPairsList }
                if isEditorVisible {
                    draftSection
                } else {
                    addAnotherPlaceholder
                }
            }
        }
    }

    /// Footer label adapts to context. While the editor is open with a
    /// valid draft and other pairs already exist, the primary action is
    /// explicitly "Save & Continue" so the click-saves-the-draft behavior
    /// doesn't read as a surprise.
    private var continueLabel: String {
        if isEditorVisible, canAddCurrent, !savedPairs.isEmpty { return "Save & Continue" }
        return "Continue"
    }

    /// Secondary button label: with the editor collapsed (>=1 saved
    /// pair, no draft in progress) it offers to open a fresh editor.
    /// With the editor open and a valid draft, it commits the draft and
    /// resets for the next pair.
    private var addAnotherLabelText: String? {
        if isEditorVisible { return "Add another" }
        return "Add another"
    }

    private var addAnotherEnabledFlag: Bool {
        if isEditorVisible { return canAddCurrent }
        return true // collapsed → button just reopens the editor
    }

    private func handleAddAnother() {
        if isEditorVisible {
            withAnimation(LD.snappy) {
                addCurrentToSavedAndReset()
                // Collapse to the placeholder once the pair lands so the
                // page reads as a tidy list. One more click reopens.
                editorOpen = false
            }
        } else {
            withAnimation(LD.snappy) { editorOpen = true }
        }
    }

    private func commitDraftIfReadyAndContinue() {
        if isEditorVisible, canAddCurrent {
            addCurrentToSavedAndReset()
        }
        onNext()
    }

    /// Collapsed editor surface — a single ghost row that reads as a
    /// "create new" affordance. Tap expands the editor back open.
    private var addAnotherPlaceholder: some View {
        Button {
            withAnimation(LD.snappy) { editorOpen = true }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(LD.lemon)
                Text("Add another tracker + workspace")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(LD.textPrimary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 12)
            .background(LD.lemon.opacity(0.04), in: RoundedRectangle(cornerRadius: LD.r10))
            .overlay(
                RoundedRectangle(cornerRadius: LD.r10)
                    .strokeBorder(LD.lemon.opacity(0.22), style: StrokeStyle(lineWidth: 0.5, dash: [3, 3])),
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Saved pairs (already added this session)

    private var savedPairsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("ADDED")
                    .font(.system(size: 9, weight: .bold))
                    .kerning(1.4)
                    .foregroundStyle(LD.textTertiary)
                Text("\(savedPairs.count)")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(LD.textTertiary)
                Spacer()
            }
            VStack(spacing: 6) {
                ForEach(savedPairs) { pair in
                    savedPairRow(pair)
                }
            }
        }
    }

    private func savedPairRow(_ pair: DraftPair) -> some View {
        let identity = identityFor(pair)
        return HStack(spacing: 10) {
            SourceGlyph(source: pair.sourceKind, size: 9)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(identity?.label ?? pair.sourceKind.displayName)
                        .font(.system(size: 11, weight: .semibold))
                    Text("·")
                        .foregroundStyle(LD.textQuaternary)
                    Text(pair.surfaceId)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(LD.textSecondary)
                }
                Text(pair.path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(LD.textTertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
            Button {
                if let idx = savedPairs.firstIndex(where: { $0.id == pair.id }) {
                    savedPairs.remove(at: idx)
                }
            } label: {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(LD.coral.opacity(0.6))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .lemonGlass(.thin, cornerRadius: 8)
    }

    private func identityFor(_ pair: DraftPair) -> DraftPair.VerifiedSnapshot? {
        let id = pair.identityRef ?? pair.newIdentityVerified?.identityId
        return verifiedIdentities.first { $0.identityId == id }
    }

    // MARK: - Draft form

    private var draftSection: some View {
        // Flat editorial layout: each section is an EYEBROW + fields, no
        // nested cards. The whole pane reads as ISSUE TRACKER → REPO/TEAM
        // → WORKSPACE PATH from top to bottom — match the visual rhythm
        // the user already meets at the bottom of the page.
        VStack(alignment: .leading, spacing: 22) {
            issueTrackerSection
            // REPO/TEAM is shown from the start so the user sees the
            // shape of the form up front. The picker is disabled
            // until surfaces load (post-verify).
            surfaceSection
            workspaceSection
        }
    }

    // MARK: ISSUE TRACKER

    private var issueTrackerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            eyebrow("ISSUE TRACKER")
            // If we already have verified identities, the user picks one
            // OR explicitly chooses Connect new. Otherwise the segmented
            // picker is just Linear/GitHub.
            if !verifiedIdentities.isEmpty {
                inlineIdentityPicker
            }
            if draft.identityRef == nil {
                sourceSegmented
                tokenField
                if draft.sourceKind == .github { hostField }
                verifyRow
            }
        }
    }

    /// Compact horizontal identity picker — no boxes, no radio circles.
    /// Each existing identity is a pill; "Connect new" appears as the
    /// final pill.
    private var inlineIdentityPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ForEach(verifiedIdentities, id: \.identityId) { snap in
                    identityPill(snap)
                }
                connectNewPill
                Spacer(minLength: 0)
            }
        }
    }

    private func identityPill(_ snap: DraftPair.VerifiedSnapshot) -> some View {
        let selected = draft.identityRef == snap.identityId
        let kind: IssueSource = snap.label.lowercased().contains("github") ? .github : .linear
        return Button {
            withAnimation(LD.snappy) {
                draft.identityRef = snap.identityId
                draft.sourceKind = kind
                // Auto-pick the first known surface on this identity
                // instead of clearing — matches the verify-success
                // behavior so the REPO/TEAM slot is always pre-filled
                // when there's a sensible default.
                draft.surfaceId = snap.surfaces.first?.id ?? ""
                draft.newIdentityToken = ""
                draft.newIdentityVerified = nil
                verifyState = .idle
            }
        } label: {
            HStack(spacing: 6) {
                SourceMark(source: kind, size: 12)
                Text("@\(snap.handle)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(selected ? LD.textPrimary : LD.textSecondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(
                selected ? AnyShapeStyle(kind.accent.opacity(0.14)) : AnyShapeStyle(LD.glassThinFill),
                in: Capsule(),
            )
            .overlay(
                Capsule().strokeBorder(
                    selected ? kind.accent.opacity(0.40) : LD.hairlineThin,
                    lineWidth: 0.5,
                ),
            )
        }
        .buttonStyle(.plain)
    }

    private var connectNewPill: some View {
        let selected = draft.identityRef == nil
        return Button {
            withAnimation(LD.snappy) {
                draft.identityRef = nil
                if draft.newIdentityVerified == nil { verifyState = .idle }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .semibold))
                Text("Connect new")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(selected ? AnyShapeStyle(LD.lemon) : AnyShapeStyle(LD.textSecondary))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(
                selected ? AnyShapeStyle(LD.lemon.opacity(0.10)) : AnyShapeStyle(Color.clear),
                in: Capsule(),
            )
            .overlay(
                Capsule().strokeBorder(
                    selected ? LD.lemon.opacity(0.32) : LD.lemon.opacity(0.20),
                    style: StrokeStyle(lineWidth: 0.5, dash: selected ? [] : [3, 3]),
                ),
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: REPO / TEAM

    private var surfaceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            eyebrow(draft.sourceKind == .linear ? "TEAM" : "REPO")
            surfacePicker
            // After a surface is chosen, surface the connection's
            // assigned-issue count as concrete proof the right scope is
            // wired up. Comes from the verify snapshot — no extra
            // network call needed.
            if !draft.surfaceId.isEmpty, let count = currentAssignedCount {
                HStack(spacing: 6) {
                    Image(systemName: "tray.full")
                        .font(.system(size: 10))
                        .foregroundStyle(LD.textTertiary)
                    Text("\(count) issue\(count == 1 ? "" : "s") assigned to this credential")
                        .font(.system(size: 10))
                        .foregroundStyle(LD.textTertiary)
                }
            }
        }
    }

    private var currentAssignedCount: Int? {
        if let ref = draft.identityRef,
           let snap = verifiedIdentities.first(where: { $0.identityId == ref })
        {
            return snap.assignedIssueCount
        }
        return draft.newIdentityVerified?.assignedIssueCount
    }

    // MARK: WORKSPACE PATH

    private var workspaceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                eyebrow("WORKSPACE PATH")
                Text("drop a folder or paste a path")
                    .font(.system(size: 9))
                    .foregroundStyle(LD.textQuaternary)
                Spacer()
            }
            pathField
            folderToggle
        }
    }

    // MARK: helpers

    private func eyebrow(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .kerning(1.3)
            .foregroundStyle(LD.textTertiary)
    }

    /// Source picker on the segmented control — a thin-glass track whose
    /// selected segment thickens to the regular tier, with the width-stable
    /// `SourceFavicon` tile per option. Picking a source resets the in-flight
    /// credential.
    private var sourceSegmented: some View {
        LemonSegmented(values: [.linear, .github], selection: Binding(
            get: { draft.sourceKind },
            set: { kind in
                draft.sourceKind = kind
                draft.newIdentityToken = ""
                draft.newIdentityHost = ""
                draft.newIdentityVerified = nil
                verifyState = .idle
            },
        )) { (kind: IssueSource, selected: Bool) in
            HStack(spacing: 6) {
                SourceFavicon(source: kind, size: 16)
                Text(kind.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(selected ? LD.textPrimary : LD.textSecondary)
            }
        }
    }

    private var tokenField: some View {
        // No sub-eyebrow — ISSUE TRACKER already labels the section.
        // The placeholder text inside the SecureField (`lin_api_…`,
        // `ghp_…`) tells you which credential format belongs here, and
        // the "create one ↗" link is right-aligned next to the field
        // for low-friction handoff to the provider.
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                SecureField(draft.sourceKind == .linear ? "lin_api_…" : "ghp_…",
                            text: $draft.newIdentityToken)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .focused($focus, equals: .token)
                    .lemonField(focused: focus == .token)
                    .onChange(of: draft.newIdentityToken) { _, _ in
                        draft.newIdentityVerified = nil
                        verifyState = .idle
                    }
                InlineLink(title: "create one", url: tokenProviderURL)
            }
            Text(tokenProviderHint)
                .font(.system(size: 10))
                .foregroundStyle(LD.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Direct link to the right token creation page per source.
    private var tokenProviderURL: URL {
        switch draft.sourceKind {
        case .linear:
            URL(string: "https://linear.app/settings/api")!
        case .github:
            // Fine-grained PAT page. Lemon needs Issues (read/write) on the
            // repos you want polled; the page lets you scope to specific
            // repos which is the safer default.
            URL(string: "https://github.com/settings/personal-access-tokens/new")!
        }
    }

    private var tokenProviderHint: String {
        switch draft.sourceKind {
        case .linear:
            "Personal API Key. Workspace-scoped; never leaves Keychain."
        case .github:
            // Match GitHub's exact wording from the fine-grained PAT
            // Permissions section so the user can scan for it visually.
            "Required: Issues · Read and write. Pick the repos Lemon should watch."
        }
    }

    private var hostField: some View {
        // Compact host field — placeholder = github.com, hint is the
        // muted "GitHub Enterprise host" cue. No eyebrow; this sits
        // just below the token field inside ISSUE TRACKER.
        TextField("github.com", text: $draft.newIdentityHost)
            .textFieldStyle(.plain)
            .font(.system(size: 12, design: .monospaced))
            .focused($focus, equals: .host)
            .lemonField(focused: focus == .host)
    }

    private var verifyRow: some View {
        let canVerify = !draft.newIdentityToken.isEmpty && verifyState != .verifying
        return HStack(spacing: 10) {
            Button {
                Task { await verify() }
            } label: {
                HStack(spacing: 6) {
                    if verifyState == .verifying {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 10))
                    }
                    Text(verifyState == .verifying ? "Verifying…" : "Verify & sync")
                        .font(.system(size: 12, weight: .semibold))
                }
                // Neutral glass affordance — yellow is reserved for the footer
                // CTA, so Verify reads as a quiet inline action that brightens
                // its text when armed.
                .foregroundStyle(canVerify ? LD.textPrimary : LD.textTertiary)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .lemonGlass(canVerify ? .regular : .thin, cornerRadius: 999)
            }
            .buttonStyle(.plain)
            .disabled(!canVerify)
            .animation(LD.smooth, value: canVerify)

            verifyStateChip
            Spacer()
        }
    }

    @ViewBuilder
    private var verifyStateChip: some View {
        switch verifyState {
        case .ok:
            if let v = draft.newIdentityVerified {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(LD.statusDone)
                    Text("@\(v.handle) · \(v.assignedIssueCount) issue\(v.assignedIssueCount == 1 ? "" : "s") assigned")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(LD.statusDone)
                }
            }
        case let .failed(msg):
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(LD.coral)
                Text(msg).font(.system(size: 10)).foregroundStyle(LD.coral).lineLimit(2)
            }
        default:
            EmptyView()
        }
    }

    /// Surface picker — populated from the chosen identity
    private var currentSurfaceList: [Surface] {
        if let ref = draft.identityRef,
           let snap = verifiedIdentities.first(where: { $0.identityId == ref })
        {
            return snap.surfaces
        }
        return draft.newIdentityVerified?.surfaces ?? []
    }

    private var surfacePicker: some View {
        let count = currentSurfaceList.count
        let enabled = count > 0
        // Placeholder is source-aware and changes shape based on whether
        // the picker is live yet:
        //   • not verified → "Verify your credentials first"
        //   • verified, nothing picked → "Select GitHub issues repo" / "Select Linear team"
        //   • verified, picked → the surfaceId itself
        let placeholder: String = {
            if !enabled {
                return "Verify your credentials first"
            }
            return draft.sourceKind == .github
                ? "Select GitHub issues repo"
                : "Select Linear team"
        }()
        return Menu {
            ForEach(currentSurfaceList) { s in
                Button(action: { draft.surfaceId = s.id }) {
                    Text(s.key.caseInsensitiveCompare(s.displayName) == .orderedSame
                        ? s.displayName
                        : "\(s.key) — \(s.displayName)")
                }
            }
        } label: {
            HStack(spacing: 8) {
                // Typographic glyph — SourceMark (SVG/PNG) bleeds out
                // of its frame inside a Menu's borderless label, which
                // blows up the layout. SourceGlyph is text-based and
                // composes correctly inside the picker.
                SourceGlyph(source: draft.sourceKind, size: 10)
                Text(draft.surfaceId.isEmpty ? placeholder : draft.surfaceId)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(draft.surfaceId.isEmpty ? LD.textSecondary : LD.textPrimary)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9))
                    .foregroundStyle(LD.textTertiary)
            }
            .lemonField(focused: false)
            .contentShape(RoundedRectangle(cornerRadius: LD.r6))
            // Disabled (pre-verify) state must stay legible — the placeholder
            // tells the user what to do next, so don't dim it into the glass.
            .opacity(enabled ? 1 : 0.82)
        }
        .menuStyle(.borderlessButton)
        .disabled(!enabled)
    }

    /// Path field — type or drag a folder onto it. The NSOpenPanel Browse
    /// button was removed because it auto-dismisses the popover when used
    /// from inside the in-app editor; keeping behavior consistent across
    /// onboarding + editor surfaces.
    private var pathField: some View {
        // The eyebrow lives on workspaceSection; this view is just the
        // input + drag-drop affordance.
        VStack(alignment: .leading, spacing: 4) {
            TextField("/path/to/repo", text: $draft.path)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .focused($focus, equals: .path)
                .lemonField(focused: focus == .path)
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    for p in providers {
                        _ = p.loadObject(ofClass: URL.self) { url, _ in
                            if let url, url.hasDirectoryPath {
                                DispatchQueue.main.async { draft.path = url.path }
                            }
                        }
                    }
                    return true
                }
        }
    }

    private var folderToggle: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $draft.allReposInFolder) {
                Text("All repos in this folder")
                    .font(.system(size: 11))
                    .foregroundStyle(LD.textSecondary)
            }
            .toggleStyle(.checkbox)

            if draft.allReposInFolder {
                VStack(alignment: .leading, spacing: 6) {
                    Text("HOME SUBDIR — optional")
                        .font(.system(size: 9, weight: .bold))
                        .kerning(1.3)
                        .foregroundStyle(LD.textTertiary)
                    TextField("e.g. memory", text: $draft.homeRepo)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .focused($focus, equals: .homeRepo)
                        .lemonField(focused: focus == .homeRepo)
                }
                .padding(.leading, 20)
            }

            Toggle(isOn: $draft.lockdown) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Lockdown — trusted author only")
                        .font(.system(size: 11))
                        .foregroundStyle(LD.textSecondary)
                    Text("Only your own issues trigger; others' content stays out of the AI. Recommended for public repos.")
                        .font(.system(size: 9.5))
                        .foregroundStyle(LD.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.checkbox)
        }
        .animation(LD.smooth, value: draft.allReposInFolder)
    }

    // MARK: - Add another

    private func addCurrentToSavedAndReset() {
        // Promote a verified-but-not-yet-saved identity into the global list so
        // the next draft can reuse it without re-verifying.
        if let snap = draft.newIdentityVerified,
           !verifiedIdentities.contains(where: { $0.identityId == snap.identityId })
        {
            verifiedIdentities.append(snap)
        }
        savedPairs.append(draft)
        // Reset draft, default to routing through whatever identity was just
        // used so consecutive workspaces under the same identity are
        // a single click apart.
        let lastIdentity = draft.identityRef ?? draft.newIdentityVerified?.identityId
        draft = DraftPair()
        draft.identityRef = lastIdentity
        verifyState = .idle
    }

    // MARK: - Verify

    private func verify() async {
        verifyState = .verifying
        let kind = draft.sourceKind
        let token = draft.newIdentityToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = draft.newIdentityHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedHost = host.isEmpty ? nil : host

        do {
            let cli = kind == .linear ? (LinearClient() as any IssueSourceClient) : (GitHubClient() as any IssueSourceClient)
            let cred = try await cli.verifyCredential(token: token, host: resolvedHost)
            let surfaces = await (try? cli.listSurfaces(token: token, host: resolvedHost)) ?? []
            let principal: String = (kind == .linear) ? cred.id : cred.handle
            let assignedCount = await (try? cli.countAssignedOpenIssues(
                token: token, host: resolvedHost, principalId: principal,
            )) ?? 0
            let snap = DraftPair.VerifiedSnapshot(
                identityId: UUID(),
                handle: cred.handle,
                label: "\(kind.displayName) · \(cred.displayName)",
                principalId: cred.id,
                surfaces: surfaces,
                assignedIssueCount: assignedCount,
            )
            await MainActor.run {
                draft.newIdentityVerified = snap
                verifyState = .ok
                // Auto-pick the first available surface as soon as we
                // have one — saves the user a click in the common case
                // (single repo / single team) and gives the empty REPO
                // slot something concrete to render. They can still
                // change it via the dropdown.
                if draft.surfaceId.isEmpty, let first = snap.surfaces.first {
                    draft.surfaceId = first.id
                }
            }
        } catch {
            await MainActor.run {
                verifyState = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - Folder picker (NSOpenPanel — only OS surface; everything Lemon-managed stays inside the wizard)

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.title = "Choose workspace folder"
        let cwd: URL = draft.path.isEmpty
            ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Projects")
            : URL(fileURLWithPath: draft.path)
        panel.directoryURL = cwd
        if panel.runModal() == .OK, let url = panel.url {
            draft.path = url.path
        }
    }
}

// MARK: - Step 4: Local AI

enum LocalAI {
    static let swiftLMBuild = "b648"
    static let swiftLMReleaseURL =
        "https://github.com/SharpAI/SwiftLM/releases/download/\(swiftLMBuild)/SwiftLM-\(swiftLMBuild)-macos-arm64.tar.gz"
    static let installCommand = "brew install hf tmux gh claude-code"
}

private struct LocalAIStep: View {
    let onNext: () -> Void
    let onBack: () -> Void

    // Prereq checks
    @State private var toolStatus: [String: Bool] = [:]
    @State private var hfLoginStatus: HFLoginStatus = .unknown
    @State private var checkTimer: Timer?

    // Model download
    @State private var modelSize: ModelSize = .e4b
    @State private var downloadState: DownloadState = .idle
    @State private var downloadProcess: Process?
    @State private var downloadedMB: Int64 = 0
    @State private var downloadTimer: Timer?

    // SwiftLM binary (auto-downloaded from GitHub release)
    @State private var swiftLMPath = KeychainStore.shared.swiftLMPath
    @State private var swiftLMState: SwiftLMState = .idle
    @State private var swiftLMProcess: Process?

    enum HFLoginStatus { case unknown, loggedIn(String), notLoggedIn }
    enum DownloadState: Equatable { case idle, running, done, failed(String) }
    enum SwiftLMState: Equatable { case idle, running, done, failed(String) }

    enum ModelSize: String, CaseIterable, Identifiable {
        case e4b, e2b
        var id: String {
            rawValue
        }

        var hfId: String {
            switch self {
            // Canonical mlx-community 4-bit. OptiQ-4bit variants exist but SwiftLM b648
            // can't load them (k_norm.weight missing at decode time — verified end-to-end
            // on Apple Silicon). Stick with the plain 4-bit quant SwiftLM's README lists.
            case .e4b: "mlx-community/gemma-4-e4b-it-4bit"
            case .e2b: "mlx-community/gemma-4-e2b-it-4bit"
            }
        }

        var dirName: String {
            switch self {
            case .e4b: "gemma-4-e4b-it-4bit"
            case .e2b: "gemma-4-e2b-it-4bit"
            }
        }

        var label: String {
            switch self {
            case .e4b: "4B  (~5.2 GB)"
            case .e2b: "2B  (~3.6 GB)"
            }
        }

        var shortName: String {
            switch self {
            case .e4b: "4B"
            case .e2b: "2B"
            }
        }

        var footprint: String {
            switch self {
            case .e4b: "~5.2 GB"
            case .e2b: "~3.6 GB"
            }
        }

        var approxMB: Int {
            self == .e4b ? 5200 : 3600
        }
    }

    private var modelDir: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Lemon/Models/\(modelSize.dirName)")
            .path
    }

    private var binDir: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Lemon/Bin")
            .path
    }

    private var tmuxOK: Bool {
        toolStatus["tmux"] == true
    }

    private var hfOK: Bool {
        toolStatus["hf"] == true
    }

    private var modelReady: Bool {
        if case .done = downloadState { return true }
        return FileManager.default.fileExists(atPath: modelDir + "/config.json")
    }

    private var swiftLMReady: Bool {
        !swiftLMPath.isEmpty && FileManager.default.isExecutableFile(atPath: swiftLMPath)
    }

    private var canEnable: Bool {
        tmuxOK && modelReady && swiftLMReady
    }

    var body: some View {
        StepShell(
            stepNumber: 3,
            title: "Add the on-device model",
            subtitle: "A small Gemma resolves the obvious prompts so a session doesn’t stall on you.",
            backAction: onBack,
            nextLabel: "Continue",
            nextEnabled: canEnable,
            nextAction: { save(); onNext() },
        ) {
            VStack(spacing: 10) {
                prereqBar
                modelSection
                swiftLMSection
            }
        }
        .onAppear {
            Logger.onboarding.info("LocalAI appeared — modelDir=\(modelDir) swiftLMPath=\(swiftLMPath, privacy: .public) binDir=\(binDir)")
            Logger.onboarding.info("LocalAI state — modelReady=\(modelReady) swiftLMReady=\(swiftLMReady) tmuxOK=\(tmuxOK) hfOK=\(hfOK) canEnable=\(canEnable)")

            if modelReady {
                downloadState = .done
                Logger.onboarding.info("LocalAI: model already on disk at \(modelDir)")
            }
            if swiftLMReady {
                swiftLMState = .done
                Logger.onboarding.info("LocalAI: SwiftLM already configured at \(swiftLMPath, privacy: .public)")
            } else if let recovered = findSwiftLMBinary(in: binDir) {
                // Recover from a prior download where binary discovery failed —
                // the file is on disk but swiftLMPath was never saved.
                Logger.onboarding.info("LocalAI: recovered SwiftLM binary at \(recovered, privacy: .public) — no download needed")
                swiftLMPath = recovered
                swiftLMState = .done
            } else {
                Logger.onboarding.info("LocalAI: no SwiftLM binary on disk at \(binDir) — download required")
            }
            runChecks()
            checkTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
                Task { @MainActor in runChecks() }
            }
        }
        .onDisappear {
            checkTimer?.invalidate()
            downloadTimer?.invalidate()
        }
    }

    // MARK: - Prereq bar

    private var prereqBar: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("REQUIREMENTS")
                .font(.system(size: 9, weight: .bold))
                .kerning(1.3)
                .foregroundStyle(LD.textTertiary)
            HStack(spacing: 6) {
                DependencyChip(label: "tmux", status: chipStatus(toolStatus["tmux"]))
                    .help(toolStatus["tmux"] == false ? LocalAI.installCommand : "")
                DependencyChip(label: "hf", status: chipStatus(toolStatus["hf"]))
                    .help(toolStatus["hf"] == false ? LocalAI.installCommand : "")
                hfLoginPill
                Spacer(minLength: 0)
            }
            if let hint = missingHint {
                Text(hint)
                    .font(.system(size: 10))
                    .foregroundStyle(LD.coral)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
    }

    private func chipStatus(_ present: Bool?) -> DependencyChip.Status {
        switch present {
        case .none: .loading
        case .some(true): .ok
        case .some(false): .attention
        }
    }

    @ViewBuilder
    private var hfLoginPill: some View {
        switch hfLoginStatus {
        case .unknown:
            EmptyView()
        case let .loggedIn(user):
            DependencyChip(label: "hf · \(user)", status: .ok)
        case .notLoggedIn:
            DependencyChip(label: "hf · sign in", status: .attention)
                .help(Text(verbatim: "Run 'hf auth login' if model access requires it."))
        }
    }

    private var missingHint: String? {
        guard toolStatus["tmux"] == false || toolStatus["hf"] == false else { return nil }
        return LocalAI.installCommand
    }

    // MARK: - Model download section

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("GEMMA MODEL")
                    .font(.system(size: 9, weight: .bold))
                    .kerning(0.8)
                    .foregroundStyle(LD.textTertiary)
                Spacer()
                if case .done = downloadState {
                    statusDot(.done, "ready")
                } else if case .running = downloadState {
                    statusDot(.running, "\(downloadedMB) / \(modelSize.approxMB) MB")
                } else if case .failed = downloadState {
                    statusDot(.failed, "error")
                }
            }

            switch downloadState {
            case .idle:
                LemonSegmented(values: ModelSize.allCases, selection: $modelSize) { (size: ModelSize, selected: Bool) in
                    HStack(spacing: 6) {
                        Text(size.shortName)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(selected ? LD.textPrimary : LD.textSecondary)
                        Text(size.footprint)
                            .font(.system(size: 11))
                            .foregroundStyle(LD.textTertiary)
                    }
                }

                Button {
                    startDownload()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle").font(.system(size: 12))
                        Text("Download model & runner").font(.system(size: 12, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(LemonButtonStyle())
                .disabled(!hfOK)

                Text(modelSize.hfId)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(LD.textTertiary)
                    .lineLimit(1).truncationMode(.middle)

            case .running:
                HStack(spacing: 10) {
                    ProgressView(value: Double(downloadedMB), total: Double(modelSize.approxMB))
                        .tint(LD.lemon)
                    Button("Cancel") { cancelDownload() }
                        .buttonStyle(GhostButtonStyle())
                        .font(.system(size: 10))
                }

            case .done:
                Text(modelDir)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(LD.textSecondary)
                    .lineLimit(1).truncationMode(.middle)

            case let .failed(err):
                VStack(alignment: .leading, spacing: 6) {
                    ScrollView {
                        Text(err)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(LD.textSecondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 56)
                    Button("Try Again") { startDownload() }
                        .buttonStyle(GhostButtonStyle())
                        .font(.system(size: 11))
                }
            }
        }
        .padding(10)
        .lemonGlass(.thin, cornerRadius: LD.r10)
    }

    private enum DotState { case running, done, failed }

    private func statusDot(_ state: DotState, _ label: String) -> some View {
        HStack(spacing: 5) {
            switch state {
            case .running:
                Circle().fill(LD.lemon).frame(width: 6, height: 6)
            case .done:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(LD.statusDone).font(.system(size: 10))
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(LD.coral).font(.system(size: 10))
            }
            Text(label)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(LD.textSecondary)
        }
    }

    // MARK: - SwiftLM section

    private var swiftLMSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("SWIFTLM RUNNER")
                    .font(.system(size: 9, weight: .bold))
                    .kerning(0.8)
                    .foregroundStyle(LD.textTertiary)
                Spacer()
                switch swiftLMState {
                case .done: statusDot(.done, "ready")
                case .running: statusDot(.running, "downloading")
                case .failed: statusDot(.failed, "error")
                case .idle: EmptyView()
                }
            }

            switch swiftLMState {
            case .idle:
                HStack(spacing: 8) {
                    Text("SharpAI/SwiftLM b648 · macOS arm64")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(LD.textSecondary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    // Every step keeps at least one yellow. While the model is
                    // still pending, its "Download model & runner" lemon button
                    // owns the step's single yellow and this stays neutral. Once
                    // the model is done, this runner pull IS the primary action
                    // (Continue is disabled until it lands), so it carries the
                    // yellow — otherwise the step would show no CTA at all.
                    let runnerLabel = HStack(spacing: 5) {
                        Image(systemName: "arrow.down.circle").font(.system(size: 11))
                        Text("Download").font(.system(size: 11, weight: .semibold))
                    }
                    if downloadState == .done {
                        Button(action: startSwiftLMDownload) { runnerLabel }
                            .buttonStyle(LemonButtonStyle())
                    } else {
                        Button(action: startSwiftLMDownload) { runnerLabel }
                            .buttonStyle(GhostButtonStyle())
                    }
                }

            case .running:
                HStack(spacing: 10) {
                    ProgressView().scaleEffect(0.6).frame(height: 10)
                    Text("github.com/SharpAI/SwiftLM")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(LD.textSecondary)
                    Spacer()
                    Button("Cancel") { cancelSwiftLMDownload() }
                        .buttonStyle(GhostButtonStyle())
                        .font(.system(size: 10))
                }

            case .done:
                Text(swiftLMPath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(LD.textSecondary)
                    .lineLimit(1).truncationMode(.middle)

            case let .failed(err):
                VStack(alignment: .leading, spacing: 6) {
                    ScrollView {
                        Text(err)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(LD.textSecondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 56)
                    Button("Try Again") { startSwiftLMDownload() }
                        .buttonStyle(GhostButtonStyle())
                        .font(.system(size: 11))
                }
            }
        }
        .padding(10)
        .lemonGlass(.thin, cornerRadius: LD.r10)
    }

    // MARK: - Actions

    private func runChecks() {
        for tool in ["tmux", "hf"] {
            Task.detached {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/zsh")
                p.arguments = ["-l", "-c", "cd /tmp && which \(tool)"]
                let outPipe = Pipe()
                p.standardOutput = outPipe
                p.standardError = Pipe()
                try? p.run(); p.waitUntilExit()
                let present = p.terminationStatus == 0
                let path = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                Logger.onboarding.info("LocalAI prereq \(tool): present=\(present) path=\(path, privacy: .public)")
                await MainActor.run { toolStatus[tool] = present }
            }
        }

        Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-l", "-c", "cd /tmp && hf auth whoami 2>/dev/null | head -1"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = Pipe()
            try? p.run(); p.waitUntilExit()
            let raw = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let status: HFLoginStatus = raw.isEmpty ? .notLoggedIn : .loggedIn(raw)
            Logger.onboarding.info("LocalAI hf auth whoami: exit=\(p.terminationStatus) raw=\(raw, privacy: .public)")
            await MainActor.run { hfLoginStatus = status }
        }
    }

    private func startDownload() {
        let dir = modelDir
        let hfId = modelSize.hfId
        Logger.onboarding.info("startDownload: hfId=\(hfId) dir=\(dir) modelSize=\(modelSize.rawValue)")
        downloadState = .running

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-l", "-c",
                       "cd /tmp && hf download \(hfId)" +
                           " --local-dir '\(dir)' 2>&1"]
        let outPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = outPipe

        downloadProcess = p

        // Poll directory size every 2s for progress
        downloadTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor in
                downloadedMB = dirSizeMB(dir)
                if modelReady, downloadState == .running {
                    downloadState = .done
                    downloadTimer?.invalidate()
                }
            }
        }

        Task.detached {
            do {
                try p.run()
                p.waitUntilExit()
                let output = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                Logger.onboarding.info("hf download exit \(p.terminationStatus), output=\(trimmed.suffix(800))")
                await MainActor.run {
                    downloadTimer?.invalidate()
                    if p.terminationStatus == 0 || modelReady {
                        downloadState = .done
                    } else {
                        let tail = String(trimmed.suffix(400))
                        let detail = tail.isEmpty
                            ? "exit \(p.terminationStatus) — try 'hf auth login' if the model is gated"
                            : tail
                        downloadState = .failed(detail)
                    }
                }
            } catch {
                await MainActor.run {
                    downloadTimer?.invalidate()
                    downloadState = .failed(error.localizedDescription)
                }
            }
        }
    }

    private func cancelDownload() {
        downloadProcess?.terminate()
        downloadProcess = nil
        downloadTimer?.invalidate()
        downloadState = .idle
        downloadedMB = 0
    }

    private func dirSizeMB(_ path: String) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(atPath: path) else { return 0 }
        var total: Int64 = 0
        for case let file as String in enumerator {
            let full = (path as NSString).appendingPathComponent(file)
            if let attrs = try? FileManager.default.attributesOfItem(atPath: full),
               let size = attrs[.size] as? Int64
            {
                total += size
            }
        }
        return total / 1_048_576
    }

    private func startSwiftLMDownload() {
        let dir = binDir
        let url = LocalAI.swiftLMReleaseURL

        // Short-circuit: if the binary is already on disk (from a prior partial run
        // where path persistence didn't land), just use it.
        if let existing = findSwiftLMBinary(in: dir) {
            Logger.onboarding.info("startSwiftLMDownload: binary already present at \(existing, privacy: .public), skipping download")
            swiftLMPath = existing
            swiftLMState = .done
            return
        }

        Logger.onboarding.info("startSwiftLMDownload: url=\(url) dir=\(dir)")
        swiftLMState = .running

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // -sS makes curl silent except errors → avoids the progress-bar firehose
        // that overflows the Pipe buffer and deadlocks the process.
        p.arguments = ["-l", "-c", """
        cd /tmp && \
        mkdir -p '\(dir)' && \
        curl -fLsS '\(url)' -o '\(dir)/swiftlm.tar.gz' 2>&1 && \
        tar -xzf '\(dir)/swiftlm.tar.gz' -C '\(dir)' 2>&1 && \
        rm -f '\(dir)/swiftlm.tar.gz' && \
        echo "extract-ok"
        """]
        let outPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = outPipe
        swiftLMProcess = p

        Task.detached {
            do {
                try p.run()
                p.waitUntilExit()
                let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                Logger.onboarding.info("startSwiftLMDownload exit=\(p.terminationStatus) bytes=\(out.utf8.count) tail=\(out.suffix(400), privacy: .public)")

                let foundPath = findSwiftLMBinary(in: dir)
                Logger.onboarding.info("startSwiftLMDownload findBinary in \(dir): \(foundPath ?? "nil", privacy: .public)")

                if p.terminationStatus == 0, let found = foundPath {
                    await MainActor.run {
                        swiftLMPath = found
                        swiftLMState = .done
                    }
                } else {
                    let tail = out.trimmingCharacters(in: .whitespacesAndNewlines).suffix(400)
                    let listing = (try? FileManager.default.contentsOfDirectory(atPath: dir).joined(separator: "\n")) ?? "(unreadable)"
                    Logger.onboarding.error("startSwiftLMDownload failed — dir listing:\n\(listing, privacy: .public)")
                    let detail = tail.isEmpty
                        ? "Couldn't locate the SwiftLM binary in \(dir) after extraction.\nContents:\n\(listing)"
                        : "\(String(tail))\n\nContents of \(dir):\n\(listing)"
                    await MainActor.run { swiftLMState = .failed(detail) }
                }
            } catch {
                Logger.onboarding.error("startSwiftLMDownload threw: \(error.localizedDescription)")
                await MainActor.run { swiftLMState = .failed(error.localizedDescription) }
            }
        }
    }

    private func cancelSwiftLMDownload() {
        swiftLMProcess?.terminate()
        swiftLMProcess = nil
        swiftLMState = .idle
    }

    private nonisolated func findSwiftLMBinary(in dir: String) -> String? {
        let fm = FileManager.default
        let candidateNames: Set = ["SwiftLM", "swiftlm", "swift-lm", "SwiftLM-cli"]
        guard let enumerator = fm.enumerator(atPath: dir) else { return nil }
        for case let rel as String in enumerator {
            let name = (rel as NSString).lastPathComponent
            guard candidateNames.contains(name) else { continue }
            let full = (dir as NSString).appendingPathComponent(rel)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue else { continue }
            if fm.isExecutableFile(atPath: full) { return full }
        }
        return nil
    }

    private func save() {
        guard canEnable else {
            Logger.onboarding.info("LocalAI save skipped — canEnable=false (tmuxOK=\(tmuxOK) modelReady=\(modelReady) swiftLMReady=\(swiftLMReady))")
            return
        }
        let k = KeychainStore.shared
        k.modelPath = modelDir
        k.swiftLMPath = swiftLMPath
        k.aiEnabled = true
        Logger.onboarding.info("LocalAI save: aiEnabled=true modelPath=\(modelDir) swiftLMPath=\(swiftLMPath, privacy: .public)")
    }
}

// MARK: - Step 3: Ready

private struct ReadyStep: View {
    let apiKey: String
    let onFinish: () -> Void
    let onBack: () -> Void

    @State private var claudeAccount: String? = nil
    @State private var claudeChecked = false
    @State private var launchAtLogin = (SMAppService.mainApp.status == .enabled)
    @State private var terminalAutomation: TerminalAutomationState = .checking

    enum TerminalAutomationState: Equatable {
        case checking
        case granted
        case denied(String) // app name that was denied
    }

    enum LabelState { case pending, creating, done(Int), failed(String) }
    @State private var labelState: LabelState = .pending

    /// The 🍋 labels (Tag it / In Progress / Waiting / Complete) are the
    /// protocol Lemon listens for. Without them, nothing the user does
    /// post-onboarding will register. So Continue is gated on
    /// `.done` — pending/creating block (work in flight) and `.failed`
    /// surfaces a Retry instead of letting the user advance into a
    /// broken state.
    private var canStart: Bool {
        guard claudeChecked else { return false }
        if case .done = labelState { return true }
        return false
    }

    private var labelsReady: Bool {
        if case .done = labelState { return true }
        return false
    }

    var body: some View {
        StepShell(
            stepNumber: 4,
            title: "You’re all set",
            subtitle: "This is the loop you’ll drive from your tracker.",
            backAction: onBack,
            nextLabel: "Start Lemon",
            nextEnabled: canStart,
            nextAction: onFinish,
        ) {
            VStack(spacing: 9) {
                // Claude auth status
                statusRow(
                    checked: claudeChecked,
                    pendingText: "Detecting Claude Code auth…",
                    successIcon: "checkmark.circle.fill",
                    successTitle: claudeAccount.map { "Using Claude Code as \($0)" } ?? "Using Claude Code",
                    successColor: LD.statusDone,
                    warningTitle: "Claude Code not authenticated",
                    warningDetail: "Run `claude login` in Terminal, then come back.",
                )

                // Linear labels + workflow education
                linearLabelsRow

                // GitHub Issues hint — only shown when the user hasn't
                // already connected a GitHub identity. Once GitHub is in
                // play the card is just noise.
                if !KeychainStore.shared.identities.contains(where: { $0.kind == .github }) {
                    githubHintRow
                }

                // Launch at login — quiet opt-in; Lemon is workflow tooling
                // for a dedicated Mac, so this is the recommended default for
                // anyone running it on a Mac mini.
                launchAtLoginRow

                // Surfaces if user clicked "Don't Allow" on the Terminal/iTerm
                // automation prompt. Hidden in the happy path.
                terminalAutomationRow
            }
        }
        .onAppear {
            detectClaudeAuth()
            createLabels()
            preauthorizeTerminalAutomation()
        }
    }

    /// Trigger the macOS Apple Events authorization dialog for Terminal.app
    /// (and iTerm2 if installed) at onboarding time, so the user clicks Allow
    /// while they're at their desk. Without this, the dialog fires the first
    /// time a 🍋 session tries to open a terminal window — exactly when the
    /// user is most likely AFK, and the session sits blocked forever.
    ///
    /// Also detects "Don't Allow" so we can surface a fallback path
    /// (System Settings → Privacy & Security → Automation) instead of
    /// silently failing to open windows later.
    private func preauthorizeTerminalAutomation() {
        Task.detached {
            var apps = ["Terminal"]
            if FileManager.default.fileExists(atPath: "/Applications/iTerm.app") {
                apps.append("iTerm")
            }
            var deniedApp: String? = nil
            for app in apps {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                p.arguments = ["-e", "tell application \"\(app)\" to count windows"]
                p.standardOutput = Pipe()
                let errPipe = Pipe()
                p.standardError = errPipe
                try? p.run(); p.waitUntilExit()
                Logger.onboarding.info("Pre-auth \(app) AppleEvents: exit=\(p.terminationStatus)")
                // osascript returns non-zero AND stderr contains "Not authorized"
                // when the user clicks Don't Allow (or has denied in Settings).
                if p.terminationStatus != 0 {
                    let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    if err.contains("authorized") || err.contains("1743") {
                        deniedApp = app
                        break
                    }
                }
            }
            await MainActor.run {
                if let app = deniedApp {
                    terminalAutomation = .denied(app)
                } else {
                    terminalAutomation = .granted
                }
            }
        }
    }

    @ViewBuilder
    private var terminalAutomationRow: some View {
        switch terminalAutomation {
        case .checking, .granted:
            EmptyView()
        case let .denied(app):
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(LD.coral).font(.system(size: 16))
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(app) automation denied")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Lemon needs to open \(app) to show running sessions. Without this, sessions still run (detached tmux) but no window appears.")
                        .font(.system(size: 11)).foregroundStyle(LD.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
                        NSWorkspace.shared.open(url)
                    } label: {
                        HStack(spacing: 3) {
                            Text("Open Privacy & Security → Automation")
                                .font(.system(size: 11, weight: .medium))
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 8, weight: .bold))
                        }
                        .foregroundStyle(LD.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                }
                Spacer()
            }
            .padding(12)
            .background(LD.coral.opacity(0.08), in: RoundedRectangle(cornerRadius: LD.r10))
        }
    }

    // MARK: - GitHub hint

    private var githubHintRow: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .foregroundStyle(LD.statusDone).font(.system(size: 13))
            VStack(alignment: .leading, spacing: 2) {
                Text("Also use GitHub Issues?")
                    .font(.system(size: 11, weight: .semibold))
                Text("Add a GitHub PAT + an owner/repo pair in Settings after launch. Same 🍋 labels, same comment loop.")
                    .font(.system(size: 10))
                    .foregroundStyle(LD.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(12)
        .background(LD.statusDone.opacity(0.06), in: RoundedRectangle(cornerRadius: LD.r10))
    }

    // MARK: - Label creation + workflow education

    private var linearLabelsRow: some View {
        VStack(spacing: 0) {
            // Status header
            HStack(spacing: 8) {
                switch labelState {
                case .pending:
                    ProgressView().scaleEffect(0.6).frame(width: 14, height: 14)
                    Text("Preparing 🍋 labels…")
                        .font(.system(size: 11)).foregroundStyle(LD.textSecondary)
                case .creating:
                    ProgressView().scaleEffect(0.6).frame(width: 14, height: 14)
                    Text("Creating 🍋 labels in your trackers…")
                        .font(.system(size: 11)).foregroundStyle(LD.textSecondary)
                case let .done(count):
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(LD.statusDone).font(.system(size: 13))
                    Text("🍋 labels created in \(count) place\(count == 1 ? "" : "s")")
                        .font(.system(size: 11, weight: .semibold))
                case let .failed(err):
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(LD.coral).font(.system(size: 13))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Couldn't create 🍋 labels")
                            .font(.system(size: 11, weight: .semibold))
                        Text(err)
                            .font(.system(size: 10))
                            .foregroundStyle(LD.textSecondary)
                            .lineLimit(2).truncationMode(.tail)
                    }
                    Spacer(minLength: 8)
                    Button("Retry") { createLabels() }
                        .buttonStyle(GhostButtonStyle())
                        .controlSize(.small)
                }
                if case .failed = labelState { } else { Spacer() }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Rectangle().fill(LD.hairlineDivider).frame(height: LD.hairlineWidth)
                .padding(.horizontal, 8)

            // Workflow pipeline — teaches lifecycle even while loading
            VStack(spacing: 0) {
                workflowRow("🍋", nil, "Tag it", "Add to any issue to queue it for Lemon", LD.lemon, false)
                workflowRow("🍋", "In Progress", "Working", "Claude opens Terminal and gets to work", LD.statusPlanning, false)
                workflowRow("🍋", "Waiting", "Needs you", "Claude paused — phone notification sent", LD.statusWaiting, false)
                workflowRow("🍋", "Complete", "PR open", "Reply to the Lemon comment to request changes", LD.statusDone, true)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .opacity(labelsReady ? 1.0 : 0.45)
            .animation(LD.smooth, value: labelsReady)
        }
        .lemonGlass(.thin, cornerRadius: LD.r10)
    }

    private func workflowRow(_ emoji: String, _ name: String?, _ action: String, _ detail: String, _ color: Color, _ isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(color)
                    .frame(width: 3, height: 14)
                if !isLast {
                    Rectangle()
                        .fill(LD.textPrimary.opacity(0.1))
                        .frame(width: 1, height: 16)
                }
            }
            .padding(.top, 5)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    HStack(spacing: 2) {
                        Text(emoji).font(.system(size: 9))
                        if let n = name {
                            Text(n).font(.system(size: 9, weight: .medium))
                                .foregroundStyle(LD.textSecondary)
                        }
                    }
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(color.opacity(0.15), in: Capsule())

                    Image(systemName: "arrow.right")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(LD.textTertiary)

                    // Status lives in the rail + tag wash; the action word stays
                    // warm-neutral so the legend reads as one color family.
                    Text(action)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(LD.textPrimary)
                }
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(LD.textSecondary)
            }
            Spacer()
        }
        .padding(.vertical, 3)
    }

    // MARK: - Generic status row

    private func statusRow(
        checked: Bool,
        pendingText: String,
        successIcon: String,
        successTitle: String,
        successColor: Color,
        warningTitle: String,
        warningDetail: String,
    ) -> some View {
        Group {
            if !checked {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.65)
                    Text(pendingText).font(.system(size: 12)).foregroundStyle(LD.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .lemonGlass(.thin, cornerRadius: LD.r10)
            } else if claudeAccount != nil {
                HStack(spacing: 10) {
                    Image(systemName: successIcon).foregroundStyle(successColor).font(.system(size: 16))
                    Text(successTitle).font(.system(size: 12, weight: .semibold))
                    Spacer()
                }
                .padding(14)
                .background(successColor.opacity(0.08), in: RoundedRectangle(cornerRadius: LD.r10))
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(LD.coral).font(.system(size: 16))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(warningTitle).font(.system(size: 12, weight: .semibold))
                        Text(warningDetail).font(.system(size: 11)).foregroundStyle(LD.textSecondary)
                    }
                    Spacer()
                }
                .padding(14)
                .background(LD.coral.opacity(0.08), in: RoundedRectangle(cornerRadius: LD.r10))
            }
        }
    }

    // MARK: - Launch at login

    private var launchAtLoginRow: some View {
        HStack(spacing: 10) {
            // Neutral icon — state is carried by the green switch, keeping the
            // page's one yellow on the footer CTA.
            iconBox("power.circle.fill", tint: launchAtLogin ? LD.statusDone : LD.textTertiary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Launch at login").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(LD.textPrimary)
                Text("Recommended if Lemon lives on a Mac that stays on")
                    .font(.system(size: 11)).foregroundStyle(LD.textSecondary)
            }
            Spacer()
            Toggle("", isOn: $launchAtLogin)
                .labelsHidden()
                .tint(LD.statusDone)
                .onChange(of: launchAtLogin) { _, enabled in
                    do {
                        if enabled { try SMAppService.mainApp.register() }
                        else { try SMAppService.mainApp.unregister() }
                    } catch {
                        Logger.onboarding.error("SMAppService toggle failed: \(error.localizedDescription)")
                        launchAtLogin = (SMAppService.mainApp.status == .enabled)
                    }
                }
        }
        .padding(14)
        .lemonGlass(.thin, cornerRadius: LD.r10)
    }

    private func iconBox(_ systemName: String, tint: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: LD.r6)
                .fill(tint.opacity(0.12))
                .frame(width: 28, height: 28)
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint)
        }
    }

    // MARK: - Label creation

    //
    // Walks the persisted (Identity, Workspace) pairs and bootstraps the
    // four 🍋 labels in each routed surface. One Linear team and one
    // GitHub repo each count as one "scope". Failures of individual
    // scopes don't abort the others — the user sees an aggregated
    // result and can hit Retry if anything failed.

    private func createLabels() {
        labelState = .creating
        Task.detached {
            let keychain = KeychainStore.shared
            let workspaces = keychain.workspaces
            // Deduplicate by (identityId, surfaceId) so two workspaces
            // routed to the same team/repo don't double-bootstrap.
            var seenScopes = Set<String>()
            var scopes: [(identity: Identity, surfaceId: String)] = []
            for ws in workspaces {
                let key = "\(ws.routing.identityId.uuidString)/\(ws.routing.surfaceId)"
                guard !seenScopes.contains(key) else { continue }
                seenScopes.insert(key)
                guard let identity = keychain.identity(for: ws) else { continue }
                scopes.append((identity, ws.routing.surfaceId))
            }

            let linear = LinearClient()
            let github = GitHubClient()
            var okCount = 0
            var firstError: String?

            for (identity, surfaceId) in scopes {
                guard let auth = keychain.authFor(identity: identity) else {
                    if firstError == nil { firstError = "Missing credential for \(identity.label)" }
                    continue
                }
                let cli: any IssueSourceClient = (identity.kind == .linear) ? linear : github
                let config = switch identity.kind {
                case .linear:
                    SourceConfig(
                        source: .linear, displayName: identity.label,
                        linearTeamKeys: [surfaceId], githubRepos: nil,
                    )
                case .github:
                    SourceConfig(
                        source: .github, displayName: identity.label,
                        linearTeamKeys: nil, githubRepos: [surfaceId],
                    )
                }
                do {
                    try await cli.bootstrapLabels(config: config, auth: auth)
                    okCount += 1
                } catch {
                    Logger.onboarding.error("Bootstrap \(identity.label)/\(surfaceId) failed: \(error.localizedDescription)")
                    if firstError == nil { firstError = error.localizedDescription }
                }
            }

            await MainActor.run {
                if scopes.isEmpty {
                    labelState = .failed("No workspaces are configured. Go back and add one.")
                } else if let err = firstError, okCount == 0 {
                    labelState = .failed(err)
                } else {
                    // Partial success (some scopes failed) still advances —
                    // the user has at least one working surface and can
                    // fix the rest in Settings.
                    labelState = .done(okCount)
                }
            }
        }
    }

    // MARK: - Claude auth

    private func detectClaudeAuth() {
        Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-l", "-c", "cd /tmp && claude whoami 2>/dev/null | head -1"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = Pipe()
            try? p.run(); p.waitUntilExit()

            var account: String? = nil
            if p.terminationStatus == 0 {
                let raw = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "`"))
                if let raw, !raw.isEmpty { account = raw }
            }

            await MainActor.run {
                claudeAccount = account
                claudeChecked = true
            }
        }
    }
}

// MARK: - Step 3: LEMON.md Proposal

private struct LemonMdStep: View {
    let repos: [WorkspaceRepo]
    let onNext: () -> Void
    let onBack: () -> Void

    enum ProposalState { case idle, analyzing, ready, failed(String) }

    @State private var proposalState: ProposalState = .idle
    @State private var editedContent = ""
    @State private var savedContent: String?

    private var saved: Bool {
        guard let savedContent else { return false }
        return savedContent == editedContent
    }

    private var primaryRepo: WorkspaceRepo? {
        repos.first { !$0.path.isEmpty }
    }

    private var lemonMdPath: String? {
        guard let repo = primaryRepo else { return nil }
        if repo.allReposInFolder, !repo.homeRepo.isEmpty {
            return "\(repo.path)/\(repo.homeRepo)/LEMON.md"
        }
        return "\(repo.path)/LEMON.md"
    }

    private var isReadyToSave: Bool {
        if case .ready = proposalState, !saved, !editedContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        return false
    }

    private var isIdle: Bool {
        if case .idle = proposalState { return true }
        return false
    }

    var body: some View {
        StepShell(
            stepNumber: 2,
            title: "Teach Lemon your codebase",
            subtitle: "LEMON.md is the brief Claude reads before every task. Draft one — edit before it saves.",
            backAction: onBack,
            // Footer reflects the actual state:
            //  - draft ready, unsaved → Save (primary, lemon) + Skip for now (secondary, grey)
            //  - saved              → Continue (primary, lemon)
            //  - idle/analyzing/failed → Skip for now (primary, lemon)
            nextLabel: isReadyToSave ? "Save" : (saved ? "Continue" : "Skip for now"),
            nextEnabled: true,
            // In the idle state the lemon already lives on the "Draft with
            // Claude" button in the body, so the footer "Skip for now" goes
            // ghost — one yellow per step.
            nextGhost: isIdle,
            nextAction: isReadyToSave ? { save() } : onNext,
            addAnotherLabel: isReadyToSave ? "Skip for now" : nil,
            addAnotherEnabled: isReadyToSave,
            addAnotherAction: isReadyToSave ? onNext : nil,
        ) {
            VStack(spacing: 14) {
                switch proposalState {
                case .idle:
                    idleView
                case .analyzing:
                    analyzingView
                case .ready:
                    editorView
                case let .failed(err):
                    failedView(err)
                }

                if saved, let path = lemonMdPath {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(LD.statusDone).font(.system(size: 13))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Saved").font(.system(size: 11, weight: .semibold))
                            Text(path)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(LD.textSecondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                    }
                    .padding(12)
                    .background(LD.statusDone.opacity(0.08), in: RoundedRectangle(cornerRadius: LD.r10))
                }
            }
        }
        .onAppear { checkExisting() }
    }

    // MARK: - State views

    private var idleView: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let path = lemonMdPath {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 11)).foregroundStyle(LD.textSecondary)
                    Text(path)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(LD.textSecondary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                }
                .padding(10)
                .lemonGlass(.thin, cornerRadius: LD.r10)
            }

            // Draft preview — the machine surface is opaque console, not glass.
            Text("DRAFT PREVIEW")
                .font(.system(size: 9, weight: .bold))
                .kerning(1.3)
                .foregroundStyle(LD.textTertiary)
            consolePreview

            // The step's one lemon — Claude is the real primary action here.
            Button {
                analyze()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                    Text("Draft with Claude")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(LemonButtonStyle())
            .disabled(primaryRepo == nil)

            Text("Claude reads your repo and proposes one. You edit before it saves.")
                .font(.system(size: 10))
                .foregroundStyle(LD.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A representative LEMON.md skeleton, rendered on the opaque console
    /// surface — mirrors the design's `.code` block.
    private var consolePreview: some View {
        VStack(alignment: .leading, spacing: 0) {
            consoleLine("# ", "project — build & test")
            consoleLine("$ ", "make build && make test", code: true)
            consoleLine("# ", "conventions")
            consoleLine("- ", "branch from origin/main", plain: true)
            consoleLine("- ", "never touch infra/", plain: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 11).padding(.vertical, 10)
        .lemonGlass(.opaque, cornerRadius: LD.r6)
    }

    private func consoleLine(_ prefix: String, _ body: String, code: Bool = false, plain: Bool = false) -> some View {
        HStack(spacing: 0) {
            Text(prefix)
                .foregroundStyle(LD.consoleText.opacity(0.45))
            Text(body)
                .foregroundStyle(LD.consoleText.opacity(plain ? 0.78 : code ? 0.92 : 0.78))
        }
        .font(.system(size: 10.5, design: .monospaced))
        .lineLimit(1)
    }

    private var analyzingView: some View {
        HStack(spacing: 12) {
            ProgressView().scaleEffect(0.75)
            VStack(alignment: .leading, spacing: 3) {
                Text("Analyzing your codebase…")
                    .font(.system(size: 12, weight: .semibold))
                Text("Reviewing structure, README, and recent commits")
                    .font(.system(size: 10)).foregroundStyle(LD.textSecondary)
            }
            Spacer()
        }
        .padding(14)
        .lemonGlass(.thin, cornerRadius: LD.r10)
    }

    private var editorView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("LEMON.md")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(LD.textSecondary)
                if let path = lemonMdPath {
                    Text("→ \(path)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(LD.textQuaternary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                // Save lives in the footer alongside "Skip for now" — see the
                // StepShell config at the top of body. No duplicate CTA here.
            }
            TextEditor(text: $editedContent)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(LD.consoleText)
                .tint(LD.lemondrop)
                .frame(minHeight: 200, maxHeight: 260)
                .scrollContentBackground(.hidden)
                .padding(8)
                .lemonGlass(.opaque, cornerRadius: LD.r6)
        }
    }

    private func failedView(_ err: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(LD.coral)
                Text("Analysis failed").font(.system(size: 12, weight: .semibold))
            }
            Text(err).font(.system(size: 10)).foregroundStyle(LD.textSecondary)
            Button("Try Again") { analyze() }.buttonStyle(GhostButtonStyle())
        }
        .padding(14)
        .background(LD.coral.opacity(0.06), in: RoundedRectangle(cornerRadius: LD.r10))
    }

    // MARK: - Actions

    private func checkExisting() {
        guard let path = lemonMdPath,
              let existing = try? String(contentsOfFile: path, encoding: .utf8),
              !existing.isEmpty else { return }
        editedContent = existing
        savedContent = existing
        proposalState = .ready
    }

    private func analyze() {
        guard let repo = primaryRepo else { return }
        proposalState = .analyzing

        let repoPath = repo.allReposInFolder && !repo.homeRepo.isEmpty
            ? "\(repo.path)/\(repo.homeRepo)"
            : repo.path

        let addDirs = repos
            .filter { !$0.path.isEmpty }
            .map { "--add-dir '\($0.path)'" }
            .joined(separator: " ")

        Task.detached {
            let promptContent = """
            Analyze the repository at: \(repoPath)

            Look at the file structure, README, and recent git history.
            Write a LEMON.md file (under 400 words) that helps an AI coding assistant understand this codebase.

            Include:
            1. What this project is and does (2-3 sentences)
            2. Key directories and their purposes
            3. How to start the dev server and run tests
            4. Deployment process and branch rules
            5. Important conventions or constraints

            IMPORTANT: Print the markdown to stdout only. Do NOT write or create any files.
            Start the output with # LEMON.md
            """

            let ts = Int(Date().timeIntervalSince1970)
            let promptPath = "/tmp/lemon-lemonmd-prompt-\(ts).txt"

            do {
                try promptContent.write(toFile: promptPath, atomically: true, encoding: .utf8)

                // Build --add-dir flags as separate arguments to avoid quoting issues
                let args = ["-l", "-c", "cd /tmp && claude -p \(addDirs) < '\(promptPath)'"]

                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/zsh")
                p.arguments = args
                let outPipe = Pipe()
                let errPipe = Pipe()
                p.standardOutput = outPipe
                p.standardError = errPipe
                try p.run()
                p.waitUntilExit()

                let output = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let errOutput = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)

                try? FileManager.default.removeItem(atPath: promptPath)

                Logger.onboarding.info("LEMON.md claude exit \(p.terminationStatus), out=\(trimmed.count) chars, err=\(errOutput.prefix(200))")

                await MainActor.run {
                    if p.terminationStatus == 0, !trimmed.isEmpty {
                        editedContent = trimmed
                        proposalState = .ready
                    } else {
                        let detail = errOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                        let msg = detail.isEmpty
                            ? "Exit \(p.terminationStatus) — check Console.app (lemon) for details"
                            : String(detail.prefix(300))
                        proposalState = .failed(msg)
                    }
                }
            } catch {
                await MainActor.run { proposalState = .failed(error.localizedDescription) }
            }
        }
    }

    private func save() {
        guard let path = lemonMdPath, !editedContent.isEmpty else { return }
        let dir = (path as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try editedContent.write(toFile: path, atomically: true, encoding: .utf8)
            Logger.onboarding.info("Saved LEMON.md to \(path)")
            withAnimation(LD.smooth) { savedContent = editedContent }
        } catch {
            Logger.onboarding.error("Failed to save LEMON.md: \(error)")
        }
    }
}
