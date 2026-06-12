import Foundation

extension GitMetadataService {
    /// Extracts ordered, de-duplicated GitHub `owner/name` slugs from
    /// `git remote -v`-style output.
    ///
    /// Only `(fetch)` lines for `github.com` remotes contribute. Results are
    /// ordered `upstream`, then `origin`, then other remotes alphabetically.
    nonisolated static func githubRepositorySlugs(fromGitRemoteVOutput output: String) -> [String] {
        var slugByRemoteName: [String: String] = [:]

        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 3 else { continue }

            let remoteName = String(parts[0])
            let remoteURL = String(parts[1])
            let remoteKind = String(parts[2])
            guard remoteKind == "(fetch)",
                  let repoSlug = githubRepositorySlug(fromRemoteURL: remoteURL) else {
                continue
            }

            slugByRemoteName[remoteName] = repoSlug
        }

        let orderedRemoteNames = slugByRemoteName.keys.sorted { lhs, rhs in
            let lhsPriority = githubRemotePriority(lhs)
            let rhsPriority = githubRemotePriority(rhs)
            if lhsPriority != rhsPriority {
                return lhsPriority < rhsPriority
            }
            return lhs < rhs
        }

        var orderedSlugs: [String] = []
        var seen: Set<String> = []
        for remoteName in orderedRemoteNames {
            guard let repoSlug = slugByRemoteName[remoteName],
                  seen.insert(repoSlug).inserted else {
                continue
            }
            orderedSlugs.append(repoSlug)
        }
        return orderedSlugs
    }

    /// Sort priority for a remote name: `upstream` (0), `origin` (1), other (2).
    nonisolated static func githubRemotePriority(_ remoteName: String) -> Int {
        switch remoteName.lowercased() {
        case "upstream":
            return 0
        case "origin":
            return 1
        default:
            return 2
        }
    }

    /// The `owner/name` slug for a GitHub remote URL (SSH, HTTPS, HTTP, git, or
    /// `ssh://` forms), or `nil` for a non-GitHub URL.
    ///
    /// SSH host aliases are common in fork workflows (`git@github-personal:o/r`
    /// with the real host mapped in `~/.ssh/config`), so SSH forms accept any
    /// github-ish host (see `isGitHubLikeHost`). A wrong guess is harmless:
    /// slugs only form query paths against the hardcoded `api.github.com`,
    /// where an unknown repo 404s.
    nonisolated static func githubRepositorySlug(fromRemoteURL remoteURL: String) -> String? {
        let trimmed = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // scp-like SSH form: git@HOST:owner/repo(.git)
        if trimmed.hasPrefix("git@"), let colon = trimmed.firstIndex(of: ":") {
            let hostStart = trimmed.index(trimmed.startIndex, offsetBy: "git@".count)
            guard hostStart < colon else { return nil }
            let host = trimmed[hostStart..<colon].lowercased()
            guard isGitHubLikeHost(host) else { return nil }
            return normalizedGitHubRepositorySlug(String(trimmed[trimmed.index(after: colon)...]))
        }

        guard let url = URL(string: trimmed),
              let host = url.host?.lowercased() else {
            return nil
        }
        switch url.scheme?.lowercased() {
        case "ssh":
            guard isGitHubLikeHost(host) else { return nil }
        case "https", "http", "git":
            guard host == "github.com" || host.hasSuffix(".github.com") else { return nil }
        default:
            return nil
        }
        return normalizedGitHubRepositorySlug(url.path)
    }

    /// `github.com`, `*.github.com`, or an SSH alias starting with `github`
    /// (the common `github-personal` / `github-work` convention).
    nonisolated static func isGitHubLikeHost(_ host: String) -> Bool {
        host == "github.com" || host.hasSuffix(".github.com") || host.hasPrefix("github")
    }

    /// The `owner/name` slug for a GitHub pull-request URL, or `nil` for a
    /// non-GitHub URL.
    nonisolated static func githubRepositorySlug(fromPullRequestURL url: URL) -> String? {
        guard let host = url.host?.lowercased(),
              host == "github.com" else {
            return nil
        }
        return normalizedGitHubRepositorySlug(url.path)
    }

    /// Normalizes a `owner/name(...)` path into a `owner/name` slug, dropping a
    /// trailing `.git`, or `nil` when it lacks both components.
    nonisolated static func normalizedGitHubRepositorySlug(_ rawPath: String) -> String? {
        let trimmedPath = rawPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmedPath.isEmpty else { return nil }
        let components = trimmedPath.split(separator: "/").map(String.init)
        guard components.count >= 2 else { return nil }
        let owner = components[0]
        var repo = components[1]
        if repo.hasSuffix(".git") {
            repo.removeLast(4)
        }
        guard !owner.isEmpty, !repo.isEmpty else { return nil }
        return "\(owner)/\(repo)"
    }
}
