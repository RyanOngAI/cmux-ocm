import Foundation

/// Result of creating a git worktree: the absolute worktree path and the
/// branch that was created for it. The branch name doubles as the friendly
/// display name for the workspace.
struct WorktreeCreationResult: Sendable, Equatable {
    let worktreePath: String
    let branchName: String
}

/// Typed failures from ``WorktreeCreationService``. Carries only what callers
/// need to branch on; ``worktreeAddFailed`` keeps git's stderr for surfacing.
enum WorktreeCreationError: Error {
    /// The provided path is not inside a git working tree.
    case notAGitRepository
    /// `HEAD` does not resolve to a commit (unborn branch); there is nothing
    /// to branch a worktree from.
    case noCommitOnHead
    /// `git rev-parse --git-path info/exclude` returned nothing usable.
    case couldNotResolveExcludeFile
    /// `git worktree add` exited non-zero.
    case worktreeAddFailed(status: Int32, details: String)
}

/// Production primitive that creates a git worktree off the repository's
/// current `HEAD` and returns where it landed. This is the single git-worktree
/// path shared by every cmux entrypoint (the repo-backed group "+" and the
/// extension-sidebar prototype).
///
/// It deliberately does **only** the git work — no sample files, no setup
/// command, no workspace spawning. Callers layer their own behavior on the
/// returned ``WorktreeCreationResult``.
enum WorktreeCreationService {
    /// Friendly, git-ref-safe codenames for auto-generated worktrees
    /// (Conductor-style). Picked in order; the first name not already taken by
    /// a branch or an on-disk worktree directory wins.
    static let codenames: [String] = [
        "amsterdam", "athens", "atlanta", "austin", "bangkok", "barcelona",
        "berlin", "boston", "brussels", "cairo", "chicago", "copenhagen",
        "dallas", "denver", "dublin", "geneva", "helsinki", "istanbul",
        "jakarta", "juneau", "kyoto", "lima", "lisbon", "london", "madrid",
        "manila", "melbourne", "nairobi", "naples", "oslo", "ottawa", "phoenix",
        "porto", "prague", "quebec", "quito", "reno", "rome", "seattle",
        "seoul", "sydney", "taipei", "tokyo", "toronto", "vienna", "warsaw",
        "wellington", "zurich"
    ]

    /// Creates a new worktree under `<repoRoot>/.cmux/worktrees/<name>` on a new
    /// branch `<name>` off `HEAD`, ensuring `.cmux/` stays locally git-ignored.
    static func createWorktree(repoRoot: String) async throws -> WorktreeCreationResult {
        let root = URL(fileURLWithPath: repoRoot, isDirectory: true).standardizedFileURL

        // 1. Must be a git working tree.
        let inside = try await runGit(["rev-parse", "--is-inside-work-tree"], in: root.path)
        guard inside.status == 0,
              decode(inside.output).trimmingCharacters(in: .whitespacesAndNewlines) == "true" else {
            throw WorktreeCreationError.notAGitRepository
        }

        // 2. HEAD must resolve to a commit — `worktree add … HEAD` fails on an
        //    unborn branch, and we want a typed error, not a raw git failure.
        let head = try await runGit(["rev-parse", "--verify", "--quiet", "HEAD"], in: root.path)
        guard head.status == 0, !decode(head.output).isEmpty else {
            throw WorktreeCreationError.noCommitOnHead
        }

        // 3. Keep the worktree container out of git's tracked state.
        try await ensureCmuxDirectoryLocallyIgnored(repoRoot: root)

        // 4. Pick a unique friendly name.
        let existingBranches = try await existingBranchNames(repoRoot: root)
        let worktreesDir = root
            .appendingPathComponent(".cmux", isDirectory: true)
            .appendingPathComponent("worktrees", isDirectory: true)
        let name = uniqueName(existingBranches: existingBranches, worktreesDir: worktreesDir)

        // 5. Create the worktree off HEAD.
        try FileManager.default.createDirectory(at: worktreesDir, withIntermediateDirectories: true)
        let worktree = worktreesDir.appendingPathComponent(name, isDirectory: true)
        let add = try await runGit(["worktree", "add", "-b", name, worktree.path, "HEAD"], in: root.path)
        guard add.status == 0 else {
            throw WorktreeCreationError.worktreeAddFailed(status: add.status, details: decode(add.output))
        }

        return WorktreeCreationResult(worktreePath: worktree.path, branchName: name)
    }

    // MARK: - Naming

    static func uniqueName(existingBranches: Set<String>, worktreesDir: URL) -> String {
        let fileManager = FileManager.default
        func isFree(_ candidate: String) -> Bool {
            !existingBranches.contains(candidate)
                && !fileManager.fileExists(atPath: worktreesDir.appendingPathComponent(candidate).path)
        }
        for codename in codenames where isFree(codename) {
            return codename
        }
        var index = 1
        while true {
            let candidate = "worktree-\(index)"
            if isFree(candidate) { return candidate }
            index += 1
        }
    }

    // MARK: - Git helpers

    private static func existingBranchNames(repoRoot: URL) async throws -> Set<String> {
        let result = try await runGit(["for-each-ref", "--format=%(refname:short)", "refs/heads"], in: repoRoot.path)
        guard result.status == 0 else { return [] }
        let names = decode(result.output)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return Set(names)
    }

    private static func ensureCmuxDirectoryLocallyIgnored(repoRoot: URL) async throws {
        let result = try await runGit(["rev-parse", "--git-path", "info/exclude"], in: repoRoot.path)
        let rawPath = decode(result.output).trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.status == 0, !rawPath.isEmpty else {
            throw WorktreeCreationError.couldNotResolveExcludeFile
        }

        let excludeURL = rawPath.hasPrefix("/")
            ? URL(fileURLWithPath: rawPath).standardizedFileURL
            : repoRoot.appendingPathComponent(rawPath).standardizedFileURL
        try FileManager.default.createDirectory(
            at: excludeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let existing = (try? String(contentsOf: excludeURL, encoding: .utf8)) ?? ""
        let alreadyIgnored = existing
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .contains { $0 == ".cmux" || $0 == ".cmux/" }
        guard !alreadyIgnored else { return }

        let separator = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
        let next = existing + separator + "# cmux worktrees\n.cmux/\n"
        try next.write(to: excludeURL, atomically: true, encoding: .utf8)
    }

    private static func decode(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? ""
    }

    /// Runs `git -C <directory> <arguments…>` and returns its exit status plus
    /// combined stdout/stderr. Reuses the proven process plumbing from the
    /// extension worktree prototype so output can't deadlock on a full pipe.
    private static func runGit(_ arguments: [String], in directory: String) async throws -> (status: Int32, output: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", directory] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let termination = CmuxExtensionProcessTermination()
        process.terminationHandler = { process in
            termination.complete(process.terminationStatus)
        }
        try process.run()
        let collector = CmuxExtensionPipeOutputCollector(fileHandle: pipe.fileHandleForReading)
        let status = await termination.wait()
        let output = await collector.finish()
        return (status, output)
    }
}
