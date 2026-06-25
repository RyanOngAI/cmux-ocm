import CmuxProcess
import Foundation
import Testing
@testable import CmuxGit

/// Records every GraphQL request the probe issues and replays stubbed
/// responses in order (nil once the stubs run out).
private actor GraphQLRequestRecorder {
    private(set) var requests: [URLRequest] = []
    private var stubbedResponses: [WorkspacePullRequestHTTPResponse?]

    init(stubbedResponses: [WorkspacePullRequestHTTPResponse?] = []) {
        self.stubbedResponses = stubbedResponses
    }

    func record(_ request: URLRequest) -> WorkspacePullRequestHTTPResponse? {
        requests.append(request)
        guard !stubbedResponses.isEmpty else { return nil }
        return stubbedResponses.removeFirst()
    }
}

/// A command runner that must never be reached by these tests.
private struct UnusedCommandRunner: CommandRunning {
    func run(
        directory: String,
        executable: String,
        arguments: [String],
        timeout: TimeInterval?
    ) async -> CommandResult {
        Issue.record("command runner unexpectedly invoked: \(executable) \(arguments)")
        return CommandResult(
            stdout: nil,
            stderr: nil,
            exitStatus: 1,
            timedOut: false,
            executionError: "unused"
        )
    }
}

/// Stage 2b: GraphQL check-state probe — decoding, query building, cache
/// policy, no-token skip, and resolution correlation by head SHA.
@Suite struct PullRequestCheckStateProbeTests {
    private let session = URLSession(configuration: .ephemeral)

    private func makeService(recorder: GraphQLRequestRecorder) -> PullRequestProbeService {
        PullRequestProbeService(
            commandRunner: UnusedCommandRunner(),
            debugLog: { _ in },
            graphQLRequestRunner: { _, request in await recorder.record(request) }
        )
    }

    private func probeItem(number: Int, branch: String, headSHA: String?) -> GitHubPullRequestProbeItem {
        GitHubPullRequestProbeItem(
            number: number,
            state: "OPEN",
            url: "https://github.com/o/r/pull/\(number)",
            updatedAt: "2026-06-11T00:00:00Z",
            headRefName: branch,
            headSHA: headSHA
        )
    }

    private func checkState(
        sha: String,
        rollup: PullRequestCheckState.RollupState,
        fetchedAt: Date
    ) -> PullRequestCheckState {
        PullRequestCheckState(
            headSHA: sha,
            rollupState: rollup,
            mergeable: "MERGEABLE",
            mergeStateStatus: "CLEAN",
            isDraft: false,
            fetchedAt: fetchedAt
        )
    }

    private func rollupResponseJSON(
        number: Int,
        oid: String,
        rollupJSON: String,
        mergeable: String = "MERGEABLE",
        mergeStateStatus: String = "CLEAN",
        isDraft: Bool = false,
        rateLimitRemaining: Int = 4999
    ) -> String {
        """
        {
          "data": {
            "repo": {
              "pr\(number)": {
                "number": \(number),
                "isDraft": \(isDraft),
                "mergeable": "\(mergeable)",
                "mergeStateStatus": "\(mergeStateStatus)",
                "commits": {
                  "nodes": [
                    { "commit": { "oid": "\(oid)", "statusCheckRollup": \(rollupJSON) } }
                  ]
                }
              }
            },
            "rateLimit": { "remaining": \(rateLimitRemaining), "resetAt": "2026-06-11T01:00:00Z" }
          }
        }
        """
    }

    // MARK: Decoding

    @Test(arguments: [
        ("SUCCESS", PullRequestCheckState.RollupState.success),
        ("PENDING", .pending),
        ("EXPECTED", .expected),
        ("FAILURE", .failure),
        ("ERROR", .error),
    ])
    func decodesRollupStates(raw: String, expected: PullRequestCheckState.RollupState) throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_000)
        let json = rollupResponseJSON(number: 7, oid: "abc123", rollupJSON: "{\"state\": \"\(raw)\"}")
        let decoded = try #require(
            PullRequestProbeService.decodeCheckStateResponse(Data(json.utf8), fetchedAt: fetchedAt)
        )
        let state = try #require(decoded.checkStatesByNumber[7])
        #expect(state.rollupState == expected)
        #expect(state.headSHA == "abc123")
        #expect(state.fetchedAt == fetchedAt)
        #expect(decoded.rateLimitRemaining == 4999)
        #expect(!decoded.hadErrors)
    }

    @Test func nullRollupDecodesToNoChecks() throws {
        let json = rollupResponseJSON(number: 7, oid: "abc123", rollupJSON: "null")
        let decoded = try #require(
            PullRequestProbeService.decodeCheckStateResponse(Data(json.utf8), fetchedAt: Date())
        )
        #expect(decoded.checkStatesByNumber[7]?.rollupState == .noChecks)
    }

    @Test func unrecognizedRollupStateDecodesToUnknown() throws {
        let json = rollupResponseJSON(number: 7, oid: "abc123", rollupJSON: "{\"state\": \"SOMETHING_NEW\"}")
        let decoded = try #require(
            PullRequestProbeService.decodeCheckStateResponse(Data(json.utf8), fetchedAt: Date())
        )
        #expect(decoded.checkStatesByNumber[7]?.rollupState == .unknown)
    }

    @Test func mergeableUnknownDraftAndMergeStateStatusPassThrough() throws {
        let json = rollupResponseJSON(
            number: 7,
            oid: "abc123",
            rollupJSON: "{\"state\": \"SUCCESS\"}",
            mergeable: "UNKNOWN",
            mergeStateStatus: "BLOCKED",
            isDraft: true
        )
        let decoded = try #require(
            PullRequestProbeService.decodeCheckStateResponse(Data(json.utf8), fetchedAt: Date())
        )
        let state = try #require(decoded.checkStatesByNumber[7])
        #expect(state.mergeable == "UNKNOWN")
        #expect(state.mergeStateStatus == "BLOCKED")
        #expect(state.isDraft)
    }

    @Test func errorsArrayWithNullNodeYieldsNoEntryAndHadErrors() throws {
        let json = """
        {
          "data": { "repo": { "pr7": null }, "rateLimit": { "remaining": 12 } },
          "errors": [ { "type": "FORBIDDEN", "message": "redacted" } ]
        }
        """
        let decoded = try #require(
            PullRequestProbeService.decodeCheckStateResponse(Data(json.utf8), fetchedAt: Date())
        )
        #expect(decoded.checkStatesByNumber.isEmpty)
        #expect(decoded.hadErrors)
        #expect(decoded.rateLimitRemaining == 12)
    }

    @Test func missingCommitNodesYieldsNoEntry() throws {
        let json = """
        {
          "data": {
            "repo": {
              "pr7": {
                "number": 7, "isDraft": false, "mergeable": "MERGEABLE",
                "mergeStateStatus": "CLEAN", "commits": { "nodes": [] }
              }
            },
            "rateLimit": { "remaining": 100 }
          }
        }
        """
        let decoded = try #require(
            PullRequestProbeService.decodeCheckStateResponse(Data(json.utf8), fetchedAt: Date())
        )
        #expect(decoded.checkStatesByNumber.isEmpty)
        #expect(!decoded.hadErrors)
    }

    @Test func restItemDecodesHeadSHA() throws {
        let json = """
        [
          {
            "number": 9,
            "state": "open",
            "html_url": "https://github.com/o/r/pull/9",
            "updated_at": "2026-06-11T00:00:00Z",
            "merged_at": null,
            "head": {"ref": "feat/x", "sha": "deadbeef"},
            "base": {"ref": "main", "sha": "cafef00d"}
          }
        ]
        """
        let rest = try #require(
            PullRequestProbeService.decodeJSON([WorkspacePullRequestRESTItem].self, from: Data(json.utf8))
        )
        let item = PullRequestProbeService.probeItem(from: rest[0])
        #expect(item.headSHA == "deadbeef")
    }

    // MARK: Query + request builders

    @Test func queryBuilderCoversOnlyTrackedNumbersWithWellFormedAliases() throws {
        let query = try #require(
            PullRequestProbeService.checkStateQuery(
                repoSlug: "manaflow-ai/cmux",
                pullRequestNumbers: [5876, 12, 5876]
            )
        )
        #expect(query.contains("repository(owner: \"manaflow-ai\", name: \"cmux\")"))
        #expect(query.contains("pr12: pullRequest(number: 12)"))
        #expect(query.contains("pr5876: pullRequest(number: 5876)"))
        // Duplicates collapse to one alias.
        #expect(query.components(separatedBy: "pr5876:").count == 2)
        #expect(query.contains("statusCheckRollup { state }"))
        #expect(query.contains("rateLimit { remaining resetAt }"))
        #expect(!query.contains("pr999"))
    }

    @Test func queryBuilderRejectsMalformedAndUnsafeSlugs() {
        #expect(PullRequestProbeService.checkStateQuery(repoSlug: "no-slash", pullRequestNumbers: [1]) == nil)
        #expect(PullRequestProbeService.checkStateQuery(repoSlug: "/missing-owner", pullRequestNumbers: [1]) == nil)
        #expect(PullRequestProbeService.checkStateQuery(repoSlug: "o\"x/r", pullRequestNumbers: [1]) == nil)
        #expect(PullRequestProbeService.checkStateQuery(repoSlug: "o/r\\evil", pullRequestNumbers: [1]) == nil)
        #expect(PullRequestProbeService.checkStateQuery(repoSlug: "o/r", pullRequestNumbers: []) == nil)
    }

    @Test func graphQLRequestUsesLiteralEndpointPOSTAndJSONHeaders() throws {
        let request = try #require(
            PullRequestProbeService.makeGraphQLRequest(query: "query { rateLimit { remaining } }", authHeader: "Bearer token-x")
        )
        #expect(request.url?.absoluteString == "https://api.github.com/graphql")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token-x")
        let body = try #require(request.httpBody)
        let payload = try #require(
            try JSONSerialization.jsonObject(with: body) as? [String: String]
        )
        #expect(payload["query"] == "query { rateLimit { remaining } }")

        let anonymous = try #require(
            PullRequestProbeService.makeGraphQLRequest(query: "query {}", authHeader: nil)
        )
        #expect(anonymous.value(forHTTPHeaderField: "Authorization") == nil)
    }

    // MARK: Cache policy

    @Test func terminalCheckStateIsReusableBeyondCacheLifetime() {
        let now = Date(timeIntervalSince1970: 10_000)
        let old = checkState(sha: "aaa", rollup: .success, fetchedAt: now.addingTimeInterval(-3_600))
        #expect(PullRequestProbeService.isCheckStateReusable(old, now: now))
        let numbers = PullRequestProbeService.checkStateNumbersNeedingFetch(
            targets: [.init(number: 7, headSHA: "aaa")],
            cachedCheckStates: ["aaa": old],
            now: now
        )
        #expect(numbers.isEmpty)
    }

    @Test func pendingCheckStateGoesStaleAfterCacheLifetime() {
        let now = Date(timeIntervalSince1970: 10_000)
        let stalePending = checkState(sha: "aaa", rollup: .pending, fetchedAt: now.addingTimeInterval(-30))
        let freshPending = checkState(sha: "bbb", rollup: .pending, fetchedAt: now.addingTimeInterval(-5))
        #expect(!PullRequestProbeService.isCheckStateReusable(stalePending, now: now))
        #expect(PullRequestProbeService.isCheckStateReusable(freshPending, now: now))
        let numbers = PullRequestProbeService.checkStateNumbersNeedingFetch(
            targets: [.init(number: 7, headSHA: "aaa"), .init(number: 8, headSHA: "bbb")],
            cachedCheckStates: ["aaa": stalePending, "bbb": freshPending],
            now: now
        )
        #expect(numbers == [7])
    }

    @Test func headSHAChangeInvalidatesImmediately() {
        let now = Date(timeIntervalSince1970: 10_000)
        // A terminal state for the OLD SHA must not satisfy the NEW SHA.
        let oldTerminal = checkState(sha: "old-sha", rollup: .success, fetchedAt: now.addingTimeInterval(-2))
        let numbers = PullRequestProbeService.checkStateNumbersNeedingFetch(
            targets: [.init(number: 7, headSHA: "new-sha")],
            cachedCheckStates: ["old-sha": oldTerminal],
            now: now
        )
        #expect(numbers == [7])
    }

    // MARK: No-token skip

    @Test func noTokenSkipsGraphQLEntirely() async {
        let recorder = GraphQLRequestRecorder()
        let service = makeService(recorder: recorder)
        let entry = WorkspacePullRequestRepoCacheEntry(
            fetchedAt: Date(),
            pullRequestsByBranch: ["feat/x": probeItem(number: 7, branch: "feat/x", headSHA: "aaa")]
        )
        let augmented = await service.checksAugmentedEntry(
            repoSlug: "o/r",
            candidateBranches: ["feat/x"],
            entry: entry,
            now: Date(),
            session: session,
            authHeader: nil
        )
        #expect(augmented.checkStatesByHeadSHA.isEmpty)
        #expect(await recorder.requests.isEmpty)
    }

    // MARK: Stage 2b fetch + cache behavior

    @Test func augmentedEntryFetchesStoresAndServesTerminalFromCache() async throws {
        let now = Date(timeIntervalSince1970: 50_000)
        let json = rollupResponseJSON(number: 7, oid: "aaa", rollupJSON: "{\"state\": \"SUCCESS\"}", rateLimitRemaining: 4321)
        let recorder = GraphQLRequestRecorder(stubbedResponses: [
            WorkspacePullRequestHTTPResponse(statusCode: 200, data: Data(json.utf8)),
        ])
        let service = makeService(recorder: recorder)
        let entry = WorkspacePullRequestRepoCacheEntry(
            fetchedAt: now,
            pullRequestsByBranch: ["feat/x": probeItem(number: 7, branch: "feat/x", headSHA: "aaa")]
        )

        let augmented = await service.checksAugmentedEntry(
            repoSlug: "o/r",
            candidateBranches: ["feat/x"],
            entry: entry,
            now: now,
            session: session,
            authHeader: "Bearer t"
        )
        #expect(await recorder.requests.count == 1)
        #expect(augmented.checkStatesByHeadSHA["aaa"]?.rollupState == .success)
        #expect(augmented.checksRateLimitRemaining == 4321)

        // Terminal state at the same SHA is served well beyond the 15s repo
        // cache lifetime without another GraphQL call.
        let later = now.addingTimeInterval(600)
        let reAugmented = await service.checksAugmentedEntry(
            repoSlug: "o/r",
            candidateBranches: ["feat/x"],
            entry: augmented,
            now: later,
            session: session,
            authHeader: "Bearer t"
        )
        #expect(await recorder.requests.count == 1)
        #expect(reAugmented.checkStatesByHeadSHA["aaa"]?.rollupState == .success)
    }

    @Test func augmentedEntryRefetchesStalePendingAtSameSHA() async throws {
        let now = Date(timeIntervalSince1970: 50_000)
        let pendingJSON = rollupResponseJSON(number: 7, oid: "aaa", rollupJSON: "{\"state\": \"PENDING\"}")
        let successJSON = rollupResponseJSON(number: 7, oid: "aaa", rollupJSON: "{\"state\": \"SUCCESS\"}")
        let recorder = GraphQLRequestRecorder(stubbedResponses: [
            WorkspacePullRequestHTTPResponse(statusCode: 200, data: Data(pendingJSON.utf8)),
            WorkspacePullRequestHTTPResponse(statusCode: 200, data: Data(successJSON.utf8)),
        ])
        let service = makeService(recorder: recorder)
        let entry = WorkspacePullRequestRepoCacheEntry(
            fetchedAt: now,
            pullRequestsByBranch: ["feat/x": probeItem(number: 7, branch: "feat/x", headSHA: "aaa")]
        )

        let first = await service.checksAugmentedEntry(
            repoSlug: "o/r", candidateBranches: ["feat/x"], entry: entry,
            now: now, session: session, authHeader: "Bearer t"
        )
        #expect(first.checkStatesByHeadSHA["aaa"]?.rollupState == .pending)

        // Within the lifetime the pending state is reused (no second call)…
        let soon = now.addingTimeInterval(5)
        let reused = await service.checksAugmentedEntry(
            repoSlug: "o/r", candidateBranches: ["feat/x"], entry: first,
            now: soon, session: session, authHeader: "Bearer t"
        )
        #expect(await recorder.requests.count == 1)
        #expect(reused.checkStatesByHeadSHA["aaa"]?.rollupState == .pending)

        // …and beyond the lifetime it is refetched.
        let later = now.addingTimeInterval(30)
        let refetched = await service.checksAugmentedEntry(
            repoSlug: "o/r", candidateBranches: ["feat/x"], entry: first,
            now: later, session: session, authHeader: "Bearer t"
        )
        #expect(await recorder.requests.count == 2)
        #expect(refetched.checkStatesByHeadSHA["aaa"]?.rollupState == .success)
    }

    @Test func augmentedEntryKeepsReusableStatesWhenFetchFails() async {
        let now = Date(timeIntervalSince1970: 50_000)
        let recorder = GraphQLRequestRecorder(stubbedResponses: [nil])
        let service = makeService(recorder: recorder)
        let terminal = checkState(sha: "aaa", rollup: .failure, fetchedAt: now.addingTimeInterval(-3_600))
        let entry = WorkspacePullRequestRepoCacheEntry(
            fetchedAt: now,
            pullRequestsByBranch: [
                "feat/x": probeItem(number: 7, branch: "feat/x", headSHA: "aaa"),
                "feat/y": probeItem(number: 8, branch: "feat/y", headSHA: "bbb"),
            ],
            checkStatesByHeadSHA: ["aaa": terminal]
        )
        let augmented = await service.checksAugmentedEntry(
            repoSlug: "o/r", candidateBranches: ["feat/x", "feat/y"], entry: entry,
            now: now, session: session, authHeader: "Bearer t"
        )
        // The transport failure leaves the reusable terminal state intact and
        // simply yields no entry (→ unknown) for the un-fetched PR.
        #expect(augmented.checkStatesByHeadSHA["aaa"]?.rollupState == .failure)
        #expect(augmented.checkStatesByHeadSHA["bbb"] == nil)
    }

    // MARK: Resolution correlation (stale-green guard)

    @Test func resolveRefreshResultsAttachesCheckStateForMatchingHeadSHAOnly() throws {
        let workspaceId = UUID()
        let panelId = UUID()
        let now = Date()
        let entry = WorkspacePullRequestRepoCacheEntry(
            fetchedAt: now,
            pullRequestsByBranch: ["feat/x": probeItem(number: 7, branch: "feat/x", headSHA: "aaa")],
            checkStatesByHeadSHA: ["aaa": checkState(sha: "aaa", rollup: .success, fetchedAt: now)]
        )
        let results = PullRequestProbeService.resolveRefreshResults(
            candidates: [
                WorkspacePullRequestCandidate(
                    workspaceId: workspaceId, panelId: panelId, branch: "feat/x", repoSlugs: ["o/r"]
                ),
            ],
            repoResults: ["o/r": .success(entry, usedCache: false, transientBranches: [])]
        )
        guard case .resolved(let resolved) = results[0].resolution else {
            Issue.record("expected resolved, got \(results[0].resolution)")
            return
        }
        #expect(resolved.checkState?.rollupState == .success)
        #expect(resolved.checkState?.headSHA == "aaa")
    }

    @Test func resolveRefreshResultsDropsCheckStateWhenHeadSHAMoved() throws {
        let workspaceId = UUID()
        let panelId = UUID()
        let now = Date()
        // REST now reports head SHA "bbb" but the cached (terminal, green)
        // check state belongs to the older "aaa": the stale green must never
        // surface — the resolved item carries no check state (unknown).
        let entry = WorkspacePullRequestRepoCacheEntry(
            fetchedAt: now,
            pullRequestsByBranch: ["feat/x": probeItem(number: 7, branch: "feat/x", headSHA: "bbb")],
            checkStatesByHeadSHA: ["aaa": checkState(sha: "aaa", rollup: .success, fetchedAt: now)]
        )
        let results = PullRequestProbeService.resolveRefreshResults(
            candidates: [
                WorkspacePullRequestCandidate(
                    workspaceId: workspaceId, panelId: panelId, branch: "feat/x", repoSlugs: ["o/r"]
                ),
            ],
            repoResults: ["o/r": .success(entry, usedCache: false, transientBranches: [])]
        )
        guard case .resolved(let resolved) = results[0].resolution else {
            Issue.record("expected resolved, got \(results[0].resolution)")
            return
        }
        #expect(resolved.checkState == nil)
    }
}
