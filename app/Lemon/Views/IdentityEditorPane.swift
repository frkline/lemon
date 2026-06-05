import SwiftUI

/// Slide-in pane for adding or editing a single identity. Pushed via
/// `AppNavigation.editIdentity(_:)` / `addIdentity(kind:)`. Replaces the
/// old sheet-presented credential cards.
struct IdentityEditorPane: View {
    @Environment(Orchestrator.self) private var orchestrator
    @Environment(AppNavigation.self) private var nav

    let target: AppNavigation.IdentityEditorTarget

    @State private var label: String = ""
    @State private var token: String = ""
    @State private var host: String = ""
    @State private var verifyState: VerifyState = .idle
    @State private var existingIdentity: Identity?
    @State private var deleteArmed = false
    @State private var deleteTask: Task<Void, Never>?

    enum VerifyState: Equatable {
        case idle
        case verifying
        case ok(handle: String, surfaceCount: Int)
        case failed(String)
    }

    private var kind: IdentityKind {
        switch target {
        case .new(let k): return k
        case .existing(let id):
            return KeychainStore.shared.identities.first { $0.id == id }?.kind ?? .linear
        }
    }

    private var isNew: Bool {
        if case .new = target { return true } else { return false }
    }

    private var isGitHub: Bool { kind == .github }
    private var verified: Bool {
        if case .ok = verifyState { return true }
        return existingIdentity != nil
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 22) {
                eyebrowHeader
                labelField
                credentialCard
                if isGitHub { hostField }
                verifyRow
                if verified { surfacesSummary }
                if !isNew { routedBySummary }
                Spacer(minLength: 4)
                actionsRow
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
        }
        .background(LD.consoleBackground.opacity(0.02))
        .onAppear { hydrate() }
    }

    // MARK: - Layout

    private var eyebrowHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(isNew ? "NEW IDENTITY" : "IDENTITY")
                    .font(.system(size: 9, weight: .bold))
                    .kerning(1.6)
                    .foregroundStyle(LD.lemon)
                SourceGlyph(source: kind.issueSource, size: 9)
            }
            Text(headerTitle)
                .font(.system(size: 24, weight: .bold, design: .serif))
                .foregroundStyle(.primary)
            Text(headerSubtitle)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var headerTitle: String {
        switch kind {
        case .linear: return isNew ? "Connect Linear" : (existingIdentity?.label ?? "Linear")
        case .github: return isNew ? "Connect GitHub" : (existingIdentity?.label ?? "GitHub")
        }
    }

    private var headerSubtitle: String {
        switch kind {
        case .linear:
            return "Personal API key from linear.app/settings → API. Lemon polls your teams; the key is stored in Keychain."
        case .github:
            return "Classic or fine-grained PAT with the `repo` scope. Add an Enterprise host below if you're on a self-hosted instance."
        }
    }

    private var labelField: some View {
        editorialField(
            eyebrow: "LABEL",
            placeholder: defaultLabel,
            text: $label,
            helper: "How this identity reads in the workspace editor."
        )
    }

    private var defaultLabel: String {
        switch kind {
        case .linear: return "Linear · work"
        case .github: return "GitHub · @you"
        }
    }

    private var credentialCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(isGitHub ? "PERSONAL ACCESS TOKEN" : "API KEY")
                .font(.system(size: 8, weight: .bold))
                .kerning(1.4)
                .foregroundStyle(.tertiary)
            SecureField(
                isGitHub ? "ghp_…" : "lin_api_…",
                text: $token
            )
            .textFieldStyle(.plain)
            .font(.system(size: 12, design: .monospaced))
            .padding(.vertical, 7)
            .padding(.horizontal, 9)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5)
            )
            .onChange(of: token) { _, _ in verifyState = .idle }
        }
    }

    private var hostField: some View {
        editorialField(
            eyebrow: "ENTERPRISE HOST",
            placeholder: "api.github.acmecorp.com (leave blank for github.com)",
            text: $host,
            helper: "Optional. Set only for GitHub Enterprise Server installations.",
            monospaced: true
        )
    }

    private var verifyRow: some View {
        HStack(spacing: 10) {
            Button {
                Task { await runVerify() }
            } label: {
                HStack(spacing: 6) {
                    if case .verifying = verifyState {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "checkmark.shield")
                            .font(.system(size: 11))
                    }
                    Text(verifyButtonLabel)
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LD.citrus)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(LD.lemon, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(token.isEmpty || verifyState == .verifying)
            .opacity(token.isEmpty ? 0.5 : 1)

            verifyStateChip
            Spacer(minLength: 0)
        }
    }

    private var verifyButtonLabel: String {
        switch verifyState {
        case .idle:      return verified ? "Re-verify & sync" : "Verify & sync"
        case .verifying: return "Talking to API…"
        case .ok:        return "Re-verify & sync"
        case .failed:    return "Retry verify"
        }
    }

    @ViewBuilder
    private var verifyStateChip: some View {
        switch verifyState {
        case .ok(let handle, let count):
            HStack(spacing: 4) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(LD.statusDone)
                Text("@\(handle) · \(count) surface\(count == 1 ? "" : "s")")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(LD.statusDone)
            }
        case .failed(let msg):
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(LD.coral)
                Text(msg)
                    .font(.system(size: 10))
                    .foregroundStyle(LD.coral)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
        default:
            EmptyView()
        }
    }

    private var surfacesSummary: some View {
        let surfaces = currentSurfaces
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("SURFACES")
                    .font(.system(size: 8, weight: .bold))
                    .kerning(1.4)
                    .foregroundStyle(.tertiary)
                Text("\(surfaces.count) visible")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            if surfaces.isEmpty {
                Text(emptySurfacesText)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: LD.r10))
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(surfaces.prefix(8), id: \.id) { surface in
                        surfaceLine(surface)
                    }
                    if surfaces.count > 8 {
                        Text("+ \(surfaces.count - 8) more")
                            .font(.system(size: 10))
                            .foregroundStyle(.quaternary)
                    }
                }
                .padding(12)
                .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: LD.r10))
            }
        }
    }

    @ViewBuilder
    private func surfaceLine(_ surface: Surface) -> some View {
        // When key == displayName (common for GitHub repos where
        // owner/repo is both the id and the label, or for Linear teams
        // whose key matches the team name), collapse the two columns
        // into a single editorial mark.
        let dupe = surface.key.caseInsensitiveCompare(surface.displayName) == .orderedSame
        HStack(spacing: 8) {
            if dupe {
                Text(surface.displayName)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                Text(surface.key)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 50, alignment: .leading)
                Text(surface.displayName)
                    .font(.system(size: 11))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
    }

    /// Workspaces that route through this identity. Surfaced so the user
    /// understands what would break if they delete the identity, and as a
    /// quick jump-back to the workspace editor.
    private var routedBySummary: some View {
        let routed = KeychainStore.shared.workspaces.filter {
            $0.routing.identityId == existingIdentity?.id
        }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("ROUTED BY")
                    .font(.system(size: 8, weight: .bold))
                    .kerning(1.4)
                    .foregroundStyle(.tertiary)
                Text("\(routed.count) workspace\(routed.count == 1 ? "" : "s")")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            if routed.isEmpty {
                Text("Not routed by any workspace yet. Delete is safe.")
                    .font(.system(size: 10))
                    .foregroundStyle(.quaternary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: LD.r10))
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(routed.prefix(6), id: \.id) { ws in
                        Button {
                            nav.editWorkspace(ws.id)
                        } label: {
                            HStack(spacing: 8) {
                                Text(URL(fileURLWithPath: ws.path).lastPathComponent.isEmpty
                                     ? "Unnamed"
                                     : URL(fileURLWithPath: ws.path).lastPathComponent)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.primary)
                                Text("·")
                                    .foregroundStyle(.quaternary)
                                Text(ws.routing.surfaceId)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(.quaternary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    if routed.count > 6 {
                        Text("+ \(routed.count - 6) more")
                            .font(.system(size: 10))
                            .foregroundStyle(.quaternary)
                    }
                    if deleteArmed {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(LD.coral)
                            Text("\(routed.count) workspace\(routed.count == 1 ? "" : "s") will lose their routing.")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(LD.coral)
                        }
                        .padding(.top, 2)
                        .transition(.opacity)
                    }
                }
                .padding(12)
                .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: LD.r10))
            }
        }
    }

    private var currentSurfaces: [Surface] {
        switch verifyState {
        case .ok:
            return existingIdentity?.knownSurfaces ?? []
        default:
            return existingIdentity?.knownSurfaces ?? []
        }
    }

    private var emptySurfacesText: String {
        switch kind {
        case .linear: return "No teams visible. Make sure the API key has team access."
        case .github: return "No repos visible. Check the PAT's `repo` scope."
        }
    }

    private var actionsRow: some View {
        HStack(spacing: 10) {
            Button("Cancel") {
                nav.popEditor()
            }
            .buttonStyle(GhostButtonStyle())

            Spacer()

            if !isNew {
                Button {
                    handleDelete()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: deleteArmed ? "trash.fill" : "trash")
                            .font(.system(size: 11))
                        Text(deleteArmed ? "Confirm delete" : "Delete identity")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(deleteArmed ? .white : LD.coral)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(deleteArmed ? LD.coral : LD.coral.opacity(0.12)))
                    .animation(LD.snappy, value: deleteArmed)
                }
                .buttonStyle(.plain)
            }

            Button("Save") {
                save()
                nav.popEditor()
            }
            .buttonStyle(LemonButtonStyle())
            .disabled(!verified)
        }
    }

    // MARK: - Behaviors

    private func hydrate() {
        if case .existing(let id) = target,
           let ident = KeychainStore.shared.identities.first(where: { $0.id == id }) {
            existingIdentity = ident
            label = ident.label
            host = ident.host ?? ""
            // Token is intentionally not pre-filled — Keychain reads happen on
            // demand and we want re-verification to be explicit.
            verifyState = .ok(handle: ident.handle, surfaceCount: ident.knownSurfaces.count)
        }
    }

    private func runVerify() async {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        verifyState = .verifying
        do {
            let result = try await orchestrator.verifyAndDiscover(
                kind: kind,
                token: trimmedToken,
                host: trimmedHost.isEmpty ? nil : trimmedHost
            )
            verifyState = .ok(handle: result.credential.displayName, surfaceCount: result.surfaces.count)
            // Mutate the in-memory identity record so the surfaces panel can
            // render the freshly fetched list immediately. Persistence happens
            // on Save.
            var ident = existingIdentity ?? Identity(
                kind: kind,
                label: label.isEmpty ? defaultLabel : label,
                handle: result.credential.displayName,
                principalId: result.credential.id,
                host: trimmedHost.isEmpty ? nil : trimmedHost
            )
            ident.label = label.isEmpty ? defaultLabel : label
            ident.handle = result.credential.displayName
            ident.principalId = result.credential.id
            ident.host = trimmedHost.isEmpty ? nil : trimmedHost
            ident.knownSurfaces = result.surfaces
            ident.surfacesFetchedAt = Date()
            existingIdentity = ident
        } catch {
            verifyState = .failed(error.localizedDescription)
        }
    }

    private func save() {
        let keychain = KeychainStore.shared
        var working = existingIdentity ?? Identity(
            kind: kind,
            label: label.isEmpty ? defaultLabel : label,
            handle: "",
            principalId: "",
            host: nil
        )
        working.label = label.isEmpty ? defaultLabel : label
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        working.host = trimmedHost.isEmpty ? nil : trimmedHost

        // Persist or update.
        var all = keychain.identities
        if let idx = all.firstIndex(where: { $0.id == working.id }) {
            all[idx] = working
        } else {
            all.append(working)
        }
        keychain.identities = all

        // Persist secret if the user typed one (re-verify path or new identity).
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedToken.isEmpty {
            keychain.setIdentitySecret(trimmedToken, for: working.id)
        }
    }

    private func handleDelete() {
        if deleteArmed {
            deleteTask?.cancel()
            performDelete()
            return
        }
        deleteArmed = true
        deleteTask?.cancel()
        deleteTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled {
                withAnimation(LD.smooth) { deleteArmed = false }
            }
        }
    }

    private func performDelete() {
        guard let ident = existingIdentity else { return }
        let keychain = KeychainStore.shared
        keychain.deleteIdentitySecret(for: ident.id)
        keychain.identities = keychain.identities.filter { $0.id != ident.id }
        // Workspaces that routed through this identity become orphaned —
        // surface in the workspace editor as a "missing identity" error.
        nav.popEditor()
    }

    // MARK: - Editorial form field helper

    private func editorialField(
        eyebrow: String,
        placeholder: String,
        text: Binding<String>,
        helper: String? = nil,
        monospaced: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(eyebrow)
                .font(.system(size: 8, weight: .bold))
                .kerning(1.4)
                .foregroundStyle(.tertiary)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: monospaced ? .monospaced : .default))
                .padding(.vertical, 7)
                .padding(.horizontal, 9)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5)
                )
            if let helper {
                Text(helper)
                    .font(.system(size: 10))
                    .foregroundStyle(.quaternary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
