import Foundation

/// The pull request a refresh resolved for one panel, reduced to the fields a
/// badge needs.
public struct WorkspacePullRequestResolvedItem: Sendable {
    /// The pull request number.
    public let number: Int
    /// The PR's html URL string.
    public let urlString: String
    /// The ``PullRequestStatus`` raw value (`"open"`/`"merged"`/`"closed"`),
    /// kept as a string so app-side status enums can bridge via `rawValue`.
    public let statusRawValue: String
    /// The branch the PR was matched for.
    public let branch: String
    /// Aggregate CI check state for the PR's *current* REST head SHA, when the
    /// stage-2b probe has one. `nil` means unknown/neutral — including the
    /// stale-green guard case where the REST head SHA moved past every cached
    /// check state's SHA (an old SHA's terminal color is never surfaced).
    public let checkState: PullRequestCheckState?

    /// Creates a resolved item.
    public init(
        number: Int,
        urlString: String,
        statusRawValue: String,
        branch: String,
        checkState: PullRequestCheckState? = nil
    ) {
        self.number = number
        self.urlString = urlString
        self.statusRawValue = statusRawValue
        self.branch = branch
        self.checkState = checkState
    }
}
