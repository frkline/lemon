import Foundation

/// Deterministic workspace inspection. Reads `.git/config` to extract the
/// origin remote, parses the URL (HTTPS or SSH) for host + owner/repo,
/// and matches the result against the user's connected identities. Returns
/// a suggestion the editor surfaces as an inline chip — never forces, just
/// proposes.
///
/// Tier 1 of the "smart routing" plan. The fuzzy Gemma-backed tier is
/// reserved for ambiguous folders and lives separately (issue followup).
enum WorkspaceAnalyzer {
    static func suggest(for path: String, identities: [Identity]) -> WorkspaceEditorPane.PathSuggestion? {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        // Try direct repo first.
        if let parsed = parseRemote(at: trimmed) {
            return matchAgainstIdentities(parsed: parsed, identities: identities)
        }

        // Fall back to scanning for child repos (multi-repo folder mode).
        let children = childRepos(at: trimmed)
        if children.count == 1, let parsed = parseRemote(at: children[0]) {
            return matchAgainstIdentities(parsed: parsed, identities: identities)
        }
        return nil
    }

    // MARK: - Remote parsing

    struct ParsedRemote: Equatable {
        let host: String // "github.com" / "github.acmecorp.com"
        let owner: String
        let repo: String
    }

    static func parseRemote(at folder: String) -> ParsedRemote? {
        let configPath = (folder as NSString).appendingPathComponent(".git/config")
        guard let contents = try? String(contentsOfFile: configPath, encoding: .utf8) else { return nil }
        return parseGitConfig(contents)
    }

    static func parseGitConfig(_ contents: String) -> ParsedRemote? {
        // Look for `[remote "origin"]` then a `url =` line inside the section.
        var inOriginBlock = false
        var foundURL: String?
        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("["), line.hasSuffix("]") {
                inOriginBlock = line.contains("[remote \"origin\"]")
                continue
            }
            if inOriginBlock, line.hasPrefix("url"), let eq = line.range(of: "=") {
                foundURL = line[eq.upperBound...].trimmingCharacters(in: .whitespaces)
                break
            }
        }
        guard let url = foundURL else { return nil }
        return parseRemoteURL(url)
    }

    static func parseRemoteURL(_ url: String) -> ParsedRemote? {
        // SSH form: git@github.com:owner/repo.git
        if let at = url.firstIndex(of: "@"), let colon = url.firstIndex(of: ":"), at < colon {
            let host = String(url[url.index(after: at) ..< colon])
            let pathPart = String(url[url.index(after: colon)...])
            return splitOwnerRepo(pathPart).map {
                ParsedRemote(host: host, owner: $0.0, repo: $0.1)
            }
        }
        // HTTPS/HTTP form: https://github.com/owner/repo.git or https://user@…/owner/repo
        if let scheme = url.range(of: "://") {
            let rest = url[scheme.upperBound...]
            // Strip optional user@ prefix
            let afterUser = rest.firstIndex(of: "@").map { rest[rest.index(after: $0)...] } ?? rest[...]
            guard let slash = afterUser.firstIndex(of: "/") else { return nil }
            let host = String(afterUser[..<slash])
            let pathPart = String(afterUser[afterUser.index(after: slash)...])
            return splitOwnerRepo(pathPart).map {
                ParsedRemote(host: host, owner: $0.0, repo: $0.1)
            }
        }
        return nil
    }

    private static func splitOwnerRepo(_ path: String) -> (String, String)? {
        var trimmed = path
        if trimmed.hasSuffix(".git") { trimmed.removeLast(4) }
        // Drop trailing slash if any
        if trimmed.hasSuffix("/") { trimmed.removeLast() }
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        // For nested paths (GitLab subgroups), take the last two segments.
        let owner = String(parts[parts.count - 2])
        let repo = String(parts[parts.count - 1])
        guard !owner.isEmpty, !repo.isEmpty else { return nil }
        return (owner, repo)
    }

    // MARK: - Child repo discovery

    static func childRepos(at folder: String) -> [String] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: folder) else { return [] }
        return entries.compactMap { name in
            let child = (folder as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            let gitPath = (child as NSString).appendingPathComponent(".git")
            guard fm.fileExists(atPath: gitPath, isDirectory: &isDir) else { return nil }
            return child
        }
    }

    // MARK: - Identity matching

    private static func matchAgainstIdentities(parsed: ParsedRemote, identities: [Identity]) -> WorkspaceEditorPane.PathSuggestion? {
        let ownerRepo = "\(parsed.owner)/\(parsed.repo)"
        // Match GitHub identities first, scoped by host.
        for ident in identities where ident.kind == .github {
            if matchesHost(parsedHost: parsed.host, identity: ident),
               ident.knownSurfaces.contains(where: { $0.id.caseInsensitiveCompare(ownerRepo) == .orderedSame })
            {
                return WorkspaceEditorPane.PathSuggestion(
                    identityId: ident.id,
                    surfaceKey: ownerRepo,
                    label: "Route through \(ident.label) · \(ownerRepo)",
                    detail: "Detected from .git/config — exact match on a known repo.",
                )
            }
        }
        // If no surface-list match but the host matches a configured identity,
        // still suggest it (user may not have refreshed surfaces yet).
        for ident in identities where ident.kind == .github {
            if matchesHost(parsedHost: parsed.host, identity: ident) {
                return WorkspaceEditorPane.PathSuggestion(
                    identityId: ident.id,
                    surfaceKey: ownerRepo,
                    label: "Route through \(ident.label) · \(ownerRepo)",
                    detail: "Detected from .git/config — repo not yet listed; consider Refresh.",
                )
            }
        }
        return nil
    }

    /// host on the parsed URL ("github.com") vs identity.host
    /// (often "api.github.com" or "api.github.acme.com"). github.com matches
    /// when host is nil or api.github.com.
    private static func matchesHost(parsedHost: String, identity: Identity) -> Bool {
        let p = parsedHost.lowercased()
        let h = (identity.host ?? "").lowercased()
        if h.isEmpty || h == "api.github.com" {
            return p == "github.com"
        }
        // "api.github.acme.com" vs "github.acme.com"
        if h.hasPrefix("api.") {
            return p == String(h.dropFirst("api.".count))
        }
        return p == h
    }
}
