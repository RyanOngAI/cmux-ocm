public import Foundation

/// Aggregate CI check state for one pull request's head commit, fetched via
/// the GraphQL `statusCheckRollup` probe (pipeline stage 2b).
///
/// Cached per head SHA on ``WorkspacePullRequestRepoCacheEntry``: terminal
/// rollups (success/failure/error) are long-lived for their SHA; non-terminal
/// rollups are only fresh within ``PullRequestProbeService/repoCacheLifetime``.
/// A head-SHA change invalidates implicitly — lookups key on the current REST
/// head SHA, so a stale entry for an old SHA is simply never matched (the
/// "stale green" guard).
public struct PullRequestCheckState: Sendable, Equatable, Codable {
    /// Aggregate rollup of every check suite and commit status on the head
    /// commit (GraphQL `StatusState`).
    public enum RollupState: String, Sendable, Equatable, Codable {
        case success
        case pending
        case expected
        case failure
        case error
        /// `statusCheckRollup` was JSON `null`: the commit has no checks at
        /// all. Renders neutral (R15), never green or red.
        ///
        /// Named `noChecks` rather than `none` so `state == .none` can never
        /// be mistaken for `Optional.none` in optional-chained comparisons.
        case noChecks
        /// The state could not be determined: missing nodes, a GraphQL errors
        /// array (e.g. fine-grained token lacking Checks read), or an
        /// unrecognized state string. Renders neutral, never red.
        case unknown

        /// Whether the rollup is terminal (success/failure/error). Terminal
        /// states are long-lived in the cache for their head SHA.
        public var isTerminal: Bool {
            switch self {
            case .success, .failure, .error:
                return true
            case .pending, .expected, .noChecks, .unknown:
                return false
            }
        }

        /// Maps a raw GraphQL `StatusState` string; absent or unrecognized
        /// values become ``unknown``.
        init(graphQLState: String?) {
            switch graphQLState?.uppercased() {
            case "SUCCESS":
                self = .success
            case "PENDING":
                self = .pending
            case "EXPECTED":
                self = .expected
            case "FAILURE":
                self = .failure
            case "ERROR":
                self = .error
            default:
                self = .unknown
            }
        }
    }

    /// The head commit SHA the rollup was observed for (GraphQL commit `oid`).
    public let headSHA: String
    /// The aggregate rollup state.
    public let rollupState: RollupState
    /// Raw GraphQL `mergeable` value (`MERGEABLE`/`CONFLICTING`/`UNKNOWN`).
    /// Stored for the deferred review-aware follow-up; v1 color ignores it
    /// (`UNKNOWN` is GitHub's lazy background computation — keep current
    /// color and re-poll).
    public let mergeable: String?
    /// Raw GraphQL `mergeStateStatus` value (e.g. `CLEAN`/`BLOCKED`/`DIRTY`).
    /// Stored for the deferred review-aware-green follow-up; v1 color ignores it.
    public let mergeStateStatus: String?
    /// Whether the PR is a draft. Stored for the deferred draft-badge
    /// follow-up; v1 color ignores it.
    public let isDraft: Bool
    /// When this state was fetched (drives the non-terminal freshness rule).
    public let fetchedAt: Date

    /// Creates a check state.
    public init(
        headSHA: String,
        rollupState: RollupState,
        mergeable: String?,
        mergeStateStatus: String?,
        isDraft: Bool,
        fetchedAt: Date
    ) {
        self.headSHA = headSHA
        self.rollupState = rollupState
        self.mergeable = mergeable
        self.mergeStateStatus = mergeStateStatus
        self.isDraft = isDraft
        self.fetchedAt = fetchedAt
    }
}
