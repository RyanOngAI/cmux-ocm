import Foundation

extension PullRequestProbeService {
    // MARK: Stage 2b — CI check-state probe (GraphQL)

    /// The GitHub GraphQL endpoint. Deliberately a literal constant — never
    /// derived from git config, remote URLs, or any other runtime input — so a
    /// hostile repository can never redirect the authenticated POST.
    nonisolated static let graphQLEndpointString = "https://api.github.com/graphql"

    /// Most check states retained per repo cache entry. Untracked terminal
    /// states stay long-lived for SHA-change flip-back protection, but the
    /// dictionary must not grow without bound.
    nonisolated static let maxRetainedCheckStatesPerRepo = 32

    /// Runs one GraphQL HTTP request. Injected (internal init) so tests can
    /// record calls and stub responses without network access — the same seam
    /// style as the injected ``CmuxProcess/CommandRunning``.
    typealias GraphQLRequestRunner =
        @Sendable (URLSession, URLRequest) async -> WorkspacePullRequestHTTPResponse?

    /// The production runner: one `URLSession` data task, `nil` on transport
    /// error (mirrors `performRequest`).
    nonisolated static let liveGraphQLRequestRunner: GraphQLRequestRunner = { session, request in
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return nil
            }
            return WorkspacePullRequestHTTPResponse(
                statusCode: httpResponse.statusCode,
                data: data
            )
        } catch {
            return nil
        }
    }

    /// One tracked PR the checks probe must cover: its number plus the head
    /// SHA the REST stage reported (used to correlate cached check states).
    struct PullRequestCheckProbeTarget: Sendable, Equatable {
        let number: Int
        let headSHA: String?
    }

    /// The decoded outcome of one checks query.
    struct PullRequestChecksDecodeResult: Sendable {
        /// Check states keyed by PR number (only PRs whose node decoded with a
        /// head oid; a missing entry means ``PullRequestCheckState/RollupState/unknown``).
        let checkStatesByNumber: [Int: PullRequestCheckState]
        /// `rateLimit.remaining` from the response, if present.
        let rateLimitRemaining: Int?
        /// Whether the response carried a GraphQL `errors` array. Only this
        /// boolean is ever surfaced — never the array contents.
        let hadErrors: Bool
    }

    // MARK: Cache policy (pure)

    /// Whether a cached check state may be served without refetching:
    /// terminal rollups are long-lived per head SHA; non-terminal rollups are
    /// only fresh within ``repoCacheLifetime``.
    nonisolated static func isCheckStateReusable(
        _ state: PullRequestCheckState,
        now: Date
    ) -> Bool {
        if state.rollupState.isTerminal {
            return true
        }
        return now.timeIntervalSince(state.fetchedAt) < Self.repoCacheLifetime
    }

    /// The PR numbers whose check state must be (re)fetched: targets without a
    /// reusable cached state for their *current* head SHA. A head-SHA change
    /// therefore invalidates immediately — the old SHA's entry never matches.
    nonisolated static func checkStateNumbersNeedingFetch(
        targets: [PullRequestCheckProbeTarget],
        cachedCheckStates: [String: PullRequestCheckState],
        now: Date
    ) -> [Int] {
        var numbers: Set<Int> = []
        for target in targets {
            if let headSHA = target.headSHA,
               let cached = cachedCheckStates[headSHA],
               isCheckStateReusable(cached, now: now) {
                continue
            }
            numbers.insert(target.number)
        }
        return numbers.sorted()
    }

    // MARK: Query + request builders (pure)

    /// Builds the bounded check-state query: one aliased `pullRequest(number:)`
    /// field per tracked PR (numbers come from the REST stage's selection —
    /// never "all open PRs"), plus `rateLimit`. Returns `nil` for a malformed
    /// slug, an unsafe slug character, or an empty number set.
    nonisolated static func checkStateQuery(
        repoSlug: String,
        pullRequestNumbers: [Int]
    ) -> String? {
        let components = repoSlug.split(separator: "/", maxSplits: 1).map(String.init)
        guard components.count == 2,
              !components[0].isEmpty,
              !components[1].isEmpty,
              !pullRequestNumbers.isEmpty else {
            return nil
        }
        // GitHub owners are alphanumeric + hyphen; repo names additionally
        // allow underscore and period. Anything else (quotes, backslashes,
        // braces…) is rejected outright rather than escaped, so the slug can
        // never break out of the GraphQL string literal.
        let allowedScalars = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_."
        )
        guard components.allSatisfy({ component in
            component.unicodeScalars.allSatisfy { allowedScalars.contains($0) }
        }) else {
            return nil
        }

        let numbers = Set(pullRequestNumbers).sorted()
        let pullRequestFields = numbers.map { number in
            "pr\(number): pullRequest(number: \(number)) { " +
            "number isDraft mergeable mergeStateStatus " +
            "commits(last: 1) { nodes { commit { oid statusCheckRollup { state } } } } }"
        }.joined(separator: " ")
        return "query { repo: repository(owner: \"\(components[0])\", name: \"\(components[1])\") " +
            "{ \(pullRequestFields) } rateLimit { remaining resetAt } }"
    }

    /// Builds the POST request for one checks query. The URL is the literal
    /// ``graphQLEndpointString`` constant — never derived from runtime input.
    nonisolated static func makeGraphQLRequest(
        query: String,
        authHeader: String?
    ) -> URLRequest? {
        guard let url = URL(string: Self.graphQLEndpointString),
              let body = try? JSONSerialization.data(withJSONObject: ["query": query]) else {
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("cmux-workspace-pr-poller", forHTTPHeaderField: "User-Agent")
        if let authHeader, !authHeader.isEmpty {
            request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        }
        return request
    }

    // MARK: Response decoding (pure, defensive)

    private struct GraphQLChecksResponse: Decodable {
        struct RateLimit: Decodable {
            let remaining: Int?
        }
        struct Rollup: Decodable {
            let state: String?
        }
        struct Commit: Decodable {
            let oid: String?
            let statusCheckRollup: Rollup?
        }
        struct CommitNode: Decodable {
            let commit: Commit?
        }
        struct Commits: Decodable {
            let nodes: [CommitNode?]?
        }
        struct PullRequestNode: Decodable {
            let number: Int?
            let isDraft: Bool?
            let mergeable: String?
            let mergeStateStatus: String?
            let commits: Commits?
        }
        struct DataContainer: Decodable {
            /// The aliased repository: every key is a `pr<N>` alias.
            let repo: [String: PullRequestNode?]?
            let rateLimit: RateLimit?
        }
        /// Opaque marker: decodes any error object without retaining its
        /// contents, so token-adjacent error text can never leak into logs.
        struct ErrorMarker: Decodable {}

        let data: DataContainer?
        let errors: [ErrorMarker]?
    }

    /// Decodes one checks response. Defensive throughout: a `null`
    /// `statusCheckRollup` maps to ``PullRequestCheckState/RollupState/noChecks``;
    /// a null node, missing commits/nodes, or missing oid simply produces no
    /// entry for that PR (the caller resolves a missing entry as `.unknown`).
    /// Returns `nil` only when the envelope itself is not decodable JSON.
    nonisolated static func decodeCheckStateResponse(
        _ data: Data,
        fetchedAt: Date
    ) -> PullRequestChecksDecodeResult? {
        guard let response = try? JSONDecoder().decode(GraphQLChecksResponse.self, from: data) else {
            return nil
        }

        var checkStatesByNumber: [Int: PullRequestCheckState] = [:]
        for node in (response.data?.repo ?? [:]).values {
            guard let node,
                  let number = node.number,
                  let commit = node.commits?.nodes?.compactMap({ $0?.commit }).first,
                  let oid = commit.oid, !oid.isEmpty else {
                continue
            }
            let rollupState: PullRequestCheckState.RollupState
            if let rollup = commit.statusCheckRollup {
                rollupState = PullRequestCheckState.RollupState(graphQLState: rollup.state)
            } else {
                rollupState = .noChecks
            }
            checkStatesByNumber[number] = PullRequestCheckState(
                headSHA: oid,
                rollupState: rollupState,
                mergeable: node.mergeable,
                mergeStateStatus: node.mergeStateStatus,
                isDraft: node.isDraft ?? false,
                fetchedAt: fetchedAt
            )
        }

        return PullRequestChecksDecodeResult(
            checkStatesByNumber: checkStatesByNumber,
            rateLimitRemaining: response.data?.rateLimit?.remaining,
            hadErrors: !(response.errors ?? []).isEmpty
        )
    }

    // MARK: Stage 2b entry point

    /// Augments one repo cache entry with check states for the tracked PRs
    /// (the candidate branches' REST-selected PRs — never a re-selection).
    ///
    /// Reusable cached states (terminal, or non-terminal and fresh) are served
    /// without a request; only the remainder is queried. Without a token the
    /// GraphQL call is skipped entirely (REST-only neutral, R15). On failure
    /// the reusable states are kept and only a status code / had-errors
    /// boolean is logged — never response bodies or the errors array.
    nonisolated func checksAugmentedEntry(
        repoSlug: String,
        candidateBranches: Set<String>,
        entry: WorkspacePullRequestRepoCacheEntry,
        now: Date,
        session: URLSession,
        authHeader: String?
    ) async -> WorkspacePullRequestRepoCacheEntry {
        // Retain reusable states (including untracked terminal ones, so a
        // rebase-then-revert never flashes a stale color after refetch).
        let retained = entry.checkStatesByHeadSHA.filter {
            Self.isCheckStateReusable($0.value, now: now)
        }

        let targets: [PullRequestCheckProbeTarget] = candidateBranches.compactMap { branch in
            guard let pullRequest = entry.pullRequestsByBranch[branch] else { return nil }
            return PullRequestCheckProbeTarget(
                number: pullRequest.number,
                headSHA: pullRequest.headSHA
            )
        }
        let numbersToFetch = Self.checkStateNumbersNeedingFetch(
            targets: targets,
            cachedCheckStates: entry.checkStatesByHeadSHA,
            now: now
        )
        guard !numbersToFetch.isEmpty else {
            return entry.replacingCheckStates(
                Self.cappedCheckStates(retained),
                rateLimitRemaining: entry.checksRateLimitRemaining
            )
        }

        // No token → skip GraphQL entirely; the header renders neutral (R15).
        guard let authHeader, !authHeader.isEmpty else {
            return entry.replacingCheckStates(
                Self.cappedCheckStates(retained),
                rateLimitRemaining: nil
            )
        }

        guard let query = Self.checkStateQuery(
            repoSlug: repoSlug,
            pullRequestNumbers: numbersToFetch
        ), let request = Self.makeGraphQLRequest(query: query, authHeader: authHeader) else {
            return entry.replacingCheckStates(
                Self.cappedCheckStates(retained),
                rateLimitRemaining: entry.checksRateLimitRemaining
            )
        }

        guard let response = await graphQLRequestRunner(session, request) else {
            debugLog("workspace.prChecks.fail repo=\(repoSlug) prs=\(numbersToFetch.count) status=nil")
            return entry.replacingCheckStates(
                Self.cappedCheckStates(retained),
                rateLimitRemaining: entry.checksRateLimitRemaining
            )
        }
        // Note: the transport surfaces status code + body only, so a 403/429
        // `Retry-After` header cannot be honored here (documented gap); the
        // caller's low-`rateLimit.remaining` backoff is the throttle signal.
        guard response.statusCode == 200,
              let decoded = Self.decodeCheckStateResponse(response.data, fetchedAt: now) else {
            debugLog(
                "workspace.prChecks.fail repo=\(repoSlug) prs=\(numbersToFetch.count) " +
                "status=\(response.statusCode)"
            )
            return entry.replacingCheckStates(
                Self.cappedCheckStates(retained),
                rateLimitRemaining: entry.checksRateLimitRemaining
            )
        }

        var merged = retained
        for state in decoded.checkStatesByNumber.values {
            merged[state.headSHA] = state
        }
        debugLog(
            "workspace.prChecks.fetch repo=\(repoSlug) prs=\(numbersToFetch.count) " +
            "decoded=\(decoded.checkStatesByNumber.count) hadErrors=\(decoded.hadErrors) " +
            "rateRemaining=\(decoded.rateLimitRemaining.map(String.init) ?? "nil")"
        )
        return entry.replacingCheckStates(
            Self.cappedCheckStates(merged),
            rateLimitRemaining: decoded.rateLimitRemaining ?? entry.checksRateLimitRemaining
        )
    }

    /// Caps the retained check-state dictionary at
    /// ``maxRetainedCheckStatesPerRepo``, keeping the newest by `fetchedAt`.
    nonisolated static func cappedCheckStates(
        _ checkStates: [String: PullRequestCheckState]
    ) -> [String: PullRequestCheckState] {
        guard checkStates.count > Self.maxRetainedCheckStatesPerRepo else {
            return checkStates
        }
        let newest = checkStates
            .sorted { $0.value.fetchedAt > $1.value.fetchedAt }
            .prefix(Self.maxRetainedCheckStatesPerRepo)
        return Dictionary(uniqueKeysWithValues: Array(newest))
    }
}

extension WorkspacePullRequestRepoCacheEntry {
    /// A copy of this entry with the check-state fields replaced.
    func replacingCheckStates(
        _ checkStatesByHeadSHA: [String: PullRequestCheckState],
        rateLimitRemaining: Int?
    ) -> WorkspacePullRequestRepoCacheEntry {
        WorkspacePullRequestRepoCacheEntry(
            fetchedAt: fetchedAt,
            pullRequestsByBranch: pullRequestsByBranch,
            knownAbsentBranches: knownAbsentBranches,
            checkStatesByHeadSHA: checkStatesByHeadSHA,
            checksRateLimitRemaining: rateLimitRemaining
        )
    }
}
