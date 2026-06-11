import AppKit
import CmuxGit
import SwiftUI

// MARK: - Formatting helpers

/// Pure formatting helpers for the Changes panel, kept off the view types so
/// they are unit-testable without rendering.
nonisolated enum GitChangesPanelFormatting {
    /// "1 file" / "%lld files" totals fragment.
    static func totalsFilesText(count: Int) -> String {
        if count == 1 {
            return String(localized: "changes.totals.fileSingular", defaultValue: "1 file")
        }
        return String.localizedStringWithFormat(
            String(localized: "changes.totals.files", defaultValue: "%lld files"),
            count
        )
    }

    /// Last path component; renames render "old → new" (last components).
    static func displayName(for file: GitChangedFile) -> String {
        let name = lastComponent(of: file.path)
        guard let previousPath = file.previousPath else { return name }
        return "\(lastComponent(of: previousPath)) → \(name)"
    }

    /// Directory portion of the current path, empty for root-level files.
    static func directoryText(for file: GitChangedFile) -> String {
        guard let slash = file.path.lastIndex(of: "/") else { return "" }
        return String(file.path[file.path.startIndex..<slash])
    }

    /// Full repo-relative path for the row tooltip; renames render
    /// "old → new" with full paths.
    static func fullPathTooltip(for file: GitChangedFile) -> String {
        guard let previousPath = file.previousPath else { return file.path }
        return "\(previousPath) → \(file.path)"
    }

    /// Localized human-readable status name (also used for accessibility).
    static func statusDescription(for status: GitChangedFileStatus) -> String {
        switch status {
        case .added:
            return String(localized: "changes.status.added", defaultValue: "Added")
        case .modified:
            return String(localized: "changes.status.modified", defaultValue: "Modified")
        case .deleted:
            return String(localized: "changes.status.deleted", defaultValue: "Deleted")
        case .renamed:
            return String(localized: "changes.status.renamed", defaultValue: "Renamed")
        case .copied:
            return String(localized: "changes.status.copied", defaultValue: "Copied")
        case .typeChanged:
            return String(localized: "changes.status.typeChanged", defaultValue: "Type changed")
        case .untracked:
            return String(localized: "changes.status.untracked", defaultValue: "Untracked")
        case .conflicted:
            return String(localized: "changes.status.conflicted", defaultValue: "Conflicted")
        case .submodule:
            return String(localized: "changes.status.submodule", defaultValue: "Submodule")
        }
    }

    /// "path, status, N added, M deleted" accessibility label per row.
    static func accessibilityLabel(for file: GitChangedFile) -> String {
        let status = statusDescription(for: file.status)
        guard let added = file.addedLines, let deleted = file.deletedLines else {
            return String.localizedStringWithFormat(
                String(localized: "changes.row.accessibility.noCounts", defaultValue: "%1$@, %2$@"),
                file.path,
                status
            )
        }
        return String.localizedStringWithFormat(
            String(
                localized: "changes.row.accessibility.withCounts",
                defaultValue: "%1$@, %2$@, %3$lld added, %4$lld deleted"
            ),
            file.path,
            status,
            added,
            deleted
        )
    }

    private static func lastComponent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }

    // MARK: PR header strings

    /// "PR #%lld" pill title.
    static func prPillTitle(number: Int) -> String {
        String.localizedStringWithFormat(
            String(localized: "changes.pr.pillTitle", defaultValue: "PR #%lld"),
            number
        )
    }

    /// Localized PR status word (reuses the sidebar's PR status keys).
    static func prStatusLabel(_ status: SidebarPullRequestStatus) -> String {
        switch status {
        case .open:
            return String(localized: "sidebar.pullRequest.statusOpen", defaultValue: "open")
        case .merged:
            return String(localized: "sidebar.pullRequest.statusMerged", defaultValue: "merged")
        case .closed:
            return String(localized: "sidebar.pullRequest.statusClosed", defaultValue: "closed")
        }
    }

    /// Localized aggregate check-state description for tooltips and
    /// accessibility. `nil`/unknown/noChecks render the neutral descriptions
    /// (R15: never claim passing or failing without a definitive rollup).
    static func checkStateDescription(_ rollupState: PullRequestCheckState.RollupState?) -> String {
        switch rollupState {
        case .success:
            return String(localized: "changes.pr.checks.passed", defaultValue: "Checks passed")
        case .pending, .expected:
            return String(localized: "changes.pr.checks.running", defaultValue: "Checks running")
        case .failure, .error:
            return String(localized: "changes.pr.checks.failed", defaultValue: "Checks failed")
        case .noChecks:
            return String(localized: "changes.pr.checks.none", defaultValue: "No checks")
        case .unknown, .none:
            return String(localized: "changes.pr.checks.unknown", defaultValue: "Check status unknown")
        }
    }

    /// "<PR label> — <check description>" pill tooltip.
    static func prPillTooltip(label: String, rollupState: PullRequestCheckState.RollupState?) -> String {
        String.localizedStringWithFormat(
            String(localized: "changes.pr.pillTooltip", defaultValue: "%1$@ — %2$@"),
            label,
            checkStateDescription(rollupState)
        )
    }
}

// MARK: - Status palette

extension GitChangedFileStatus {
    /// Row filename tint. Mirrors the file explorer's git palette family
    /// (`FileExplorerStyle.gitColor(for:)` in `FileExplorerStore.swift`).
    var changesRowColor: Color {
        switch self {
        case .added: return Color(nsColor: .systemGreen)
        case .modified: return Color(nsColor: .systemYellow)
        case .deleted: return Color(nsColor: .systemRed)
        case .renamed, .copied: return Color(nsColor: .systemBlue)
        case .typeChanged: return Color(nsColor: .systemYellow)
        case .untracked: return Color(nsColor: .tertiaryLabelColor)
        case .conflicted: return Color(nsColor: .systemOrange)
        case .submodule: return Color(nsColor: .secondaryLabelColor)
        }
    }
}

// MARK: - Workspace root resolution

extension GitChangesWorkspaceRoot {
    /// Maps a workspace to the Changes store's root descriptor: remote
    /// workspaces are explicitly `.remote` (R26's dedicated state), an empty
    /// cwd is `.none`, everything else is the local cwd.
    @MainActor
    static func forWorkspace(_ workspace: Workspace) -> GitChangesWorkspaceRoot {
        if workspace.isRemoteWorkspace { return .remote }
        let directory = workspace.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        return directory.isEmpty ? .none : .local(path: directory)
    }
}

// MARK: - Action bundles

/// Callback bundle handed below the snapshot boundary in place of a store
/// reference. See `IndexSectionActions` in `SessionIndexView.swift`: every
/// capability a row needs is a closure so no view under the `ForEach` can
/// subscribe to broad store updates.
struct GitChangesRowActions {
    let onOpenFile: (GitChangedFile) -> Void
}

/// Callback bundle for the PR header (same pattern as
/// ``GitChangesRowActions``): the header receives value state + closures,
/// never a store or workspace reference.
struct GitChangesHeaderActions {
    let onOpenPullRequest: (URL) -> Void
    let onCreatePR: () -> Void
}

// MARK: - PR header logic (pure)

/// Tint for the PR pill, derived from the CI rollup state and PR status.
nonisolated enum GitChangesPRTint: Equatable, Sendable {
    case green
    case orange
    case red
    case neutral
}

/// Pure color-mapping and visibility predicates for the PR header, kept off
/// the view types so they are unit-testable without rendering.
nonisolated enum GitChangesPRHeaderLogic {
    /// Color mapping (plan KTD): rollup SUCCESS → green, PENDING/EXPECTED →
    /// orange, FAILURE/ERROR → red, noChecks/unknown/`nil` → neutral (R15:
    /// never green or red without a definitive rollup). Merged/closed PRs
    /// render neutral regardless of rollup — the sidebar has no dedicated
    /// merged tint, so the status label/icon carries that state.
    static func tint(
        rollupState: PullRequestCheckState.RollupState?,
        prStatus: SidebarPullRequestStatus
    ) -> GitChangesPRTint {
        guard prStatus == .open else { return .neutral }
        switch rollupState {
        case .success:
            return .green
        case .pending, .expected:
            return .orange
        case .failure, .error:
            return .red
        case .noChecks, .unknown, .none:
            return .neutral
        }
    }

    /// Short name of the resolved base ref: `origin/main` → `main`, local
    /// `main` stays `main`. The store's base resolver only emits
    /// `origin/<default>` (origin/HEAD symref) or a local `main`/`master`,
    /// so dropping the first slash component is exact.
    static func defaultBranchShortName(baseRef: String) -> String {
        guard let slash = baseRef.firstIndex(of: "/") else { return baseRef }
        return String(baseRef[baseRef.index(after: slash)...])
    }

    /// Header visibility. Hidden when: the snapshot isn't a ready (merge-base
    /// resolved) one — degraded mode hides (R22); the branch is unknown or
    /// detached (`HEAD`); the branch IS the default branch (R14); the remote
    /// isn't GitHub — no resolvable slug, carried on the snapshot (R18); or
    /// PR polling is disabled in Settings (R30).
    static func isHeaderVisible(
        phase: GitChangesPhase,
        branch: String?,
        baseRef: String?,
        hasGitHubRemote: Bool,
        pollingEnabled: Bool
    ) -> Bool {
        guard phase == .ready, let baseRef, let branch, branch != "HEAD" else { return false }
        guard hasGitHubRemote, pollingEnabled else { return false }
        return branch != defaultBranchShortName(baseRef: baseRef)
    }

    /// Picks the workspace's PR entry for the current branch out of the
    /// per-panel PR map (`Workspace.panelPullRequests`, populated by the REST
    /// poll via `updatePanelPullRequest`). The focused panel's entry wins
    /// when it matches; otherwise the lowest panel id, for determinism when
    /// several terminals track the same branch.
    static func resolvedPullRequest(
        panelPullRequests: [UUID: SidebarPullRequestState],
        branch: String?,
        focusedPanelId: UUID?
    ) -> (panelId: UUID, state: SidebarPullRequestState)? {
        guard let branch else { return nil }
        let matches = panelPullRequests.filter { $0.value.branch == branch }
        guard !matches.isEmpty else { return nil }
        if let focusedPanelId, let state = matches[focusedPanelId] {
            return (focusedPanelId, state)
        }
        guard let entry = matches.min(by: { $0.key.uuidString < $1.key.uuidString }) else {
            return nil
        }
        return (entry.key, entry.value)
    }
}

// MARK: - PR header state

/// Immutable PR-header model computed at the panel root and handed below the
/// snapshot boundary as a value. `Equatable` so ``GitChangesContentView`` can
/// skip re-evaluation when neither the snapshot nor the header changed.
struct GitChangesPRHeaderState: Equatable {
    struct PullRequestPill: Equatable {
        let number: Int
        let label: String
        let url: URL
        let status: SidebarPullRequestStatus
        let tint: GitChangesPRTint
        let rollupState: PullRequestCheckState.RollupState?
    }

    enum CreatePRAvailability: Equatable {
        case enabled(targetPanelId: UUID)
        case noAgentTerminal
        case promptSent
    }

    enum Content: Equatable {
        case pullRequest(PullRequestPill)
        case createPR(CreatePRAvailability)
    }

    let content: Content

    /// Builds the header state from value inputs only. Returns `nil` when the
    /// header is hidden (default branch / degraded / non-GitHub / polling off)
    /// or there is neither a PR nor anything to create one from (R9: Create PR
    /// shows only when the branch has changes).
    static func make(
        snapshot: GitChangesSnapshot,
        panelPullRequests: [UUID: SidebarPullRequestState],
        checkStatesByPanel: [UUID: PullRequestCheckState],
        focusedPanelId: UUID?,
        agentCandidates: [GitChangesCreatePRLogic.AgentPanelCandidate],
        createPRPending: Bool,
        pollingEnabled: Bool
    ) -> GitChangesPRHeaderState? {
        guard GitChangesPRHeaderLogic.isHeaderVisible(
            phase: snapshot.phase,
            branch: snapshot.branch,
            baseRef: snapshot.baseRef,
            hasGitHubRemote: snapshot.hasGitHubRemote,
            pollingEnabled: pollingEnabled
        ) else { return nil }

        if let resolved = GitChangesPRHeaderLogic.resolvedPullRequest(
            panelPullRequests: panelPullRequests,
            branch: snapshot.branch,
            focusedPanelId: focusedPanelId
        ) {
            let rollupState = checkStatesByPanel[resolved.panelId]?.rollupState
            return GitChangesPRHeaderState(content: .pullRequest(PullRequestPill(
                number: resolved.state.number,
                label: resolved.state.label,
                url: resolved.state.url,
                status: resolved.state.status,
                tint: GitChangesPRHeaderLogic.tint(
                    rollupState: rollupState,
                    prStatus: resolved.state.status
                ),
                rollupState: rollupState
            )))
        }

        guard !snapshot.files.isEmpty else { return nil }
        if createPRPending {
            return GitChangesPRHeaderState(content: .createPR(.promptSent))
        }
        if let targetPanelId = GitChangesCreatePRLogic.targetPanelId(
            candidates: agentCandidates,
            focusedPanelId: focusedPanelId
        ) {
            return GitChangesPRHeaderState(content: .createPR(.enabled(targetPanelId: targetPanelId)))
        }
        return GitChangesPRHeaderState(content: .createPR(.noAgentTerminal))
    }
}

// MARK: - Workspace bridging

extension Workspace {
    /// Agent-terminal candidates for Create PR targeting: terminal panels
    /// owning at least one live agent PID key (only agent hook registration
    /// populates `agentPIDKeysByPanelId`, so plain shells never qualify —
    /// R16). Hibernated agent panels are excluded. Recency comes from the
    /// panel's agent status entries, mirroring
    /// `Workspace.agentStatusKey(forAgentPIDKey:)` key derivation.
    func gitChangesAgentPanelCandidates() -> [GitChangesCreatePRLogic.AgentPanelCandidate] {
        var candidates: [GitChangesCreatePRLogic.AgentPanelCandidate] = []
        candidates.reserveCapacity(agentPIDKeysByPanelId.count)
        for (panelId, pidKeys) in agentPIDKeysByPanelId {
            guard !pidKeys.isEmpty,
                  let terminalPanel = panels[panelId] as? TerminalPanel,
                  !terminalPanel.isAgentHibernated else { continue }
            var lastActivityAt: Date?
            for key in pidKeys {
                // Mirrors agentStatusKey(forAgentPIDKey:): the exact key when
                // a status entry exists for it, else the prefix before the
                // first ".".
                let statusKey: String
                if statusEntries[key] != nil {
                    statusKey = key
                } else if let dotIndex = key.firstIndex(of: ".") {
                    statusKey = String(key[..<dotIndex])
                } else {
                    statusKey = key
                }
                if let timestamp = statusEntries[statusKey]?.timestamp {
                    lastActivityAt = max(lastActivityAt ?? .distantPast, timestamp)
                }
            }
            candidates.append(GitChangesCreatePRLogic.AgentPanelCandidate(
                panelId: panelId,
                lastActivityAt: lastActivityAt
            ))
        }
        return candidates
    }
}

// MARK: - Host (nil-store wrapper)

/// Hosts the Changes panel for call sites whose store is optional (no
/// workspace selected). Renders the not-a-repo state when there is nothing
/// to attach to. `workspace` feeds the PR header; without it the list still
/// renders, header-less.
struct GitChangesPanelHostView: View {
    let store: GitChangesStore?
    let workspace: Workspace?
    let onOpenFile: (GitChangedFile) -> Void

    var body: some View {
        if let store {
            if let workspace {
                GitChangesWorkspacePanelView(store: store, workspace: workspace, onOpenFile: onOpenFile)
            } else {
                GitChangesPanelView(store: store, onOpenFile: onOpenFile)
            }
        } else {
            GitChangesMessageView(
                message: String(
                    localized: "changes.state.notARepo",
                    defaultValue: "This folder isn't a Git repository"
                )
            )
        }
    }
}

// MARK: - Panel

/// Changes panel root with workspace context: observes the store plus the
/// workspace — the one additional observed source allowed at the panel root
/// (PR metadata, CI check state, agent presence). Everything below the root
/// receives immutable values plus closures (snapshot-boundary rule); the
/// content view's `Equatable` gate means frequent unrelated workspace
/// publishes cost only this cheap body, never a list re-diff.
struct GitChangesWorkspacePanelView: View {
    @ObservedObject var store: GitChangesStore
    @ObservedObject var workspace: Workspace
    let onOpenFile: (GitChangedFile) -> Void

    var body: some View {
        let prHeader = GitChangesPRHeaderState.make(
            snapshot: store.snapshot,
            panelPullRequests: workspace.panelPullRequests,
            checkStatesByPanel: workspace.pullRequestCheckStatesByPanel,
            focusedPanelId: workspace.focusedPanelId,
            agentCandidates: workspace.gitChangesAgentPanelCandidates(),
            createPRPending: store.createPRPending,
            pollingEnabled: SidebarWorkspaceDetailDefaults.pullRequestPollingEnabled(defaults: .standard)
        )
        let pullRequestExistsForCurrentBranch = GitChangesPRHeaderLogic.resolvedPullRequest(
            panelPullRequests: workspace.panelPullRequests,
            branch: store.snapshot.branch,
            focusedPanelId: workspace.focusedPanelId
        ) != nil
        GitChangesContentView(
            snapshot: store.snapshot,
            prHeader: prHeader,
            actions: GitChangesRowActions(onOpenFile: onOpenFile),
            headerActions: headerActions,
            onRetry: { [weak store] in
                guard let store else { return }
                Task { await store.refreshNow() }
            }
        )
        .equatable()
        // Create PR pending lifecycle (R17): cleared when polling reports a
        // PR for the CURRENT branch. Event callbacks only — never mutate
        // store state from body computations.
        .onChange(of: pullRequestExistsForCurrentBranch) { _, exists in
            store.reconcileCreatePRPending(pullRequestExistsForCurrentBranch: exists)
        }
        .onAppear {
            store.reconcileCreatePRPending(
                pullRequestExistsForCurrentBranch: pullRequestExistsForCurrentBranch
            )
        }
    }

    private var headerActions: GitChangesHeaderActions {
        GitChangesHeaderActions(
            onOpenPullRequest: { url in
                // Default-browser open, matching the sidebar's PR-link
                // fallback (`openPullRequestLink` in ContentView.swift).
                NSWorkspace.shared.open(url)
            },
            onCreatePR: { [weak store, weak workspace] in
                guard let store, let workspace else { return }
                // Re-resolve the target at click time (render-time state can
                // be stale); the store's pending flag is the idempotency
                // guard across views and windows.
                guard let targetPanelId = GitChangesCreatePRLogic.targetPanelId(
                    candidates: workspace.gitChangesAgentPanelCandidates(),
                    focusedPanelId: workspace.focusedPanelId
                ) else { return }
                store.sendCreatePRPrompt(
                    workspaceId: workspace.id,
                    agentSurfaceId: targetPanelId
                )
            }
        )
    }
}

/// Header-less Changes panel root for call sites without workspace context.
/// The only observed source is the store.
struct GitChangesPanelView: View {
    @ObservedObject var store: GitChangesStore
    let onOpenFile: (GitChangedFile) -> Void

    var body: some View {
        GitChangesContentView(
            snapshot: store.snapshot,
            prHeader: nil,
            actions: GitChangesRowActions(onOpenFile: onOpenFile),
            headerActions: GitChangesHeaderActions(onOpenPullRequest: { _ in }, onCreatePR: {}),
            onRetry: { [weak store] in
                guard let store else { return }
                Task { await store.refreshNow() }
            }
        )
        .equatable()
    }
}

/// Snapshot-driven content. `Equatable` on the snapshot and PR header values
/// alone so unrelated parent re-evaluations don't re-diff the list subtree.
private struct GitChangesContentView: View, Equatable {
    let snapshot: GitChangesSnapshot
    let prHeader: GitChangesPRHeaderState?
    let actions: GitChangesRowActions
    let headerActions: GitChangesHeaderActions
    let onRetry: () -> Void

    static func == (lhs: GitChangesContentView, rhs: GitChangesContentView) -> Bool {
        lhs.snapshot == rhs.snapshot && lhs.prHeader == rhs.prHeader
    }

    var body: some View {
        switch snapshot.phase {
        case .loading:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .notARepo:
            GitChangesMessageView(
                message: String(
                    localized: "changes.state.notARepo",
                    defaultValue: "This folder isn't a Git repository"
                )
            )
        case .remoteUnavailable:
            GitChangesMessageView(
                message: String(
                    localized: "changes.state.remoteUnavailable",
                    defaultValue: "Changes isn't available for remote workspaces yet"
                )
            )
        case .failed:
            GitChangesMessageView(
                message: String(
                    localized: "changes.state.failed",
                    defaultValue: "Couldn't read changes"
                ),
                retryTitle: String(localized: "changes.action.retry", defaultValue: "Retry"),
                onRetry: onRetry
            )
        case .ready, .degraded:
            listContent
        }
    }

    @ViewBuilder
    private var listContent: some View {
        VStack(spacing: 0) {
            GitChangesHeaderView(branch: snapshot.branch, baseRef: snapshot.baseRef)

            if let prHeader {
                GitChangesPRHeaderSectionView(state: prHeader, actions: headerActions)
            }

            GitChangesTotalsView(
                fileCount: snapshot.files.count,
                totalAddedLines: snapshot.totalAddedLines,
                totalDeletedLines: snapshot.totalDeletedLines
            )

            if snapshot.phase == .degraded {
                Text(String(
                    localized: "changes.caption.degraded",
                    defaultValue: "Uncommitted changes only (no base branch)"
                ))
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
            }

            Divider()

            if snapshot.files.isEmpty {
                GitChangesMessageView(message: emptyListMessage)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(snapshot.files) { file in
                            GitChangesFileRow(file: file, actions: actions)
                                .equatable()
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var emptyListMessage: String {
        if snapshot.phase == .ready, let baseRef = snapshot.baseRef {
            return String.localizedStringWithFormat(
                String(localized: "changes.empty.noChangesFromBase", defaultValue: "No changes from %@"),
                baseRef
            )
        }
        return String(localized: "changes.empty.noChanges", defaultValue: "No changes")
    }
}

// MARK: - Header (branch context + U5 slot)

private struct GitChangesHeaderView: View {
    let branch: String?
    let baseRef: String?

    var body: some View {
        if branch != nil || baseRef != nil {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                if let branch {
                    Text(verbatim: branch)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let baseRef {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                    Text(verbatim: baseRef)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 4)
        }
    }
}

// MARK: - PR header section (U5 slot)

/// PR header row: the linked PR as a CI-color-coded pill, or the Create PR
/// button. Receives an immutable state value plus a closure bundle only
/// (snapshot-boundary rule).
private struct GitChangesPRHeaderSectionView: View {
    let state: GitChangesPRHeaderState
    let actions: GitChangesHeaderActions

    var body: some View {
        HStack(spacing: 6) {
            switch state.content {
            case .pullRequest(let pill):
                pillButton(pill)
            case .createPR(let availability):
                createPRButton(availability)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 2)
    }

    private func pillButton(_ pill: GitChangesPRHeaderState.PullRequestPill) -> some View {
        let tintColor = color(for: pill.tint)
        return Button {
            actions.onOpenPullRequest(pill.url)
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(tintColor)
                    .frame(width: 6, height: 6)
                Text(GitChangesPanelFormatting.prPillTitle(number: pill.number))
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundColor(.primary)
                Text(GitChangesPanelFormatting.prStatusLabel(pill.status))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(tintColor.opacity(0.14)))
            .overlay(Capsule().strokeBorder(tintColor.opacity(0.35), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .safeHelp(GitChangesPanelFormatting.prPillTooltip(label: pill.label, rollupState: pill.rollupState))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(prAccessibilityLabel(pill))
    }

    @ViewBuilder
    private func createPRButton(_ availability: GitChangesPRHeaderState.CreatePRAvailability) -> some View {
        let isEnabled: Bool = {
            if case .enabled = availability { return true }
            return false
        }()
        Button {
            actions.onCreatePR()
        } label: {
            Text(createPRTitle(availability))
                .font(.system(size: 11))
        }
        .controlSize(.small)
        .disabled(!isEnabled)
        .safeHelp(createPRTooltip(availability))
    }

    private func createPRTitle(_ availability: GitChangesPRHeaderState.CreatePRAvailability) -> String {
        switch availability {
        case .promptSent:
            return String(localized: "changes.createPR.promptSent", defaultValue: "Prompt sent…")
        case .enabled, .noAgentTerminal:
            return String(localized: "changes.createPR.button", defaultValue: "Create PR")
        }
    }

    private func createPRTooltip(_ availability: GitChangesPRHeaderState.CreatePRAvailability) -> String {
        switch availability {
        case .enabled:
            return String(
                localized: "changes.createPR.tooltip",
                defaultValue: "Ask this workspace's agent terminal to push the branch and create a pull request"
            )
        case .noAgentTerminal:
            return String(
                localized: "changes.createPR.noAgentTooltip",
                defaultValue: "Create PR needs a running agent terminal in this workspace"
            )
        case .promptSent:
            return String(
                localized: "changes.createPR.promptSentTooltip",
                defaultValue: "Prompt sent to the agent terminal — waiting for the pull request to appear"
            )
        }
    }

    private func prAccessibilityLabel(_ pill: GitChangesPRHeaderState.PullRequestPill) -> String {
        String.localizedStringWithFormat(
            String(localized: "changes.pr.accessibility", defaultValue: "%1$@, %2$@, %3$@"),
            GitChangesPanelFormatting.prPillTitle(number: pill.number),
            GitChangesPanelFormatting.prStatusLabel(pill.status),
            GitChangesPanelFormatting.checkStateDescription(pill.rollupState)
        )
    }

    private func color(for tint: GitChangesPRTint) -> Color {
        switch tint {
        case .green: return Color(nsColor: .systemGreen)
        case .orange: return Color(nsColor: .systemOrange)
        case .red: return Color(nsColor: .systemRed)
        case .neutral: return Color(nsColor: .secondaryLabelColor)
        }
    }
}

// MARK: - Totals line

private struct GitChangesTotalsView: View {
    let fileCount: Int
    let totalAddedLines: Int
    let totalDeletedLines: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(GitChangesPanelFormatting.totalsFilesText(count: fileCount))
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundColor(.secondary)
            Spacer(minLength: 0)
            if totalAddedLines > 0 {
                Text(verbatim: "+\(totalAddedLines)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundColor(Color(nsColor: .systemGreen))
            }
            if totalDeletedLines > 0 {
                Text(verbatim: "−\(totalDeletedLines)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundColor(Color(nsColor: .systemRed))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Row

/// One changed-file row. Value snapshot + closure bundle only; `Equatable`
/// on the file so unrelated snapshot publishes don't re-evaluate row bodies
/// (snapshot-boundary rule, see CLAUDE.md and `SessionIndexView.swift`).
private struct GitChangesFileRow: View, Equatable {
    let file: GitChangedFile
    let actions: GitChangesRowActions

    @State private var isHovered = false

    static func == (lhs: GitChangesFileRow, rhs: GitChangesFileRow) -> Bool {
        lhs.file == rhs.file
    }

    var body: some View {
        Button {
            actions.onOpenFile(file)
        } label: {
            HStack(spacing: 6) {
                Text(GitChangesPanelFormatting.displayName(for: file))
                    .font(.system(size: 11.5))
                    .foregroundColor(file.status.changesRowColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                let directory = GitChangesPanelFormatting.directoryText(for: file)
                if !directory.isEmpty {
                    Text(verbatim: directory)
                        .font(.system(size: 10.5))
                        .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                trailingCounts
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 3.5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isHovered ? primaryHoverColor : Color.clear)
        .onHover { isHovered = $0 }
        .safeHelp(GitChangesPanelFormatting.fullPathTooltip(for: file))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(GitChangesPanelFormatting.accessibilityLabel(for: file))
    }

    private var primaryHoverColor: Color {
        Color.primary.opacity(0.06)
    }

    @ViewBuilder
    private var trailingCounts: some View {
        if file.status == .submodule {
            Text(String(localized: "changes.row.submodule", defaultValue: "submodule"))
                .font(.system(size: 10))
                .foregroundColor(Color(nsColor: .tertiaryLabelColor))
        } else if file.isBinary {
            Text(String(localized: "changes.row.binary", defaultValue: "binary"))
                .font(.system(size: 10))
                .foregroundColor(Color(nsColor: .tertiaryLabelColor))
        } else if let added = file.addedLines, let deleted = file.deletedLines {
            HStack(spacing: 4) {
                Text(verbatim: "+\(added)")
                    .foregroundColor(Color(nsColor: .systemGreen))
                Text(verbatim: "−\(deleted)")
                    .foregroundColor(Color(nsColor: .systemRed))
            }
            .font(.system(size: 10.5).monospacedDigit())
        }
    }
}

// MARK: - Message states

private struct GitChangesMessageView: View {
    let message: String
    var retryTitle: String?
    var onRetry: (() -> Void)?

    var body: some View {
        VStack(spacing: 8) {
            Text(message)
                .font(.system(size: 11.5))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            if let retryTitle, let onRetry {
                Button(retryTitle, action: onRetry)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
