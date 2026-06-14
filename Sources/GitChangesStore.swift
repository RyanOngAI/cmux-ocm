import Combine
import CmuxFileWatch
import CmuxFoundation
import CmuxGit
import Darwin
import Foundation

// MARK: - Snapshot value types

/// Lifecycle phase of a ``GitChangesSnapshot``.
enum GitChangesPhase: Equatable, Sendable {
    /// No refresh has completed yet for the current root.
    case loading
    /// The snapshot reflects a successful refresh against the merge-base.
    case ready
    /// The workspace root is not inside a git repository (or there is no local root).
    case notARepo
    /// The workspace root is remote (SSH); local git inspection is unavailable.
    case remoteUnavailable
    /// No default branch or merge-base could be resolved; rows show
    /// uncommitted + untracked changes only.
    case degraded
    /// Three or more consecutive git failures; rows are the last good data.
    case failed
}

/// Status of one changed file relative to the merge-base / working tree.
enum GitChangedFileStatus: Equatable, Sendable {
    case added
    case modified
    case deleted
    case renamed
    case copied
    case typeChanged
    case untracked
    case conflicted
    case submodule
}

/// One changed file row. Paths are repo-root-relative.
///
/// `addedLines`/`deletedLines` are `nil` for binary files, submodule pointer
/// changes, conflicted files, and untracked files whose counts were skipped
/// (too large, vanished, or beyond the per-refresh counting cap).
struct GitChangedFile: Equatable, Sendable, Identifiable {
    var id: String { path }
    /// Repo-root-relative current path (rename target for renames).
    let path: String
    /// Repo-root-relative pre-rename/copy origin path, when known.
    let previousPath: String?
    let status: GitChangedFileStatus
    /// True when git reported the diff as binary (`-` numstat counts).
    let isBinary: Bool
    let addedLines: Int?
    let deletedLines: Int?
}

/// Immutable result of one refresh cycle. Published as a whole; equal
/// snapshots are never re-published.
struct GitChangesSnapshot: Equatable, Sendable {
    let phase: GitChangesPhase
    /// Absolute repo root path resolved via `git rev-parse --show-toplevel`.
    let repoRootPath: String?
    /// Current branch short name (`HEAD` when detached), when resolvable.
    let branch: String?
    /// Resolved default-branch ref the diff is computed against
    /// (e.g. `origin/main` or `main`); `nil` in degraded/non-repo phases.
    let baseRef: String?
    /// Merge-base commit SHA between HEAD and ``baseRef``.
    let mergeBase: String?
    /// Changed rows, sorted by path.
    let files: [GitChangedFile]
    /// Sum of all non-nil ``GitChangedFile/addedLines``.
    let totalAddedLines: Int
    /// Sum of all non-nil ``GitChangedFile/deletedLines``.
    let totalDeletedLines: Int
    /// True when the repository has a resolvable GitHub `owner/name` remote
    /// slug (`GitMetadataService.repositorySlugs`, read from `config` with no
    /// subprocess). Resolved alongside the base ref (`.git`-event cadence).
    /// The PR header is hidden for non-GitHub/absent remotes (R18).
    let hasGitHubRemote: Bool

    init(
        phase: GitChangesPhase,
        repoRootPath: String? = nil,
        branch: String? = nil,
        baseRef: String? = nil,
        mergeBase: String? = nil,
        files: [GitChangedFile] = [],
        hasGitHubRemote: Bool = false
    ) {
        self.phase = phase
        self.repoRootPath = repoRootPath
        self.branch = branch
        self.baseRef = baseRef
        self.mergeBase = mergeBase
        self.files = files
        self.totalAddedLines = files.compactMap(\.addedLines).reduce(0, +)
        self.totalDeletedLines = files.compactMap(\.deletedLines).reduce(0, +)
        self.hasGitHubRemote = hasGitHubRemote
    }

    static let initial = GitChangesSnapshot(phase: .loading)
}

/// Minimal local-vs-remote root descriptor (mirrors the shape of
/// `FileExplorerWorkspaceRoot` without the SSH connection payload).
enum GitChangesWorkspaceRoot: Equatable, Sendable {
    case none
    case local(path: String)
    case remote
}

// MARK: - Parser intermediate values

/// One `git diff --numstat -z` record.
struct GitNumstatEntry: Equatable, Sendable {
    let path: String
    let previousPath: String?
    /// `nil` when git reported `-` (binary).
    let addedLines: Int?
    let deletedLines: Int?
    let isBinary: Bool
}

/// One `git diff --name-status -z` record.
struct GitNameStatusEntry: Equatable, Sendable {
    /// First letter of the status field (`A`, `M`, `D`, `R`, `C`, `T`, ...).
    let statusLetter: Character
    let path: String
    let previousPath: String?
}

/// One `git status --porcelain -z` record.
struct GitPorcelainEntry: Equatable, Sendable {
    let indexStatus: Character
    let workTreeStatus: Character
    let path: String
    let previousPath: String?
}

/// Resolved diff-base information, cached between `.git`-event refreshes.
struct GitChangesResolvedBase: Equatable, Sendable {
    /// Default-branch ref (e.g. `origin/main`); `nil` when unresolvable.
    let baseRef: String?
    /// `git merge-base HEAD baseRef` SHA; `nil` when unresolvable.
    let mergeBase: String?
    /// Current branch short name.
    let branch: String?
    /// Whether the repository has a GitHub remote slug (see
    /// ``GitChangesSnapshot/hasGitHubRemote``).
    let hasGitHubRemote: Bool
}

// MARK: - Untracked line counter

/// Counts lines in untracked files in-process (git numstat semantics) with a
/// `(path, size, mtime)` cache so unchanged files are never re-read.
struct GitUntrackedLineCounter: Sendable {
    struct CacheEntry: Sendable {
        let fileSize: Int64
        let modificationDate: Date
        let addedLines: Int?
        let isBinary: Bool
    }

    /// Files larger than this render without counts (matches the plan's ~1MB skip).
    static let maxCountableFileSize: Int64 = 1_048_576
    /// At most this many untracked files are read from disk per refresh; the
    /// rest render without counts (cache hits stay free).
    static let maxCountedFilesPerRefresh = 200
    /// Git's binary sniff window: a NUL in the first 8000 bytes means binary.
    static let binarySniffLength = 8000

    private(set) var cache: [String: CacheEntry] = [:]

    /// Counts lines for the untracked file at `path` (absolute).
    ///
    /// - Returns: counts (nil when binary/oversized/unreadable), the binary
    ///   flag, and whether a disk read occurred (cache misses only).
    mutating func count(
        atPath path: String,
        allowRead: Bool = true,
        fileManager: FileManager = .default
    ) -> (addedLines: Int?, isBinary: Bool, didRead: Bool) {
        guard let attributes = try? fileManager.attributesOfItem(atPath: path) else {
            // Vanished mid-refresh: row renders without counts, refresh continues.
            cache.removeValue(forKey: path)
            return (nil, false, false)
        }
        guard (attributes[.type] as? FileAttributeType) == .typeRegular else {
            // Symlinks, fifos, sockets: never read, never count.
            return (nil, false, false)
        }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modificationDate = (attributes[.modificationDate] as? Date) ?? .distantPast
        if let entry = cache[path],
           entry.fileSize == size,
           entry.modificationDate == modificationDate {
            return (entry.addedLines, entry.isBinary, false)
        }
        guard size <= Self.maxCountableFileSize else {
            cache[path] = CacheEntry(
                fileSize: size,
                modificationDate: modificationDate,
                addedLines: nil,
                isBinary: false
            )
            return (nil, false, false)
        }
        guard allowRead else { return (nil, false, false) }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: [.uncached]) else {
            // Vanished between stat and read: degrade to a row without counts.
            return (nil, false, true)
        }
        let measured = Self.measure(data)
        let entry = CacheEntry(
            fileSize: size,
            modificationDate: modificationDate,
            addedLines: measured.isBinary ? nil : measured.lineCount,
            isBinary: measured.isBinary
        )
        cache[path] = entry
        return (entry.addedLines, entry.isBinary, true)
    }

    /// Drops cache entries whose path is not in this refresh's untracked set
    /// (absolute paths), so tracked-or-deleted files cannot grow the cache
    /// without bound. O(cache size).
    mutating func pruneCache(keepingPaths keep: Set<String>) {
        cache = cache.filter { keep.contains($0.key) }
    }

    /// Pure measurement: newline count, +1 when non-empty without a trailing
    /// newline (git numstat semantics); NUL in the first 8000 bytes → binary.
    static func measure(_ data: Data) -> (lineCount: Int, isBinary: Bool) {
        if data.prefix(Self.binarySniffLength).contains(0) {
            return (0, true)
        }
        var count = 0
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            for byte in buffer where byte == 0x0A {
                count += 1
            }
        }
        if let last = data.last, last != 0x0A {
            count += 1
        }
        return (count, false)
    }
}

// MARK: - Git process execution

/// Result of one git spawn: exit status plus captured stdout.
struct GitProcessResult: Sendable {
    let exitStatus: Int32
    let stdout: Data
}

/// Mutable `Data` guarded by `lock`; appended from the pipe's readability
/// callback thread, read once on completion.
private final class GitProcessOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func value() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

/// One git spawn with single-resume continuation semantics and SIGTERM →
/// SIGKILL cancellation, mirroring the `ProcessTerminationGate` precedent in
/// `AgentForkSupport`/`FileExplorerStore`.
///
/// `@unchecked Sendable`: every mutable property is accessed only under
/// `lock`; the gate handles the launch-vs-terminate race (lock carve-out:
/// synchronous Process callbacks racing to resume one continuation).
private final class GitProcessExecution: @unchecked Sendable {
    private let arguments: [String]
    private let workingDirectory: String
    private let lock = NSLock()
    private let terminationGate = ProcessTerminationGate()
    private let outputBuffer = GitProcessOutputBuffer()
    private var process: Process?
    private var pipe: Pipe?
    private var killTimer: DispatchSourceTimer?
    private var continuation: CheckedContinuation<GitProcessResult?, Never>?
    private var completed = false
    private var cancelled = false

    /// SIGTERM → SIGKILL escalation delay.
    private static let killEscalationDelay: DispatchTimeInterval = .milliseconds(500)

    init(arguments: [String], workingDirectory: String) {
        self.arguments = arguments
        self.workingDirectory = workingDirectory
    }

    func start(continuation: CheckedContinuation<GitProcessResult?, Never>) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: GitChangesStore.gitExecutablePath)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        process.environment = GitChangesStore.gitEnvironment()

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [outputBuffer] handle in
            switch handle.readAvailableDataOrEndOfFile() {
            case .data(let data):
                outputBuffer.append(data)
            case .wouldBlock:
                return
            case .endOfFile:
                handle.readabilityHandler = nil
            }
        }
        process.terminationHandler = { [weak self] _ in
            self?.finish()
        }

        lock.lock()
        if completed || cancelled {
            completed = true
            lock.unlock()
            terminationGate.markFinished()
            pipe.fileHandleForReading.readabilityHandler = nil
            process.terminationHandler = nil
            continuation.resume(returning: nil)
            return
        }
        self.continuation = continuation
        self.pipe = pipe
        lock.unlock()

        do {
            try process.run()
        } catch {
            terminationGate.markFinished()
            lock.lock()
            cancelled = true
            lock.unlock()
            finish()
            return
        }

        lock.lock()
        if completed {
            lock.unlock()
            terminationGate.markFinished()
            process.terminationHandler = nil
            return
        }
        self.process = process
        lock.unlock()

        if terminationGate.markLaunched() {
            if process.isRunning {
                process.terminate()
                startKillTimer(processIdentifier: process.processIdentifier)
            }
        }
    }

    /// Requests termination (SIGTERM, escalating to SIGKILL). Safe before
    /// launch and after completion.
    func cancel() {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        cancelled = true
        lock.unlock()

        guard terminationGate.requestTermination() else { return }
        lock.lock()
        let process = self.process
        lock.unlock()
        guard let process, process.isRunning else { return }
        process.terminate()
        startKillTimer(processIdentifier: process.processIdentifier)
    }

    // DispatchSource timer carve-out: this deadline must fire from the
    // synchronous cancel()/termination-handler context with no async host.
    private func startKillTimer(processIdentifier: pid_t) {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + Self.killEscalationDelay)
        timer.setEventHandler { [self] in
            lock.lock()
            let shouldKill = !completed && process?.isRunning == true
            lock.unlock()
            if shouldKill {
                kill(processIdentifier, SIGKILL)
            }
        }
        lock.lock()
        if completed {
            lock.unlock()
            timer.resume()
            timer.cancel()
            return
        }
        killTimer?.cancel()
        killTimer = timer
        lock.unlock()
        timer.resume()
    }

    private func finish() {
        let continuation: CheckedContinuation<GitProcessResult?, Never>?
        let pipe: Pipe?
        let process: Process?
        let killTimer: DispatchSourceTimer?
        let cancelled: Bool

        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        continuation = self.continuation
        self.continuation = nil
        pipe = self.pipe
        self.pipe = nil
        process = self.process
        self.process = nil
        killTimer = self.killTimer
        self.killTimer = nil
        cancelled = self.cancelled
        lock.unlock()

        terminationGate.markFinished()
        killTimer?.cancel()
        process?.terminationHandler = nil
        pipe?.fileHandleForReading.readabilityHandler = nil
        if let readHandle = pipe?.fileHandleForReading {
            outputBuffer.append(readHandle.readDataToEndOfFileOrEmpty())
        }
        guard !cancelled, let process else {
            continuation?.resume(returning: nil)
            return
        }
        continuation?.resume(
            returning: GitProcessResult(
                exitStatus: process.terminationStatus,
                stdout: outputBuffer.value()
            )
        )
    }
}

// MARK: - Store

/// Per-workspace store producing live changed-file snapshots versus the
/// merge-base with the default branch.
///
/// Owned by ``TabManager``'s registry, ref-counted by visible panels: fully
/// suspended (no watchers, no refreshes) at zero observers, refreshed
/// immediately on re-attach. Publishes exactly one value, ``snapshot``, and
/// only when its contents change (old/new compared off-main).
@MainActor
final class GitChangesStore: ObservableObject {
    @Published private(set) var snapshot: GitChangesSnapshot = .initial

    /// "Create PR prompt sent" pending state (R17), scoped to the workspace
    /// store so two windows showing the same workspace cannot double-send.
    /// Set by ``sendCreatePRPrompt(workspaceId:agentSurfaceId:timeout:dispatch:)``;
    /// cleared when polling reports a PR for the current branch
    /// (``reconcileCreatePRPending(pullRequestExistsForCurrentBranch:)``) or
    /// after ``createPRPendingTimeout``.
    @Published private(set) var createPRPending = false

    static let gitExecutablePath = "/usr/bin/git"
    /// Per-spawn timeout; every command here is read-only so SIGTERM is safe.
    static let gitTimeout: TimeInterval = 10
    static let minimumRefreshInterval: TimeInterval = 0.3
    static let refreshPacingFactor: Double = 3
    static let refreshQuietResetInterval: TimeInterval = 2
    /// How long the Create PR button stays in "Prompt sent…" before
    /// re-enabling when no PR appears for the branch (R17).
    static let createPRPendingTimeout: TimeInterval = 300

    private enum RefreshTrigger {
        /// Workspace-tree FSEvent: numstat + status only.
        case treeEvent
        /// `.git` metadata FSEvent: re-resolve default branch + merge-base.
        case gitMetadataEvent
        /// First attach / root change / resume: full resolve.
        case attach
        /// Trailing run coalesced behind an in-flight refresh.
        case trailing
    }

    private let gitMetadataService: GitMetadataService
    private var workspaceRoot: GitChangesWorkspaceRoot = .none
    private var isSuspended = true
    /// Bumped on root swap / suspend; refresh results from older generations
    /// are discarded on arrival.
    private var generation: UInt64 = 0
    private var needsBaseReresolve = true
    private var cachedBase: GitChangesResolvedBase?
    private var untrackedCounter = GitUntrackedLineCounter()
    private var refreshTask: Task<Void, Never>?
    private var scheduledRefreshTask: Task<Void, Never>?
    private var hasPendingTrailingRefresh = false
    private var lastRefreshEndedAt: Date?
    private var lastRefreshDuration: TimeInterval = 0
    private var consecutiveGitFailureCount = 0
    private var treeWatcher: RecursivePathWatcher?
    private var treeWatcherTask: Task<Void, Never>?
    private var gitWatcher: RecursivePathWatcher?
    private var gitWatcherTask: Task<Void, Never>?
    private var gitWatcherSetupTask: Task<Void, Never>?
    private var createPRPendingTimeoutTask: Task<Void, Never>?

    init(gitMetadataService: GitMetadataService = GitMetadataService()) {
        self.gitMetadataService = gitMetadataService
    }

    deinit {
        refreshTask?.cancel()
        scheduledRefreshTask?.cancel()
        gitWatcherSetupTask?.cancel()
        treeWatcherTask?.cancel()
        gitWatcherTask?.cancel()
        createPRPendingTimeoutTask?.cancel()
        // Dropping the watcher references runs their deinits, which tear down
        // the FSEventStreams and finish the consumer tasks' streams.
    }

    // MARK: Public lifecycle (driven by TabManager's registry)

    /// Updates the workspace root. A change resets all caches and, when the
    /// store is active, restarts watchers and refreshes immediately — except
    /// when both roots are local and the new path is still inside the already
    /// resolved repo root, where the snapshot, caches, and watchers survive
    /// (terminal focus moves between subdirectories must not flash the UI).
    func setWorkspaceRoot(_ newRoot: GitChangesWorkspaceRoot) {
        guard newRoot != workspaceRoot else { return }
        if case .local(let newPath) = newRoot,
           case .local = workspaceRoot,
           let repoRoot = snapshot.repoRootPath,
           Self.isPath(newPath, containedIn: repoRoot) {
            workspaceRoot = newRoot
            if !isSuspended {
                // The tree watcher can still be rooted at the pre-refresh
                // workspace path; re-root it to the repo root so events from
                // the whole repo keep flowing (no-op when already there).
                updateTreeWatcher(path: repoRoot)
                refreshGitWatcherPaths(for: repoRoot)
                scheduleRefresh(trigger: .attach)
            }
            return
        }
        workspaceRoot = newRoot
        generation &+= 1
        cancelRefreshWork()
        teardownWatchers()
        cachedBase = nil
        needsBaseReresolve = true
        untrackedCounter = GitUntrackedLineCounter()
        consecutiveGitFailureCount = 0
        lastRefreshEndedAt = nil
        lastRefreshDuration = 0

        switch newRoot {
        case .none:
            setSnapshotIfChanged(GitChangesSnapshot(phase: .notARepo))
        case .remote:
            setSnapshotIfChanged(GitChangesSnapshot(phase: .remoteUnavailable))
        case .local(let path):
            setSnapshotIfChanged(.initial)
            if !isSuspended {
                updateTreeWatcher(path: path)
                refreshGitWatcherPaths(for: path)
                scheduleRefresh(trigger: .attach)
            }
        }
    }

    /// Activates the store (first observer attached): starts watchers and
    /// refreshes immediately, bypassing pacing.
    func resume() {
        guard isSuspended else { return }
        isSuspended = false
        guard case .local(let path) = workspaceRoot else { return }
        lastRefreshEndedAt = nil // immediate refresh on re-attach
        needsBaseReresolve = true
        let watchPath = snapshot.repoRootPath ?? path
        updateTreeWatcher(path: watchPath)
        refreshGitWatcherPaths(for: watchPath)
        scheduleRefresh(trigger: .attach)
    }

    /// Fully suspends the store (zero observers): tears down watchers and
    /// cancels in-flight and pending refreshes. The last snapshot is kept so a
    /// re-attach renders instantly while the immediate refresh runs.
    func suspend() {
        guard !isSuspended else { return }
        isSuspended = true
        generation &+= 1
        cancelRefreshWork()
        teardownWatchers()
    }

    // MARK: Create PR (single shared mutation path)

    /// Sends the fixed Create PR prompt to the chosen agent terminal and
    /// enters the pending state. This is the ONE mutation path for every
    /// Create PR entrypoint (sidebar Changes tab and pop-out pane, any
    /// window): the workspace-scoped pending flag makes double-clicks and
    /// two-window clicks no-ops (R17). A queued send (busy terminal) still
    /// counts as sent — the socket layer reports `queued` but delivers.
    ///
    /// - Parameters:
    ///   - dispatch: Test seam; production uses the Feed `surface.send_text`
    ///     path, which is a non-focus socket command (socket policy: no
    ///     first-responder change, no window raise).
    /// - Returns: `false` when a send was already pending (nothing sent).
    @discardableResult
    func sendCreatePRPrompt(
        workspaceId: UUID,
        agentSurfaceId: UUID,
        timeout: TimeInterval = GitChangesStore.createPRPendingTimeout,
        dispatch: (@MainActor (_ workspaceId: UUID, _ surfaceId: UUID, _ text: String) -> Void)? = nil
    ) -> Bool {
        guard !createPRPending else { return false }
        markCreatePRPending()
        let send = dispatch ?? Self.dispatchCreatePRPromptViaFeedPath
        send(workspaceId, agentSurfaceId, GitChangesCreatePRLogic.promptText)
        createPRPendingTimeoutTask?.cancel()
        // Bounded, cancellable timeout (Clock.sleep carve-out): re-enables the
        // button when no PR appears for the branch within the window (R17).
        createPRPendingTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard let self, !Task.isCancelled else { return }
            self.clearCreatePRPending()
        }
        return true
    }

    /// Clears the pending state once polling reports a PR for the workspace's
    /// CURRENT branch. Called from the header observation on every
    /// `panelPullRequests` change — a PR detected on a *different* branch
    /// (the agent may have switched branches) keeps the pending state.
    func reconcileCreatePRPending(pullRequestExistsForCurrentBranch: Bool) {
        guard createPRPending, pullRequestExistsForCurrentBranch else { return }
        clearCreatePRPending()
    }

    /// Marks the "Create PR prompt sent" pending state. Private so
    /// ``sendCreatePRPrompt(workspaceId:agentSurfaceId:timeout:dispatch:)``,
    /// ``reconcileCreatePRPending(pullRequestExistsForCurrentBranch:)``, and
    /// the timeout stay the only mutation paths.
    private func markCreatePRPending() {
        if !createPRPending {
            createPRPending = true
        }
    }

    /// Clears the "Create PR prompt sent" pending state (see
    /// ``markCreatePRPending()`` for the single-mutation-path rationale).
    private func clearCreatePRPending() {
        createPRPendingTimeoutTask?.cancel()
        createPRPendingTimeoutTask = nil
        if createPRPending {
            createPRPending = false
        }
    }

    /// Production dispatch: the Feed's prompt-injection path
    /// (`FeedJumpResolver.sendText` → `.feedRequestSendText` →
    /// `AppDelegate.handleFeedRequestSendText` → `surface.send_text` socket
    /// line). `pressEnter: true` follows the pasted prompt with a real
    /// Return keypress so agent composers submit it — a trailing CR inside
    /// the bracketed paste would just sit in the input box. Neither send
    /// changes focus or raises a window.
    private static func dispatchCreatePRPromptViaFeedPath(
        workspaceId: UUID,
        surfaceId: UUID,
        text: String
    ) {
        FeedJumpResolver.sendText(
            workspaceId: workspaceId.uuidString,
            surfaceId: surfaceId.uuidString,
            text: text,
            pressEnter: true
        )
    }

    /// Runs one refresh to completion, bypassing pacing and suspension.
    /// Intended for tests and explicit user-driven refreshes.
    func refreshNow() async {
        guard case .local = workspaceRoot else { return }
        scheduledRefreshTask?.cancel()
        scheduledRefreshTask = nil
        if let inFlight = refreshTask {
            await inFlight.value
        }
        startRefresh()
        if let task = refreshTask {
            await task.value
        }
    }

    // MARK: Snapshot publishing

    /// Publishes `newSnapshot` only when it differs from the current one.
    /// (The production path also compares off-main inside `performRefresh`
    /// so the main hop is skipped entirely for equal snapshots.)
    @discardableResult
    func setSnapshotIfChanged(_ newSnapshot: GitChangesSnapshot) -> Bool {
        guard newSnapshot != snapshot else { return false }
        snapshot = newSnapshot
        return true
    }

    // MARK: Refresh scheduling

    private func scheduleRefresh(trigger: RefreshTrigger) {
        guard !isSuspended, case .local = workspaceRoot else { return }
        switch trigger {
        case .gitMetadataEvent, .attach:
            needsBaseReresolve = true
        case .treeEvent, .trailing:
            break
        }
        if refreshTask != nil {
            hasPendingTrailingRefresh = true
            return
        }
        if scheduledRefreshTask != nil {
            // A run is already scheduled; the latched needsBaseReresolve flag
            // carries this trigger's intent.
            return
        }
        let delay = Self.refreshDelay(
            now: Date(),
            lastRefreshEndedAt: lastRefreshEndedAt,
            lastRefreshDuration: lastRefreshDuration
        )
        if delay <= 0 {
            startRefresh()
        } else {
            // Bounded, cancellable self-pacing delay — the delay itself is the
            // intended behavior (Clock.sleep carve-out in cmux-architecture).
            scheduledRefreshTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard let self, !Task.isCancelled else { return }
                self.scheduledRefreshTask = nil
                self.startRefresh()
            }
        }
    }

    private func startRefresh() {
        guard refreshTask == nil, case .local(let workspacePath) = workspaceRoot else { return }
        let refreshGeneration = generation
        let input = GitChangesRefreshInput(
            workspacePath: workspacePath,
            resolveBase: needsBaseReresolve || cachedBase == nil,
            cachedBase: cachedBase,
            previousSnapshot: snapshot,
            counter: untrackedCounter
        )
        needsBaseReresolve = false
        // Detached so the git work never runs on the main actor.
        refreshTask = Task.detached(priority: .utility) { [weak self] in
            let outcome = await GitChangesStore.performRefresh(input)
            await self?.applyRefreshOutcome(outcome, generation: refreshGeneration)
        }
    }

    private func applyRefreshOutcome(_ outcome: GitChangesRefreshOutcome, generation: UInt64) {
        guard generation == self.generation else {
            // Stale result after a root swap or suspend: discard entirely.
            return
        }
        refreshTask = nil
        lastRefreshEndedAt = Date()

        switch outcome {
        case .success(let newSnapshot, let changed, let base, let counter, let duration):
            lastRefreshDuration = duration
            consecutiveGitFailureCount = 0
            cachedBase = base
            untrackedCounter = counter
            if changed {
                setSnapshotIfChanged(newSnapshot)
            }
            if !isSuspended, let repoRoot = newSnapshot.repoRootPath {
                updateTreeWatcher(path: repoRoot)
                refreshGitWatcherPaths(for: repoRoot)
            }
        case .failure(let duration):
            lastRefreshDuration = duration
            consecutiveGitFailureCount += 1
            needsBaseReresolve = true
            if consecutiveGitFailureCount >= 3 {
                // Keep the last rows; only the phase flips to failed.
                setSnapshotIfChanged(
                    GitChangesSnapshot(
                        phase: .failed,
                        repoRootPath: snapshot.repoRootPath,
                        branch: snapshot.branch,
                        baseRef: snapshot.baseRef,
                        mergeBase: snapshot.mergeBase,
                        files: snapshot.files,
                        hasGitHubRemote: snapshot.hasGitHubRemote
                    )
                )
            }
        }

        if hasPendingTrailingRefresh {
            hasPendingTrailingRefresh = false
            scheduleRefresh(trigger: .trailing)
        }
    }

    private func cancelRefreshWork() {
        scheduledRefreshTask?.cancel()
        scheduledRefreshTask = nil
        // Task cancellation SIGTERMs the in-flight git process via the
        // runner's cancellation handler.
        refreshTask?.cancel()
        refreshTask = nil
        hasPendingTrailingRefresh = false
    }

    /// Pure pacing math: seconds to wait before the next refresh may start.
    /// Next refresh ≥ `max(minimumInterval, pacingFactor × last duration)`
    /// after the last one ended. The quiet-window reset only short-circuits
    /// once `max(quietResetInterval, requiredGap)` has elapsed — the required
    /// gap always wins when larger, so a slow refresh (e.g. 10s → 30s gap)
    /// stays paced well past the quiet window.
    nonisolated static func refreshDelay(
        now: Date,
        lastRefreshEndedAt: Date?,
        lastRefreshDuration: TimeInterval,
        minimumInterval: TimeInterval = GitChangesStore.minimumRefreshInterval,
        pacingFactor: Double = GitChangesStore.refreshPacingFactor,
        quietResetInterval: TimeInterval = GitChangesStore.refreshQuietResetInterval
    ) -> TimeInterval {
        guard let lastRefreshEndedAt else { return 0 }
        let sinceLast = now.timeIntervalSince(lastRefreshEndedAt)
        let requiredGap = max(minimumInterval, pacingFactor * lastRefreshDuration)
        guard sinceLast < max(quietResetInterval, requiredGap) else { return 0 }
        return max(0, requiredGap - sinceLast)
    }

    /// Pure containment check: true when `path` equals `ancestor` or lives
    /// beneath it (component-wise after `standardizingPath`; symlinks are not
    /// resolved — a mismatch just falls back to the full root reset).
    nonisolated static func isPath(_ path: String, containedIn ancestor: String) -> Bool {
        let normalizedPath = (path as NSString).standardizingPath
        let normalizedAncestor = (ancestor as NSString).standardizingPath
        if normalizedPath == normalizedAncestor { return true }
        let prefix = normalizedAncestor.hasSuffix("/")
            ? normalizedAncestor
            : normalizedAncestor + "/"
        return normalizedPath.hasPrefix(prefix)
    }

    // MARK: Watchers

    private func updateTreeWatcher(path: String) {
        if treeWatcher?.watchedPaths == [path] { return }
        treeWatcherTask?.cancel()
        treeWatcherTask = nil
        treeWatcher = nil
        guard let watcher = RecursivePathWatcher(paths: [path]) else { return }
        treeWatcher = watcher
        let events = watcher.events
        treeWatcherTask = Task { @MainActor [weak self] in
            for await _ in events {
                guard let self else { break }
                self.scheduleRefresh(trigger: .treeEvent)
            }
        }
    }

    private func refreshGitWatcherPaths(for directory: String) {
        gitWatcherSetupTask?.cancel()
        let setupGeneration = generation
        let service = gitMetadataService
        gitWatcherSetupTask = Task { [weak self] in
            let paths = await service.watchedPaths(for: directory)
            await MainActor.run { [weak self] in
                guard let self,
                      !self.isSuspended,
                      setupGeneration == self.generation else { return }
                self.applyGitWatcherPaths(paths)
            }
        }
    }

    private func applyGitWatcherPaths(_ paths: [String]?) {
        guard let paths, !paths.isEmpty else {
            gitWatcherTask?.cancel()
            gitWatcherTask = nil
            gitWatcher = nil
            return
        }
        if gitWatcher?.watchedPaths == paths { return }
        gitWatcherTask?.cancel()
        gitWatcherTask = nil
        gitWatcher = nil
        guard let watcher = RecursivePathWatcher(paths: paths) else { return }
        gitWatcher = watcher
        let events = watcher.events
        gitWatcherTask = Task { @MainActor [weak self] in
            for await _ in events {
                guard let self else { break }
                self.scheduleRefresh(trigger: .gitMetadataEvent)
            }
        }
    }

    private func teardownWatchers() {
        gitWatcherSetupTask?.cancel()
        gitWatcherSetupTask = nil
        treeWatcherTask?.cancel()
        treeWatcherTask = nil
        treeWatcher = nil
        gitWatcherTask?.cancel()
        gitWatcherTask = nil
        gitWatcher = nil
    }
}

// MARK: - Refresh pipeline (off-main, pure inputs/outputs)

struct GitChangesRefreshInput: Sendable {
    let workspacePath: String
    let resolveBase: Bool
    let cachedBase: GitChangesResolvedBase?
    let previousSnapshot: GitChangesSnapshot
    let counter: GitUntrackedLineCounter
}

enum GitChangesRefreshOutcome: Sendable {
    case success(
        snapshot: GitChangesSnapshot,
        changed: Bool,
        base: GitChangesResolvedBase?,
        counter: GitUntrackedLineCounter,
        duration: TimeInterval
    )
    /// A git spawn failed at the process level (launch failure or timeout) or
    /// a required command exited non-zero unexpectedly.
    case failure(duration: TimeInterval)
}

extension GitChangesStore {
    /// Shared environment for every git spawn. `GIT_OPTIONAL_LOCKS=0` keeps
    /// read-only commands from rewriting `.git/index` (which would re-fire our
    /// own watcher and race the agent's git commands for `index.lock`).
    nonisolated static func gitEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        return environment
    }

    /// Runs one read-only git command with a bounded timeout. Task
    /// cancellation (generation change) SIGTERMs the process.
    nonisolated static func runGit(
        _ arguments: [String],
        in directory: String,
        timeout: TimeInterval = GitChangesStore.gitTimeout
    ) async -> GitProcessResult? {
        let execution = GitProcessExecution(arguments: arguments, workingDirectory: directory)
        // Bounded, cancellable deadline (Clock.sleep carve-out): kills a hung
        // git at the timeout; cancelled on normal completion below.
        let timeoutTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            execution.cancel()
        }
        defer { timeoutTask.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                execution.start(continuation: continuation)
            }
        } onCancel: {
            execution.cancel()
        }
    }

    nonisolated static func firstLine(_ data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let line = text
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let line, !line.isEmpty else { return nil }
        return line
    }

    /// Default-branch resolution chain (ported from the CLI's
    /// `resolvedGitBranchDiffBaseRef`, narrowed per the plan):
    /// `cmux.changes.base` git config (per-repo override, must resolve to a
    /// commit) → `origin/HEAD` symref → local `main` → local `master` → none.
    /// Returns `nil` on a process-level git failure.
    nonisolated static func resolveBase(repoRoot: String) async -> GitChangesResolvedBase? {
        guard let branchResult = await runGit(
            ["rev-parse", "--abbrev-ref", "HEAD"], in: repoRoot
        ) else { return nil }
        let branch = branchResult.exitStatus == 0 ? firstLine(branchResult.stdout) : nil

        // Default-branch base resolution is shared with worktree creation
        // (`GitDefaultBranchResolver`) so a worktree branched off this ref shows
        // an empty diff here. A process-level failure still aborts the refresh.
        let baseResolution = await GitDefaultBranchResolver.resolveBaseRef { arguments in
            guard let result = await runGit(arguments, in: repoRoot) else { return nil }
            return GitDefaultBranchResolver.CommandResult(
                exitStatus: result.exitStatus,
                firstLine: firstLine(result.stdout) ?? ""
            )
        }
        let baseRef: String?
        switch baseResolution {
        case .processFailure:
            return nil
        case .resolved(let resolved):
            baseRef = resolved
        }

        var mergeBase: String?
        if let baseRef {
            guard let result = await runGit(
                ["merge-base", "HEAD", baseRef], in: repoRoot
            ) else { return nil }
            if result.exitStatus == 0 {
                mergeBase = firstLine(result.stdout)
            }
        }
        // GitHub slug detection for the PR header (R18). Reads remote URLs
        // straight from `config` (no git subprocess), so it is cheap enough
        // to ride the base-resolution cadence (`.git` events only).
        let hasGitHubRemote = !(await GitMetadataService().repositorySlugs(forDirectory: repoRoot).isEmpty)
        return GitChangesResolvedBase(
            baseRef: baseRef,
            mergeBase: mergeBase,
            branch: branch,
            hasGitHubRemote: hasGitHubRemote
        )
    }

    /// One full refresh cycle. Runs entirely off-main; the caller applies the
    /// outcome on the main actor (and skips the publish when `changed` is false).
    nonisolated static func performRefresh(
        _ input: GitChangesRefreshInput
    ) async -> GitChangesRefreshOutcome {
        let start = ContinuousClock.now
        func elapsed() -> TimeInterval {
            let duration = ContinuousClock.now - start
            return TimeInterval(duration.components.seconds)
                + TimeInterval(duration.components.attoseconds) / 1e18
        }

        guard let rootResult = await runGit(
            ["rev-parse", "--show-toplevel"], in: input.workspacePath
        ) else { return .failure(duration: elapsed()) }
        guard rootResult.exitStatus == 0, let repoRoot = firstLine(rootResult.stdout) else {
            let newSnapshot = GitChangesSnapshot(phase: .notARepo)
            return .success(
                snapshot: newSnapshot,
                changed: newSnapshot != input.previousSnapshot,
                base: nil,
                counter: input.counter,
                duration: elapsed()
            )
        }

        var base = input.cachedBase
        if input.resolveBase || base == nil {
            guard let resolved = await resolveBase(repoRoot: repoRoot) else {
                return .failure(duration: elapsed())
            }
            base = resolved
        }

        // Merge-base unresolvable → degraded: diff uncommitted changes against
        // HEAD when it exists, untracked-only when it does not (unborn HEAD).
        let degraded = base?.mergeBase == nil
        let diffTarget: String?
        if let mergeBase = base?.mergeBase {
            diffTarget = mergeBase
        } else {
            guard let headProbe = await runGit(
                ["rev-parse", "--verify", "--quiet", "HEAD^{commit}"], in: repoRoot
            ) else { return .failure(duration: elapsed()) }
            diffTarget = headProbe.exitStatus == 0 ? "HEAD" : nil
        }

        var numstatData = Data()
        var nameStatusData = Data()
        if let diffTarget {
            guard let numstatResult = await runGit(
                ["diff", "--numstat", "-z", diffTarget], in: repoRoot
            ), numstatResult.exitStatus == 0 else {
                return .failure(duration: elapsed())
            }
            guard let nameStatusResult = await runGit(
                ["diff", "--name-status", "-z", diffTarget], in: repoRoot
            ), nameStatusResult.exitStatus == 0 else {
                return .failure(duration: elapsed())
            }
            numstatData = numstatResult.stdout
            nameStatusData = nameStatusResult.stdout
        }

        guard let statusResult = await runGit(
            ["status", "--porcelain", "-z", "-uall"], in: repoRoot
        ), statusResult.exitStatus == 0 else {
            return .failure(duration: elapsed())
        }

        let numstat = parseNumstat(numstatData)
        let nameStatus = parseNameStatus(nameStatusData)
        let porcelain = parsePorcelainStatus(statusResult.stdout)

        // Untracked line counts, in-process with the (path, size, mtime) cache.
        var counter = input.counter
        var readsThisRefresh = 0
        var untrackedAddedLines: [String: Int] = [:]
        var untrackedBinaryPaths: Set<String> = []
        let untrackedPaths = porcelain
            .filter { $0.indexStatus == "?" }
            .map(\.path)
            .sorted()
        var untrackedAbsolutePaths: Set<String> = []
        for relativePath in untrackedPaths {
            let absolutePath = (repoRoot as NSString).appendingPathComponent(relativePath)
            untrackedAbsolutePaths.insert(absolutePath)
            let allowRead = readsThisRefresh < GitUntrackedLineCounter.maxCountedFilesPerRefresh
            let result = counter.count(atPath: absolutePath, allowRead: allowRead)
            if result.didRead { readsThisRefresh += 1 }
            if result.isBinary { untrackedBinaryPaths.insert(relativePath) }
            if let lines = result.addedLines { untrackedAddedLines[relativePath] = lines }
        }
        // Entries for files no longer untracked (committed, deleted, ignored)
        // would otherwise accumulate forever.
        counter.pruneCache(keepingPaths: untrackedAbsolutePaths)

        let files = mergeChangedFiles(
            numstat: numstat,
            nameStatus: nameStatus,
            porcelain: porcelain,
            untrackedAddedLines: untrackedAddedLines,
            untrackedBinaryPaths: untrackedBinaryPaths,
            isSubmodulePath: { relativePath in
                var isDirectory: ObjCBool = false
                let absolutePath = (repoRoot as NSString).appendingPathComponent(relativePath)
                return FileManager.default.fileExists(atPath: absolutePath, isDirectory: &isDirectory)
                    && isDirectory.boolValue
            }
        )

        let newSnapshot = GitChangesSnapshot(
            phase: degraded ? .degraded : .ready,
            repoRootPath: repoRoot,
            branch: base?.branch,
            baseRef: degraded ? nil : base?.baseRef,
            mergeBase: base?.mergeBase,
            files: files,
            hasGitHubRemote: base?.hasGitHubRemote ?? false
        )
        return .success(
            snapshot: newSnapshot,
            changed: newSnapshot != input.previousSnapshot,
            base: base,
            counter: counter,
            duration: elapsed()
        )
    }

    // MARK: Parsers (pure)

    /// Parses `git diff --numstat -z` output.
    ///
    /// Records: `added\tdeleted\tpath\0`. Renames emit an empty path field
    /// followed by two NUL-separated paths: `added\tdeleted\t\0old\0new\0`.
    /// Binary files report `-\t-`.
    nonisolated static func parseNumstat(_ data: Data) -> [GitNumstatEntry] {
        let tokens = nulSeparatedTokens(data)
        var entries: [GitNumstatEntry] = []
        var index = 0
        while index < tokens.count {
            let record = tokens[index]
            let fields = record.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else {
                index += 1
                continue
            }
            let addedField = String(fields[0])
            let deletedField = String(fields[1])
            let pathField = String(fields[2])
            let isBinary = addedField == "-" || deletedField == "-"
            let added = isBinary ? nil : Int(addedField)
            let deleted = isBinary ? nil : Int(deletedField)
            if !isBinary, added == nil || deleted == nil {
                index += 1
                continue
            }
            if pathField.isEmpty {
                // Rename: next two tokens are the old then new path.
                guard index + 2 < tokens.count else { break }
                entries.append(
                    GitNumstatEntry(
                        path: tokens[index + 2],
                        previousPath: tokens[index + 1],
                        addedLines: added,
                        deletedLines: deleted,
                        isBinary: isBinary
                    )
                )
                index += 3
            } else {
                entries.append(
                    GitNumstatEntry(
                        path: pathField,
                        previousPath: nil,
                        addedLines: added,
                        deletedLines: deleted,
                        isBinary: isBinary
                    )
                )
                index += 1
            }
        }
        return entries
    }

    /// Parses `git diff --name-status -z` output.
    ///
    /// Records are NUL-separated: `status\0path\0`, with renames/copies as
    /// `R<score>\0old\0new\0`.
    nonisolated static func parseNameStatus(_ data: Data) -> [GitNameStatusEntry] {
        let tokens = nulSeparatedTokens(data)
        var entries: [GitNameStatusEntry] = []
        var index = 0
        while index + 1 < tokens.count {
            let status = tokens[index]
            guard let letter = status.first else {
                index += 1
                continue
            }
            if letter == "R" || letter == "C" {
                guard index + 2 < tokens.count else { break }
                entries.append(
                    GitNameStatusEntry(
                        statusLetter: letter,
                        path: tokens[index + 2],
                        previousPath: tokens[index + 1]
                    )
                )
                index += 3
            } else {
                entries.append(
                    GitNameStatusEntry(
                        statusLetter: letter,
                        path: tokens[index + 1],
                        previousPath: nil
                    )
                )
                index += 2
            }
        }
        return entries
    }

    /// Parses `git status --porcelain -z -uall` (v1) output.
    ///
    /// Records: `XY path\0`; renames/copies carry the origin as the next
    /// NUL-separated token (target first, then origin).
    nonisolated static func parsePorcelainStatus(_ data: Data) -> [GitPorcelainEntry] {
        let tokens = nulSeparatedTokens(data)
        var entries: [GitPorcelainEntry] = []
        var index = 0
        while index < tokens.count {
            let record = tokens[index]
            guard record.count >= 4 else {
                index += 1
                continue
            }
            let characters = Array(record)
            let indexStatus = characters[0]
            let workTreeStatus = characters[1]
            let path = String(characters[3...])
            var previousPath: String?
            if indexStatus == "R" || indexStatus == "C"
                || workTreeStatus == "R" || workTreeStatus == "C" {
                if index + 1 < tokens.count {
                    previousPath = tokens[index + 1]
                    index += 1
                }
            }
            entries.append(
                GitPorcelainEntry(
                    indexStatus: indexStatus,
                    workTreeStatus: workTreeStatus,
                    path: path,
                    previousPath: previousPath
                )
            )
            index += 1
        }
        return entries
    }

    /// Merges numstat counts, name-status letters, and porcelain status into
    /// final rows: staged + unstaged collapse to one row (numstat vs the
    /// merge-base already spans both), conflicts override with no counts,
    /// submodule pointer changes carry no counts, untracked rows take the
    /// in-process counts.
    nonisolated static func mergeChangedFiles(
        numstat: [GitNumstatEntry],
        nameStatus: [GitNameStatusEntry],
        porcelain: [GitPorcelainEntry],
        untrackedAddedLines: [String: Int],
        untrackedBinaryPaths: Set<String>,
        isSubmodulePath: (String) -> Bool
    ) -> [GitChangedFile] {
        let nameStatusByPath = Dictionary(
            nameStatus.map { ($0.path, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var rowsByPath: [String: GitChangedFile] = [:]

        for entry in numstat {
            let nameStatusEntry = nameStatusByPath[entry.path]
            var status = Self.status(forNameStatusLetter: nameStatusEntry?.statusLetter)
            if status == .modified, entry.previousPath != nil {
                status = .renamed
            }
            var added = entry.addedLines
            var deleted = entry.deletedLines
            var isBinary = entry.isBinary
            if isSubmodulePath(entry.path) {
                status = .submodule
                added = nil
                deleted = nil
                isBinary = false
            }
            rowsByPath[entry.path] = GitChangedFile(
                path: entry.path,
                previousPath: entry.previousPath ?? nameStatusEntry?.previousPath,
                status: status,
                isBinary: isBinary,
                addedLines: added,
                deletedLines: deleted
            )
        }

        for entry in porcelain {
            if entry.indexStatus == "?" {
                guard rowsByPath[entry.path] == nil else { continue }
                let isBinary = untrackedBinaryPaths.contains(entry.path)
                let added = untrackedAddedLines[entry.path]
                rowsByPath[entry.path] = GitChangedFile(
                    path: entry.path,
                    previousPath: nil,
                    status: .untracked,
                    isBinary: isBinary,
                    addedLines: added,
                    deletedLines: added != nil ? 0 : nil
                )
            } else if Self.isConflict(index: entry.indexStatus, workTree: entry.workTreeStatus) {
                rowsByPath[entry.path] = GitChangedFile(
                    path: entry.path,
                    previousPath: rowsByPath[entry.path]?.previousPath,
                    status: .conflicted,
                    isBinary: false,
                    addedLines: nil,
                    deletedLines: nil
                )
            }
            // Other tracked porcelain entries only annotate rows that numstat
            // (vs the merge-base) already produced; they never add rows.
        }

        return rowsByPath.values.sorted { $0.path < $1.path }
    }

    nonisolated private static func status(
        forNameStatusLetter letter: Character?
    ) -> GitChangedFileStatus {
        switch letter {
        case "A": return .added
        case "D": return .deleted
        case "R": return .renamed
        case "C": return .copied
        case "T": return .typeChanged
        default: return .modified
        }
    }

    nonisolated private static func isConflict(index: Character, workTree: Character) -> Bool {
        if index == "U" || workTree == "U" { return true }
        return (index == "D" && workTree == "D") || (index == "A" && workTree == "A")
    }

    nonisolated private static func nulSeparatedTokens(_ data: Data) -> [String] {
        guard !data.isEmpty else { return [] }
        return data
            .split(separator: 0, omittingEmptySubsequences: false)
            .compactMap { chunk -> String? in
                guard !chunk.isEmpty else { return nil }
                return String(data: Data(chunk), encoding: .utf8)
            }
    }
}

// MARK: - Create PR logic (pure)

/// Pure target-selection and prompt policy for the Changes header's Create PR
/// button, kept off the store and views so it is unit-testable.
nonisolated enum GitChangesCreatePRLogic {
    /// One agent-terminal panel eligible to receive the Create PR prompt.
    /// Candidates are built from `Workspace.agentPIDKeysByPanelId`, which only
    /// agent hook registration populates — a plain shell never appears here
    /// (R16: the prompt must never land where it would execute as commands).
    struct AgentPanelCandidate: Equatable, Sendable {
        let panelId: UUID
        /// Latest agent status-entry timestamp attributable to the panel;
        /// `nil` when the agent has not reported status yet.
        let lastActivityAt: Date?

        init(panelId: UUID, lastActivityAt: Date? = nil) {
            self.panelId = panelId
            self.lastActivityAt = lastActivityAt
        }
    }

    /// The fixed prompt typed into the agent terminal.
    ///
    /// Deliberately a constant with NO interpolation: branch names and other
    /// repo-derived strings are attacker-influencable (a crafted branch name
    /// would be typed into the agent terminal verbatim), so the agent is told
    /// to use "the current branch" instead. Fixed English by convention for
    /// agent-directed prompts (the Feed path sends raw user text; agent CLIs
    /// are English-first) — this string is consumed by the agent, not shown
    /// in cmux UI, so it is intentionally not localized.
    static let promptText = "Please push the current branch under its existing name and "
        + "create a pull request for it: write a descriptive title and body "
        + "summarizing the changes, then report the PR URL."

    /// Targeting rule (R10/R16): the workspace's focused panel when it is an
    /// agent terminal, otherwise the agent panel with the most recent status
    /// activity ("most-recently-active agent"); panels that never reported
    /// status rank last; ties break on panel id for determinism. Returns
    /// `nil` when the workspace has no agent terminal (button disabled).
    static func targetPanelId(
        candidates: [AgentPanelCandidate],
        focusedPanelId: UUID?
    ) -> UUID? {
        if let focusedPanelId, candidates.contains(where: { $0.panelId == focusedPanelId }) {
            return focusedPanelId
        }
        return candidates.min { lhs, rhs in
            let lhsActivity = lhs.lastActivityAt ?? .distantPast
            let rhsActivity = rhs.lastActivityAt ?? .distantPast
            if lhsActivity != rhsActivity {
                return lhsActivity > rhsActivity // most recent first
            }
            return lhs.panelId.uuidString < rhs.panelId.uuidString
        }?.panelId
    }
}
