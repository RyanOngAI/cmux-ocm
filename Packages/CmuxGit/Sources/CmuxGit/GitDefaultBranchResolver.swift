import Foundation

/// Resolves the ref that represents a repository's "default branch" — the base
/// a fresh worktree should branch from and the base the Changes panel diffs
/// against. Both callers share this one chain so a worktree created off the
/// resolved ref shows an empty Changes panel instead of inheriting whatever
/// branch happened to be checked out.
///
/// The resolver makes no assumptions about how git is invoked: callers inject a
/// `runGit` closure, so it stays pure and unit-testable with a stub.
public struct GitDefaultBranchResolver {
    public init() {}

    /// One git invocation's outcome: the process exit status plus the trimmed
    /// first line of stdout (`""` when stdout was empty).
    public struct CommandResult: Sendable, Equatable {
        public let exitStatus: Int32
        public let firstLine: String

        public init(exitStatus: Int32, firstLine: String) {
            self.exitStatus = exitStatus
            self.firstLine = firstLine
        }
    }

    /// Result of resolving the default branch.
    public enum Resolution: Sendable, Equatable {
        /// A git invocation failed at the process level (launch failure / timeout).
        /// Callers that need a strict diff base treat this as a refresh failure;
        /// callers that just need a base ref fall back to their own default.
        case processFailure
        /// Resolution ran to completion. `baseRef` is the default-branch ref, or
        /// `nil` when none of the candidates exist (caller decides the fallback).
        case resolved(baseRef: String?)
    }

    /// Resolution chain (matches the Changes panel's diff-base logic):
    /// `cmux.changes.base` git config (per-repo override; must resolve to a
    /// commit) → `origin/HEAD` symref → local `main` → local `master` → none.
    ///
    /// - Parameter runGit: runs `git <arguments>` in the target repository and
    ///   returns the result, or `nil` on a process-level failure.
    public func resolveBaseRef(
        runGit: (_ arguments: [String]) async -> CommandResult?
    ) async -> Resolution {
        // 1. Per-repo override. An unresolvable override falls through to
        //    auto-detection rather than failing resolution outright.
        guard let configured = await runGit(["config", "--get", "cmux.changes.base"]) else {
            return .processFailure
        }
        if configured.exitStatus == 0, !configured.firstLine.isEmpty {
            guard let verified = await runGit(
                ["rev-parse", "--verify", "--quiet", "\(configured.firstLine)^{commit}"]
            ) else { return .processFailure }
            if verified.exitStatus == 0 {
                return .resolved(baseRef: configured.firstLine)
            }
        }

        // 2. The remote's default branch (e.g. `origin/main`).
        guard let originHead = await runGit(
            ["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"]
        ) else { return .processFailure }
        if originHead.exitStatus == 0, !originHead.firstLine.isEmpty {
            return .resolved(baseRef: originHead.firstLine)
        }

        // 3. Conventional local default branches.
        for candidate in ["main", "master"] {
            guard let result = await runGit(
                ["rev-parse", "--verify", "--quiet", "refs/heads/\(candidate)^{commit}"]
            ) else { return .processFailure }
            if result.exitStatus == 0 {
                return .resolved(baseRef: candidate)
            }
        }

        return .resolved(baseRef: nil)
    }
}
