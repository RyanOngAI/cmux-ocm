public import Foundation

/// One repository's cached pull-request lookup state, keyed by branch.
///
/// The caller owns the cache (slug → entry) and hands it back on each refresh;
/// the service decides freshness with ``PullRequestProbeService/repoCacheLifetime``.
public struct WorkspacePullRequestRepoCacheEntry: Sendable {
    /// When this entry was fetched.
    public let fetchedAt: Date
    /// The best pull request per normalized branch name.
    public let pullRequestsByBranch: [String: GitHubPullRequestProbeItem]
    /// Branches positively known to have no pull request (so a cached entry
    /// doesn't re-trigger per-branch lookups for them).
    public let knownAbsentBranches: Set<String>
    /// Aggregate CI check state per PR head SHA (stage 2b GraphQL probe).
    /// Terminal rollups are long-lived for their SHA; non-terminal entries
    /// are only fresh within ``PullRequestProbeService/repoCacheLifetime``.
    public let checkStatesByHeadSHA: [String: PullRequestCheckState]
    /// `rateLimit.remaining` reported by the last GraphQL checks fetch, so the
    /// caller can back off polling when the budget runs low.
    public let checksRateLimitRemaining: Int?

    /// Creates a cache entry.
    public init(
        fetchedAt: Date,
        pullRequestsByBranch: [String: GitHubPullRequestProbeItem],
        knownAbsentBranches: Set<String> = [],
        checkStatesByHeadSHA: [String: PullRequestCheckState] = [:],
        checksRateLimitRemaining: Int? = nil
    ) {
        self.fetchedAt = fetchedAt
        self.pullRequestsByBranch = pullRequestsByBranch
        self.knownAbsentBranches = knownAbsentBranches
        self.checkStatesByHeadSHA = checkStatesByHeadSHA
        self.checksRateLimitRemaining = checksRateLimitRemaining
    }
}
