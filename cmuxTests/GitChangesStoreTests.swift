import Combine
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Git changes store")
struct GitChangesStoreTests {

    // MARK: - Fixture helpers

    private func makeTempDirectory() throws -> String {
        let path = NSTemporaryDirectory()
            .appending("GitChangesStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            atPath: path,
            withIntermediateDirectories: true
        )
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// Normalizes a path for comparison: `resolvingSymlinksInPath()` strips
    /// the `/private` prefix, while `git rev-parse --show-toplevel` reports
    /// `/private/var/...`; running both sides through this makes them equal.
    private func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    @discardableResult
    private func git(_ arguments: [String], in directory: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        environment["GIT_AUTHOR_NAME"] = "test"
        environment["GIT_AUTHOR_EMAIL"] = "test@example.com"
        environment["GIT_COMMITTER_NAME"] = "test"
        environment["GIT_COMMITTER_EMAIL"] = "test@example.com"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: output, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "GitChangesStoreTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) failed: \(text)"]
            )
        }
        return text
    }

    private func write(_ contents: String, to relativePath: String, in directory: String) throws {
        let url = URL(fileURLWithPath: directory).appendingPathComponent(relativePath)
        try contents.data(using: .utf8)!.write(to: url)
    }

    // MARK: - Numstat parsing

    @Test func numstatParsesModifyAddDeleteRecords() {
        let data = Data("3\t1\tfile.txt\u{0}5\t0\tadded.txt\u{0}0\t4\tdeleted.txt\u{0}".utf8)
        let entries = GitChangesStore.parseNumstat(data)
        #expect(entries.count == 3)
        #expect(entries[0] == GitNumstatEntry(
            path: "file.txt", previousPath: nil, addedLines: 3, deletedLines: 1, isBinary: false
        ))
        #expect(entries[1].addedLines == 5)
        #expect(entries[1].deletedLines == 0)
        #expect(entries[2].path == "deleted.txt")
        #expect(entries[2].deletedLines == 4)
    }

    @Test func numstatParsesRenameTwoPathForm() {
        // Renames emit an empty path field, then old and new paths as
        // separate NUL-terminated tokens.
        let data = Data("1\t0\t\u{0}old name.txt\u{0}new name.txt\u{0}2\t2\tother.txt\u{0}".utf8)
        let entries = GitChangesStore.parseNumstat(data)
        #expect(entries.count == 2)
        #expect(entries[0].path == "new name.txt")
        #expect(entries[0].previousPath == "old name.txt")
        #expect(entries[0].addedLines == 1)
        #expect(entries[1].path == "other.txt")
    }

    @Test func numstatMarksBinaryRecords() {
        let data = Data("-\t-\tbin.dat\u{0}".utf8)
        let entries = GitChangesStore.parseNumstat(data)
        #expect(entries.count == 1)
        #expect(entries[0].isBinary)
        #expect(entries[0].addedLines == nil)
        #expect(entries[0].deletedLines == nil)
    }

    @Test func numstatParsesUnicodeAndSpacePaths() {
        let data = Data("2\t0\t日本語 ファイル.txt\u{0}1\t1\tsp ace/depth two.txt\u{0}".utf8)
        let entries = GitChangesStore.parseNumstat(data)
        #expect(entries.count == 2)
        #expect(entries[0].path == "日本語 ファイル.txt")
        #expect(entries[1].path == "sp ace/depth two.txt")
    }

    // MARK: - Name-status and porcelain parsing

    @Test func nameStatusParsesLettersAndRenames() {
        let data = Data("A\u{0}bin.dat\u{0}R075\u{0}old.txt\u{0}new.txt\u{0}M\u{0}sp ace.txt\u{0}".utf8)
        let entries = GitChangesStore.parseNameStatus(data)
        #expect(entries.count == 3)
        #expect(entries[0].statusLetter == "A")
        #expect(entries[0].path == "bin.dat")
        #expect(entries[1].statusLetter == "R")
        #expect(entries[1].path == "new.txt")
        #expect(entries[1].previousPath == "old.txt")
        #expect(entries[2].statusLetter == "M")
        #expect(entries[2].path == "sp ace.txt")
    }

    @Test func porcelainParsesRenameTargetThenOrigin() {
        let data = Data("R  new.txt\u{0}old.txt\u{0}?? plain.txt\u{0} M tracked.txt\u{0}".utf8)
        let entries = GitChangesStore.parsePorcelainStatus(data)
        #expect(entries.count == 3)
        #expect(entries[0].indexStatus == "R")
        #expect(entries[0].path == "new.txt")
        #expect(entries[0].previousPath == "old.txt")
        #expect(entries[1].indexStatus == "?")
        #expect(entries[1].path == "plain.txt")
        #expect(entries[2].indexStatus == " ")
        #expect(entries[2].workTreeStatus == "M")
    }

    // MARK: - Merge

    @Test func mergeProducesUntrackedRowsWithCounts() {
        let porcelain = [
            GitPorcelainEntry(indexStatus: "?", workTreeStatus: "?", path: "new.txt", previousPath: nil),
            GitPorcelainEntry(indexStatus: "?", workTreeStatus: "?", path: "big.bin", previousPath: nil),
        ]
        let files = GitChangesStore.mergeChangedFiles(
            numstat: [],
            nameStatus: [],
            porcelain: porcelain,
            untrackedAddedLines: ["new.txt": 2],
            untrackedBinaryPaths: ["big.bin"],
            isSubmodulePath: { _ in false }
        )
        #expect(files.count == 2)
        let newRow = files.first { $0.path == "new.txt" }
        #expect(newRow?.status == .untracked)
        #expect(newRow?.addedLines == 2)
        #expect(newRow?.deletedLines == 0)
        let binaryRow = files.first { $0.path == "big.bin" }
        #expect(binaryRow?.status == .untracked)
        #expect(binaryRow?.isBinary == true)
        #expect(binaryRow?.addedLines == nil)
    }

    @Test func mergeMarksConflictedWithoutCounts() {
        let numstat = [
            GitNumstatEntry(path: "conflict.txt", previousPath: nil, addedLines: 3, deletedLines: 1, isBinary: false)
        ]
        let porcelain = [
            GitPorcelainEntry(indexStatus: "U", workTreeStatus: "U", path: "conflict.txt", previousPath: nil)
        ]
        let files = GitChangesStore.mergeChangedFiles(
            numstat: numstat,
            nameStatus: [],
            porcelain: porcelain,
            untrackedAddedLines: [:],
            untrackedBinaryPaths: [],
            isSubmodulePath: { _ in false }
        )
        #expect(files.count == 1)
        #expect(files[0].status == .conflicted)
        #expect(files[0].addedLines == nil)
        #expect(files[0].deletedLines == nil)
    }

    @Test func mergeCollapsesStagedAndUnstagedToOneRow() {
        let numstat = [
            GitNumstatEntry(path: "file.txt", previousPath: nil, addedLines: 2, deletedLines: 1, isBinary: false)
        ]
        let nameStatus = [
            GitNameStatusEntry(statusLetter: "M", path: "file.txt", previousPath: nil)
        ]
        // Staged + unstaged edits to the same path: porcelain reports "MM".
        let porcelain = [
            GitPorcelainEntry(indexStatus: "M", workTreeStatus: "M", path: "file.txt", previousPath: nil)
        ]
        let files = GitChangesStore.mergeChangedFiles(
            numstat: numstat,
            nameStatus: nameStatus,
            porcelain: porcelain,
            untrackedAddedLines: [:],
            untrackedBinaryPaths: [],
            isSubmodulePath: { _ in false }
        )
        #expect(files.count == 1)
        #expect(files[0].status == .modified)
        #expect(files[0].addedLines == 2)
        #expect(files[0].deletedLines == 1)
    }

    @Test func mergeMarksSubmodulePointerChangeWithoutCounts() {
        let numstat = [
            GitNumstatEntry(path: "subdir", previousPath: nil, addedLines: 1, deletedLines: 1, isBinary: false)
        ]
        let nameStatus = [
            GitNameStatusEntry(statusLetter: "M", path: "subdir", previousPath: nil)
        ]
        let files = GitChangesStore.mergeChangedFiles(
            numstat: numstat,
            nameStatus: nameStatus,
            porcelain: [],
            untrackedAddedLines: [:],
            untrackedBinaryPaths: [],
            isSubmodulePath: { $0 == "subdir" }
        )
        #expect(files.count == 1)
        #expect(files[0].status == .submodule)
        #expect(files[0].addedLines == nil)
        #expect(files[0].deletedLines == nil)
    }

    // MARK: - Untracked line counting

    @Test func untrackedCounterUsesNumstatNewlineSemantics() throws {
        // Pure measurement first.
        #expect(GitUntrackedLineCounter.measure(Data("a\nb".utf8)).lineCount == 2)
        #expect(GitUntrackedLineCounter.measure(Data("a\nb\n".utf8)).lineCount == 2)
        #expect(GitUntrackedLineCounter.measure(Data()).lineCount == 0)
        #expect(GitUntrackedLineCounter.measure(Data([0x61, 0x00, 0x62])).isBinary)

        let directory = try makeTempDirectory()
        try write("one\ntwo\nthree", to: "no-trailing.txt", in: directory)
        var counter = GitUntrackedLineCounter()
        let result = counter.count(atPath: directory + "/no-trailing.txt")
        #expect(result.addedLines == 3)
        #expect(result.didRead)
        #expect(!result.isBinary)
    }

    @Test func untrackedCounterSkipsFilesOverOneMegabyte() throws {
        let directory = try makeTempDirectory()
        let path = directory + "/big.txt"
        let data = Data(repeating: 0x61, count: Int(GitUntrackedLineCounter.maxCountableFileSize) + 1)
        try data.write(to: URL(fileURLWithPath: path))
        var counter = GitUntrackedLineCounter()
        let result = counter.count(atPath: path)
        #expect(result.addedLines == nil)
        #expect(!result.didRead)
    }

    @Test func untrackedCounterHandlesVanishedFile() throws {
        let directory = try makeTempDirectory()
        var counter = GitUntrackedLineCounter()
        let result = counter.count(atPath: directory + "/never-existed.txt")
        #expect(result.addedLines == nil)
        #expect(!result.isBinary)
        #expect(!result.didRead)
    }

    @Test func untrackedCounterCacheHitSkipsReread() throws {
        let directory = try makeTempDirectory()
        let path = directory + "/cached.txt"
        try write("a\nb\n", to: "cached.txt", in: directory)
        var counter = GitUntrackedLineCounter()

        let first = counter.count(atPath: path)
        #expect(first.addedLines == 2)
        #expect(first.didRead)

        let second = counter.count(atPath: path)
        #expect(second.addedLines == 2)
        #expect(!second.didRead)

        // Change size: the (path, size, mtime) cache key misses and re-reads.
        try write("a\nb\nc\nd\n", to: "cached.txt", in: directory)
        let third = counter.count(atPath: path)
        #expect(third.addedLines == 4)
        #expect(third.didRead)
    }

    // MARK: - Pacing math

    @Test func refreshDelayPacingMath() {
        let base = Date(timeIntervalSinceReferenceDate: 1_000)

        // No previous refresh → immediate.
        #expect(GitChangesStore.refreshDelay(
            now: base, lastRefreshEndedAt: nil, lastRefreshDuration: 5
        ) == 0)

        // Quiet window (≥2s since last end, required gap already smaller)
        // resets pacing → immediate.
        #expect(GitChangesStore.refreshDelay(
            now: base.addingTimeInterval(2.0),
            lastRefreshEndedAt: base,
            lastRefreshDuration: 0.5
        ) == 0)

        // A 1s refresh enforces a 3s gap even past the 2s quiet window: the
        // required gap wins when it is the larger of the two.
        #expect(abs(GitChangesStore.refreshDelay(
            now: base.addingTimeInterval(2.0),
            lastRefreshEndedAt: base,
            lastRefreshDuration: 1.0
        ) - 1.0) < 0.0001)

        // Fast refresh → 300ms floor applies: 0.1s elapsed of a 0.3s gap.
        let floored = GitChangesStore.refreshDelay(
            now: base.addingTimeInterval(0.1),
            lastRefreshEndedAt: base,
            lastRefreshDuration: 0.05
        )
        #expect(abs(floored - 0.2) < 0.0001)

        // Slow refresh → 3× duration: 1.0s elapsed of a 1.5s gap.
        let paced = GitChangesStore.refreshDelay(
            now: base.addingTimeInterval(1.0),
            lastRefreshEndedAt: base,
            lastRefreshDuration: 0.5
        )
        #expect(abs(paced - 0.5) < 0.0001)

        // Gap already satisfied → immediate.
        #expect(GitChangesStore.refreshDelay(
            now: base.addingTimeInterval(0.4),
            lastRefreshEndedAt: base,
            lastRefreshDuration: 0.05
        ) == 0)

        // Slow refresh (10s) → the 3× gap (30s) outlives the quiet window:
        // an event at +3s still waits ~27s (the quiet reset must not
        // short-circuit a larger required gap).
        let slow = GitChangesStore.refreshDelay(
            now: base.addingTimeInterval(3.0),
            lastRefreshEndedAt: base,
            lastRefreshDuration: 10.0
        )
        #expect(abs(slow - 27.0) < 0.0001)

        // Once the full 30s gap has elapsed, the next event is immediate.
        #expect(GitChangesStore.refreshDelay(
            now: base.addingTimeInterval(31.0),
            lastRefreshEndedAt: base,
            lastRefreshDuration: 10.0
        ) == 0)
    }

    // MARK: - Path containment (same-repo root changes)

    @Test func pathContainmentMatchesEqualAndDescendantPathsOnly() {
        #expect(GitChangesStore.isPath("/repo", containedIn: "/repo"))
        #expect(GitChangesStore.isPath("/repo/sub", containedIn: "/repo"))
        #expect(GitChangesStore.isPath("/repo/sub/deep", containedIn: "/repo"))
        #expect(GitChangesStore.isPath("/repo/sub/", containedIn: "/repo"))
        // Sibling with a shared prefix is NOT contained.
        #expect(!GitChangesStore.isPath("/repository", containedIn: "/repo"))
        // The ancestor itself is not contained in its child.
        #expect(!GitChangesStore.isPath("/repo", containedIn: "/repo/sub"))
        #expect(!GitChangesStore.isPath("/other", containedIn: "/repo"))
    }

    @Test @MainActor func sameRepoSubdirectoryRootChangeKeepsSnapshot() async throws {
        let directory = try makeTempDirectory()
        try git(["init", "-q", "-b", "main"], in: directory)
        try write("one\n", to: "base.txt", in: directory)
        try git(["add", "."], in: directory)
        try git(["commit", "-q", "-m", "init"], in: directory)
        try FileManager.default.createDirectory(
            atPath: directory + "/sub",
            withIntermediateDirectories: true
        )
        try write("hello\n", to: "sub/untracked.txt", in: directory)

        let store = GitChangesStore()
        store.setWorkspaceRoot(.local(path: directory))
        await store.refreshNow()
        let before = store.snapshot
        #expect(before.phase != .loading)
        #expect(before.repoRootPath != nil)

        // cwd moves to a subdirectory of the resolved repo root: the snapshot
        // survives (no `.loading` flash / cache drop), only a refresh is
        // scheduled.
        store.setWorkspaceRoot(.local(path: directory + "/sub"))
        #expect(store.snapshot == before)

        // A refresh from the subdirectory resolves the same repo root.
        await store.refreshNow()
        #expect(normalizedPath(store.snapshot.repoRootPath ?? "") == directory)
    }

    @Test func untrackedCounterPrunesEntriesOutsideKeepSet() throws {
        let directory = try makeTempDirectory()
        try write("a\n", to: "keep.txt", in: directory)
        try write("b\n", to: "drop.txt", in: directory)
        var counter = GitUntrackedLineCounter()
        _ = counter.count(atPath: directory + "/keep.txt")
        _ = counter.count(atPath: directory + "/drop.txt")
        #expect(counter.cache.count == 2)

        counter.pruneCache(keepingPaths: [directory + "/keep.txt"])
        #expect(counter.cache.count == 1)
        #expect(counter.cache[directory + "/keep.txt"] != nil)
        #expect(counter.cache[directory + "/drop.txt"] == nil)
    }

    // MARK: - Publish discipline

    @Test @MainActor func equalSnapshotsPublishOnce() {
        let store = GitChangesStore()
        var publishCount = 0
        let cancellable = store.objectWillChange.sink { publishCount += 1 }
        defer { cancellable.cancel() }

        func makeSnapshot() -> GitChangesSnapshot {
            GitChangesSnapshot(
                phase: .ready,
                repoRootPath: "/tmp/repo",
                branch: "feature",
                baseRef: "main",
                mergeBase: "abc123",
                files: [
                    GitChangedFile(
                        path: "file.txt",
                        previousPath: nil,
                        status: .modified,
                        isBinary: false,
                        addedLines: 2,
                        deletedLines: 1
                    )
                ]
            )
        }

        #expect(store.setSnapshotIfChanged(makeSnapshot()))
        #expect(!store.setSnapshotIfChanged(makeSnapshot()))
        #expect(publishCount == 1)
        #expect(store.snapshot.totalAddedLines == 2)
        #expect(store.snapshot.totalDeletedLines == 1)
    }

    // MARK: - Default-branch chain (real repos)

    @Test func defaultBranchChainPrefersOriginHead() async throws {
        let directory = try makeTempDirectory()
        try git(["init", "-q", "-b", "main"], in: directory)
        try git(["commit", "-q", "--allow-empty", "-m", "init"], in: directory)
        try git(["update-ref", "refs/remotes/origin/main", "HEAD"], in: directory)
        try git(
            ["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"],
            in: directory
        )

        let resolved = await GitChangesStore.resolveBase(repoRoot: directory)
        let base = try #require(resolved)
        #expect(base.baseRef == "origin/main")
        #expect(base.mergeBase != nil)
        #expect(base.branch == "main")
    }

    @Test func defaultBranchChainFallsBackToLocalMainThenNone() async throws {
        // origin/HEAD unset, local main exists → "main".
        let withMain = try makeTempDirectory()
        try git(["init", "-q", "-b", "main"], in: withMain)
        try git(["commit", "-q", "--allow-empty", "-m", "init"], in: withMain)
        try git(["checkout", "-q", "-b", "feature"], in: withMain)
        let resolvedMain = await GitChangesStore.resolveBase(repoRoot: withMain)
        let mainBase = try #require(resolvedMain)
        #expect(mainBase.baseRef == "main")
        #expect(mainBase.mergeBase != nil)
        #expect(mainBase.branch == "feature")

        // Neither origin/HEAD nor main/master → no base (uncommitted-only mode).
        let without = try makeTempDirectory()
        try git(["init", "-q", "-b", "work"], in: without)
        try git(["commit", "-q", "--allow-empty", "-m", "init"], in: without)
        let resolvedNone = await GitChangesStore.resolveBase(repoRoot: without)
        let noBase = try #require(resolvedNone)
        #expect(noBase.baseRef == nil)
        #expect(noBase.mergeBase == nil)
    }

    // MARK: - Store integration (real repos)

    @Test @MainActor func mergeBaseFailureProducesDegradedSnapshot() async throws {
        // Orphan branch: `main` exists but shares no history with HEAD, so
        // `git merge-base HEAD main` fails → degraded (uncommitted + untracked).
        let directory = try makeTempDirectory()
        try git(["init", "-q", "-b", "main"], in: directory)
        try write("base\n", to: "base.txt", in: directory)
        try git(["add", "."], in: directory)
        try git(["commit", "-q", "-m", "init"], in: directory)
        try git(["checkout", "-q", "--orphan", "orphan"], in: directory)
        try git(["commit", "-q", "-m", "orphan root"], in: directory)
        try write("hello\nworld\n", to: "untracked.txt", in: directory)

        let store = GitChangesStore()
        store.setWorkspaceRoot(.local(path: directory))
        await store.refreshNow()

        #expect(store.snapshot.phase == .degraded)
        #expect(store.snapshot.baseRef == nil)
        #expect(normalizedPath(store.snapshot.repoRootPath ?? "") == directory)
        let untracked = store.snapshot.files.first { $0.path == "untracked.txt" }
        #expect(untracked?.status == .untracked)
        #expect(untracked?.addedLines == 2)
    }

    @Test @MainActor func fullRefreshProducesRowsAndCounts() async throws {
        let directory = try makeTempDirectory()
        try git(["init", "-q", "-b", "main"], in: directory)
        try write("one\ntwo\nthree\n", to: "base.txt", in: directory)
        try git(["add", "."], in: directory)
        try git(["commit", "-q", "-m", "init"], in: directory)
        try git(["checkout", "-q", "-b", "feature"], in: directory)
        // Committed change on the branch (+2 lines).
        try write("one\ntwo\nthree\nfour\nfive\n", to: "base.txt", in: directory)
        try git(["commit", "-q", "-am", "extend"], in: directory)
        // Untracked file: 2 lines, no trailing newline.
        try write("a\nb", to: "notes.txt", in: directory)

        let store = GitChangesStore()
        store.setWorkspaceRoot(.local(path: directory))
        await store.refreshNow()

        let snapshot = store.snapshot
        #expect(snapshot.phase == .ready)
        #expect(snapshot.branch == "feature")
        #expect(snapshot.baseRef == "main")
        #expect(normalizedPath(snapshot.repoRootPath ?? "") == directory)
        #expect(snapshot.files.count == 2)

        let modified = snapshot.files.first { $0.path == "base.txt" }
        #expect(modified?.status == .modified)
        #expect(modified?.addedLines == 2)
        #expect(modified?.deletedLines == 0)

        let untracked = snapshot.files.first { $0.path == "notes.txt" }
        #expect(untracked?.status == .untracked)
        #expect(untracked?.addedLines == 2)
        #expect(untracked?.deletedLines == 0)

        #expect(snapshot.totalAddedLines == 4)
        #expect(snapshot.totalDeletedLines == 0)

        // A second refresh with no changes keeps the equal snapshot identity.
        let before = snapshot
        await store.refreshNow()
        #expect(store.snapshot == before)
    }
}
