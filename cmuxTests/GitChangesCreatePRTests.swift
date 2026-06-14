import CmuxGit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Git changes PR header and Create PR")
struct GitChangesCreatePRTests {

    // MARK: - Helpers

    private func makeSnapshot(
        phase: GitChangesPhase = .ready,
        branch: String? = "feat/topic",
        baseRef: String? = "origin/main",
        files: [GitChangedFile] = [GitChangesCreatePRTests.sampleFile],
        hasGitHubRemote: Bool = true
    ) -> GitChangesSnapshot {
        GitChangesSnapshot(
            phase: phase,
            repoRootPath: "/repo",
            branch: branch,
            baseRef: baseRef,
            mergeBase: "abc123",
            files: files,
            hasGitHubRemote: hasGitHubRemote
        )
    }

    private static let sampleFile = GitChangedFile(
        path: "Sources/File.swift",
        previousPath: nil,
        status: .modified,
        isBinary: false,
        addedLines: 3,
        deletedLines: 1
    )

    private func makePRState(
        number: Int = 42,
        branch: String? = "feat/topic",
        status: SidebarPullRequestStatus = .open
    ) -> SidebarPullRequestState {
        SidebarPullRequestState(
            number: number,
            label: "PR #\(number)",
            url: URL(string: "https://github.com/o/r/pull/\(number)")!,
            status: status,
            branch: branch
        )
    }

    private func makeCheckState(
        _ rollupState: PullRequestCheckState.RollupState
    ) -> PullRequestCheckState {
        PullRequestCheckState(
            headSHA: "deadbeef",
            rollupState: rollupState,
            mergeable: nil,
            mergeStateStatus: nil,
            isDraft: false,
            fetchedAt: Date()
        )
    }

    // MARK: - Color mapping

    @Test(arguments: [
        (PullRequestCheckState.RollupState.success, GitChangesPRTint.green),
        (.pending, .orange),
        (.expected, .orange),
        (.failure, .red),
        (.error, .red),
        (.noChecks, .neutral),
        (.unknown, .neutral),
    ])
    func tintMapsRollupStatesForOpenPRs(
        rollupState: PullRequestCheckState.RollupState,
        expected: GitChangesPRTint
    ) {
        #expect(GitChangesPRHeaderLogic.tint(rollupState: rollupState, prStatus: .open) == expected)
    }

    @Test func nilRollupIsNeutralNeverGreenOrRed() {
        #expect(GitChangesPRHeaderLogic.tint(rollupState: nil, prStatus: .open) == .neutral)
    }

    @Test func mergedAndClosedPRsAreNeutralRegardlessOfRollup() {
        for rollupState in [PullRequestCheckState.RollupState.success, .failure, .pending] {
            #expect(GitChangesPRHeaderLogic.tint(rollupState: rollupState, prStatus: .merged) == .neutral)
            #expect(GitChangesPRHeaderLogic.tint(rollupState: rollupState, prStatus: .closed) == .neutral)
        }
    }

    // MARK: - Header visibility

    @Test func headerVisibleOnFeatureBranchWithGitHubRemoteAndPolling() {
        #expect(GitChangesPRHeaderLogic.isHeaderVisible(
            phase: .ready, branch: "feat/topic", baseRef: "origin/main",
            hasGitHubRemote: true, pollingEnabled: true
        ))
    }

    @Test func headerHiddenOnDefaultBranch() {
        #expect(!GitChangesPRHeaderLogic.isHeaderVisible(
            phase: .ready, branch: "main", baseRef: "origin/main",
            hasGitHubRemote: true, pollingEnabled: true
        ))
        // Local base ref form ("main" with no remote prefix).
        #expect(!GitChangesPRHeaderLogic.isHeaderVisible(
            phase: .ready, branch: "main", baseRef: "main",
            hasGitHubRemote: true, pollingEnabled: true
        ))
        // Multi-component default branch resolved through origin/HEAD.
        #expect(!GitChangesPRHeaderLogic.isHeaderVisible(
            phase: .ready, branch: "release/1.0", baseRef: "origin/release/1.0",
            hasGitHubRemote: true, pollingEnabled: true
        ))
    }

    @Test func headerVisibilityWithConfiguredBaseOverrides() {
        // cmux.changes.base = "myfork/main": on local main, the short-name
        // match treats it as the default branch — hidden.
        #expect(!GitChangesPRHeaderLogic.isHeaderVisible(
            phase: .ready, branch: "main", baseRef: "myfork/main",
            hasGitHubRemote: true, pollingEnabled: true
        ))
        // Feature branch against a fork base — visible.
        #expect(GitChangesPRHeaderLogic.isHeaderVisible(
            phase: .ready, branch: "feat/topic", baseRef: "myfork/main",
            hasGitHubRemote: true, pollingEnabled: true
        ))
        // Slashed LOCAL branch as the configured base: being on the base
        // branch itself hides the header (full-ref match, R14).
        #expect(!GitChangesPRHeaderLogic.isHeaderVisible(
            phase: .ready, branch: "release/2.0", baseRef: "release/2.0",
            hasGitHubRemote: true, pollingEnabled: true
        ))
        // On a branch whose name collides with the base's LAST path
        // component only via multi-slash short-naming, stay visible: the
        // short form of "team/release/2.0" is "release/2.0", not "2.0".
        #expect(GitChangesPRHeaderLogic.isHeaderVisible(
            phase: .ready, branch: "2.0", baseRef: "team/release/2.0",
            hasGitHubRemote: true, pollingEnabled: true
        ))
    }

    @Test func headerHiddenInDegradedMode() {
        #expect(!GitChangesPRHeaderLogic.isHeaderVisible(
            phase: .degraded, branch: "feat/topic", baseRef: nil,
            hasGitHubRemote: true, pollingEnabled: true
        ))
    }

    @Test func headerHiddenWithoutGitHubRemote() {
        #expect(!GitChangesPRHeaderLogic.isHeaderVisible(
            phase: .ready, branch: "feat/topic", baseRef: "origin/main",
            hasGitHubRemote: false, pollingEnabled: true
        ))
    }

    @Test func headerHiddenWhenPollingDisabled() {
        #expect(!GitChangesPRHeaderLogic.isHeaderVisible(
            phase: .ready, branch: "feat/topic", baseRef: "origin/main",
            hasGitHubRemote: true, pollingEnabled: false
        ))
    }

    @Test func headerHiddenOnDetachedHEAD() {
        #expect(!GitChangesPRHeaderLogic.isHeaderVisible(
            phase: .ready, branch: "HEAD", baseRef: "origin/main",
            hasGitHubRemote: true, pollingEnabled: true
        ))
        #expect(!GitChangesPRHeaderLogic.isHeaderVisible(
            phase: .ready, branch: nil, baseRef: "origin/main",
            hasGitHubRemote: true, pollingEnabled: true
        ))
    }

    @Test func defaultBranchShortNameStripsRemotePrefixOnly() {
        #expect(GitChangesPRHeaderLogic.defaultBranchShortName(baseRef: "origin/main") == "main")
        #expect(GitChangesPRHeaderLogic.defaultBranchShortName(baseRef: "main") == "main")
        #expect(GitChangesPRHeaderLogic.defaultBranchShortName(baseRef: "origin/release/1.0") == "release/1.0")
    }

    // MARK: - PR resolution per branch

    @Test func resolvedPullRequestMatchesCurrentBranchOnly() {
        let panelId = UUID()
        let prs = [panelId: makePRState(branch: "feat/topic")]
        let resolved = GitChangesPRHeaderLogic.resolvedPullRequest(
            panelPullRequests: prs, branch: "feat/topic", focusedPanelId: nil
        )
        #expect(resolved?.panelId == panelId)
        #expect(resolved?.state.number == 42)

        // A PR tracked for a DIFFERENT branch never matches.
        let other = GitChangesPRHeaderLogic.resolvedPullRequest(
            panelPullRequests: prs, branch: "other-branch", focusedPanelId: nil
        )
        #expect(other == nil)
    }

    @Test func resolvedPullRequestIgnoresClosedAndStaleMergedPRs() {
        let panelId = UUID()
        let closed = GitChangesPRHeaderLogic.resolvedPullRequest(
            panelPullRequests: [panelId: makePRState(status: .closed)],
            branch: "feat/topic",
            focusedPanelId: panelId
        )
        #expect(closed == nil)

        let mergedFresh = GitChangesPRHeaderLogic.resolvedPullRequest(
            panelPullRequests: [panelId: makePRState(status: .merged)],
            branch: "feat/topic",
            focusedPanelId: panelId
        )
        #expect(mergedFresh != nil)

        let staleMergedState = SidebarPullRequestState(
            number: 42,
            label: "PR #42",
            url: URL(string: "https://github.com/o/r/pull/42")!,
            status: .merged,
            branch: "feat/topic",
            isStale: true
        )
        let mergedStale = GitChangesPRHeaderLogic.resolvedPullRequest(
            panelPullRequests: [panelId: staleMergedState],
            branch: "feat/topic",
            focusedPanelId: panelId
        )
        #expect(mergedStale == nil)
    }

    @Test func resolvedPullRequestPrefersFocusedPanel() {
        let focusedPanelId = UUID()
        let otherPanelId = UUID()
        let prs = [
            focusedPanelId: makePRState(number: 7, branch: "feat/topic"),
            otherPanelId: makePRState(number: 8, branch: "feat/topic"),
        ]
        let resolved = GitChangesPRHeaderLogic.resolvedPullRequest(
            panelPullRequests: prs, branch: "feat/topic", focusedPanelId: focusedPanelId
        )
        #expect(resolved?.panelId == focusedPanelId)
        #expect(resolved?.state.number == 7)
    }

    // MARK: - Create PR target selection

    @Test func focusedAgentPanelWinsRegardlessOfRecency() {
        let focused = UUID()
        let recent = UUID()
        let candidates = [
            GitChangesCreatePRLogic.AgentPanelCandidate(panelId: focused, lastActivityAt: Date(timeIntervalSince1970: 10)),
            GitChangesCreatePRLogic.AgentPanelCandidate(panelId: recent, lastActivityAt: Date(timeIntervalSince1970: 1000)),
        ]
        #expect(GitChangesCreatePRLogic.targetPanelId(candidates: candidates, focusedPanelId: focused) == focused)
    }

    @Test func focusedShellFallsBackToMostRecentAgent() {
        let shellPanelId = UUID() // never a candidate: shells own no agent PID keys
        let older = UUID()
        let newer = UUID()
        let candidates = [
            GitChangesCreatePRLogic.AgentPanelCandidate(panelId: older, lastActivityAt: Date(timeIntervalSince1970: 10)),
            GitChangesCreatePRLogic.AgentPanelCandidate(panelId: newer, lastActivityAt: Date(timeIntervalSince1970: 1000)),
        ]
        #expect(GitChangesCreatePRLogic.targetPanelId(candidates: candidates, focusedPanelId: shellPanelId) == newer)
    }

    @Test func agentWithoutActivityRanksBelowDatedAgent() {
        let dated = UUID()
        let undated = UUID()
        let candidates = [
            GitChangesCreatePRLogic.AgentPanelCandidate(panelId: undated, lastActivityAt: nil),
            GitChangesCreatePRLogic.AgentPanelCandidate(panelId: dated, lastActivityAt: Date(timeIntervalSince1970: 5)),
        ]
        #expect(GitChangesCreatePRLogic.targetPanelId(candidates: candidates, focusedPanelId: nil) == dated)
    }

    @Test func noAgentCandidatesReturnsNil() {
        #expect(GitChangesCreatePRLogic.targetPanelId(candidates: [], focusedPanelId: UUID()) == nil)
    }

    @Test func tieBreaksDeterministicallyByPanelId() {
        let date = Date(timeIntervalSince1970: 50)
        let a = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let b = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let candidates = [
            GitChangesCreatePRLogic.AgentPanelCandidate(panelId: b, lastActivityAt: date),
            GitChangesCreatePRLogic.AgentPanelCandidate(panelId: a, lastActivityAt: date),
        ]
        let first = GitChangesCreatePRLogic.targetPanelId(candidates: candidates, focusedPanelId: nil)
        let second = GitChangesCreatePRLogic.targetPanelId(candidates: candidates.reversed(), focusedPanelId: nil)
        #expect(first == a)
        #expect(second == a)
    }

    // MARK: - Header state builder

    @Test func builderProducesPillWhenPRExistsForBranch() {
        let panelId = UUID()
        let state = GitChangesPRHeaderState.make(
            snapshot: makeSnapshot(),
            panelPullRequests: [panelId: makePRState()],
            checkStatesByPanel: [panelId: makeCheckState(.success)],
            focusedPanelId: nil,
            agentCandidates: [],
            createPRPending: false,
            pollingEnabled: true
        )
        guard case .pullRequest(let pill)? = state?.content else {
            Issue.record("expected pull request pill, got \(String(describing: state))")
            return
        }
        #expect(pill.number == 42)
        #expect(pill.tint == .green)
        #expect(pill.rollupState == .success)
    }

    @Test func builderPillIsNeutralWithoutCheckState() {
        let panelId = UUID()
        let state = GitChangesPRHeaderState.make(
            snapshot: makeSnapshot(),
            panelPullRequests: [panelId: makePRState()],
            checkStatesByPanel: [:],
            focusedPanelId: nil,
            agentCandidates: [],
            createPRPending: false,
            pollingEnabled: true
        )
        guard case .pullRequest(let pill)? = state?.content else {
            Issue.record("expected pull request pill")
            return
        }
        #expect(pill.tint == .neutral)
    }

    @Test func builderProducesEnabledCreatePRWithAgent() {
        let agentPanelId = UUID()
        let state = GitChangesPRHeaderState.make(
            snapshot: makeSnapshot(),
            panelPullRequests: [:],
            checkStatesByPanel: [:],
            focusedPanelId: nil,
            agentCandidates: [.init(panelId: agentPanelId, lastActivityAt: nil)],
            createPRPending: false,
            pollingEnabled: true
        )
        #expect(state?.content == .createPR(.enabled(targetPanelId: agentPanelId)))
    }

    @Test func builderDisablesCreatePRWithoutAgentTerminal() {
        let state = GitChangesPRHeaderState.make(
            snapshot: makeSnapshot(),
            panelPullRequests: [:],
            checkStatesByPanel: [:],
            focusedPanelId: nil,
            agentCandidates: [],
            createPRPending: false,
            pollingEnabled: true
        )
        #expect(state?.content == .createPR(.noAgentTerminal))
    }

    @Test func builderShowsPromptSentWhilePending() {
        let state = GitChangesPRHeaderState.make(
            snapshot: makeSnapshot(),
            panelPullRequests: [:],
            checkStatesByPanel: [:],
            focusedPanelId: nil,
            agentCandidates: [.init(panelId: UUID(), lastActivityAt: nil)],
            createPRPending: true,
            pollingEnabled: true
        )
        #expect(state?.content == .createPR(.promptSent))
    }

    @Test func builderHidesCreatePRWhenBranchHasNoChanges() {
        let state = GitChangesPRHeaderState.make(
            snapshot: makeSnapshot(files: []),
            panelPullRequests: [:],
            checkStatesByPanel: [:],
            focusedPanelId: nil,
            agentCandidates: [.init(panelId: UUID(), lastActivityAt: nil)],
            createPRPending: false,
            pollingEnabled: true
        )
        #expect(state == nil)
    }

    @Test func builderHidesEverythingOnDefaultBranchEvenWithPR() {
        let panelId = UUID()
        let state = GitChangesPRHeaderState.make(
            snapshot: makeSnapshot(branch: "main"),
            panelPullRequests: [panelId: makePRState(branch: "main")],
            checkStatesByPanel: [:],
            focusedPanelId: nil,
            agentCandidates: [],
            createPRPending: false,
            pollingEnabled: true
        )
        #expect(state == nil)
    }

    // MARK: - Pending lifecycle (store)

    @MainActor
    @Test func sendMarksPendingAndDispatchesPromptOnce() {
        let store = GitChangesStore()
        var sent: [(workspaceId: UUID, surfaceId: UUID, text: String)] = []
        let workspaceId = UUID()
        let surfaceId = UUID()

        let first = store.sendCreatePRPrompt(
            workspaceId: workspaceId, agentSurfaceId: surfaceId, timeout: 60
        ) { workspaceId, surfaceId, text in
            sent.append((workspaceId, surfaceId, text))
        }
        #expect(first)
        #expect(store.createPRPending)
        #expect(sent.count == 1)
        #expect(sent.first?.workspaceId == workspaceId)
        #expect(sent.first?.surfaceId == surfaceId)
        #expect(sent.first?.text == GitChangesCreatePRLogic.promptText)

        // Double-click / second window: pending blocks a duplicate send.
        let second = store.sendCreatePRPrompt(
            workspaceId: workspaceId, agentSurfaceId: surfaceId, timeout: 60
        ) { workspaceId, surfaceId, text in
            sent.append((workspaceId, surfaceId, text))
        }
        #expect(!second)
        #expect(sent.count == 1)
        // Clear through the public reconcile path (the mutators are private;
        // sendCreatePRPrompt/reconcile/timeout are the only mutation paths).
        store.reconcileCreatePRPending(pullRequestExistsForCurrentBranch: true)
    }

    @MainActor
    @Test func pendingClearsOnPRForCurrentBranchButNotOtherBranch() {
        let store = GitChangesStore()
        store.sendCreatePRPrompt(workspaceId: UUID(), agentSurfaceId: UUID(), timeout: 60) { _, _, _ in }
        #expect(store.createPRPending)

        // Poll reported a PR, but only for a different branch: keep pending.
        store.reconcileCreatePRPending(pullRequestExistsForCurrentBranch: false)
        #expect(store.createPRPending)

        // Poll reported a PR for the CURRENT branch: clear.
        store.reconcileCreatePRPending(pullRequestExistsForCurrentBranch: true)
        #expect(!store.createPRPending)
    }

    @MainActor
    @Test func pendingClearsAfterTimeout() async {
        let store = GitChangesStore()
        store.sendCreatePRPrompt(workspaceId: UUID(), agentSurfaceId: UUID(), timeout: 0.05) { _, _, _ in }
        #expect(store.createPRPending)

        let deadline = Date().addingTimeInterval(3)
        while store.createPRPending && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(!store.createPRPending)
    }

    @MainActor
    @Test func reconcileWithoutPendingIsANoOp() {
        let store = GitChangesStore()
        store.reconcileCreatePRPending(pullRequestExistsForCurrentBranch: true)
        #expect(!store.createPRPending)
    }

    // MARK: - Prompt text safety

    @Test func promptTextHasNoInterpolationOrFormatSpecifiers() {
        let prompt = GitChangesCreatePRLogic.promptText
        #expect(!prompt.isEmpty)
        // Security review constraint: a fixed constant with no format
        // specifiers and no repo-derived strings (branch names are
        // attacker-influencable and would be typed into the agent terminal).
        #expect(!prompt.contains("%"))
        #expect(!prompt.contains("$("))
        #expect(!prompt.contains("`"))
        #expect(prompt.contains("current branch"))
        #expect(prompt.contains("pull request"))
    }

    @MainActor
    @Test func dispatchedPromptIsExactlyTheConstant() {
        // Proves the send path performs no composition/interpolation on top
        // of the constant (e.g. no branch name appended).
        let store = GitChangesStore()
        var dispatchedText: String?
        store.sendCreatePRPrompt(workspaceId: UUID(), agentSurfaceId: UUID(), timeout: 60) { _, _, text in
            dispatchedText = text
        }
        #expect(dispatchedText == GitChangesCreatePRLogic.promptText)
        store.reconcileCreatePRPending(pullRequestExistsForCurrentBranch: true)
    }
}
