import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Coverage for the production worktree-creation primitive that backs the
/// repo-backed group "+" button. The throwaway sample-files/dev-server behavior
/// lives in the extension prototype, not here.
@Suite("Worktree creation service")
struct WorktreeCreationServiceTests {

    // MARK: - Fixtures

    private func makeTempDirectory() throws -> String {
        let path = NSTemporaryDirectory()
            .appending("WorktreeCreationServiceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
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
                domain: "WorktreeCreationServiceTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) failed: \(text)"]
            )
        }
        return text
    }

    private func makeRepoWithCommit() throws -> String {
        let directory = try makeTempDirectory()
        try git(["init", "-q", "-b", "main"], in: directory)
        try git(["commit", "-q", "--allow-empty", "-m", "init"], in: directory)
        return directory
    }

    // MARK: - Happy path

    @Test("creates a worktree under .cmux/worktrees off the default branch")
    func createsWorktreeUnderContainer() async throws {
        let repo = try makeRepoWithCommit()

        let result = try await WorktreeCreationService.createWorktree(repoRoot: repo)

        // Lands under the conventional container.
        #expect(result.worktreePath.contains("/.cmux/worktrees/\(result.branchName)"))
        #expect(FileManager.default.fileExists(atPath: result.worktreePath))

        // git knows about the worktree.
        let list = try git(["worktree", "list", "--porcelain"], in: repo)
        #expect(list.contains(result.worktreePath))

        // The branch exists and points at the default branch (here `main`).
        let branchSha = try git(["rev-parse", result.branchName], in: repo)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let mainSha = try git(["rev-parse", "main"], in: repo)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(branchSha == mainSha)
    }

    @Test("branches off the default branch, not the current feature branch")
    func basesWorktreeOnDefaultBranchNotCurrentHead() async throws {
        let repo = try makeTempDirectory()
        try git(["init", "-q", "-b", "main"], in: repo)
        try git(["commit", "-q", "--allow-empty", "-m", "base"], in: repo)
        let mainSha = try git(["rev-parse", "HEAD"], in: repo)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Move HEAD onto a feature branch that is ahead of main — mirroring a
        // user who clicks "+" while on a feature branch.
        try git(["checkout", "-q", "-b", "feature"], in: repo)
        try git(["commit", "-q", "--allow-empty", "-m", "feature work"], in: repo)
        let featureSha = try git(["rev-parse", "HEAD"], in: repo)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(mainSha != featureSha)

        let result = try await WorktreeCreationService.createWorktree(repoRoot: repo)

        // The worktree must start from the default branch (a clean slate), not
        // inherit the feature branch's commits.
        let branchSha = try git(["rev-parse", result.branchName], in: repo)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(branchSha == mainSha)
        #expect(branchSha != featureSha)

        // And it carries none of the feature branch's changes (empty diff vs main),
        // so the Changes panel shows nothing for a freshly created worktree.
        let diff = try git(["diff", "--stat", "main", result.branchName], in: repo)
        #expect(diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test(".cmux/ is added to info/exclude exactly once across repeated creates")
    func excludeEntryIsIdempotent() async throws {
        let repo = try makeRepoWithCommit()

        _ = try await WorktreeCreationService.createWorktree(repoRoot: repo)
        _ = try await WorktreeCreationService.createWorktree(repoRoot: repo)

        let excludePath = URL(fileURLWithPath: repo)
            .appendingPathComponent(".git/info/exclude").path
        let exclude = (try? String(contentsOfFile: excludePath, encoding: .utf8)) ?? ""
        let occurrences = exclude
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0 == ".cmux/" }
            .count
        #expect(occurrences == 1)
    }

    @Test("repeated creates in the same repo get distinct branch names")
    func namesAreUnique() async throws {
        let repo = try makeRepoWithCommit()

        let first = try await WorktreeCreationService.createWorktree(repoRoot: repo)
        let second = try await WorktreeCreationService.createWorktree(repoRoot: repo)

        #expect(first.branchName != second.branchName)
        #expect(FileManager.default.fileExists(atPath: first.worktreePath))
        #expect(FileManager.default.fileExists(atPath: second.worktreePath))
    }

    // MARK: - Error paths

    @Test("throws when the path is not a git repository")
    func throwsForNonRepository() async throws {
        let directory = try makeTempDirectory()

        await #expect(throws: WorktreeCreationError.self) {
            _ = try await WorktreeCreationService.createWorktree(repoRoot: directory)
        }
        // No partial worktree container should be left behind.
        let worktrees = URL(fileURLWithPath: directory)
            .appendingPathComponent(".cmux/worktrees").path
        #expect(FileManager.default.fileExists(atPath: worktrees) == false)
    }

    @Test("throws when HEAD is unborn (no commits)")
    func throwsForUnbornHead() async throws {
        let directory = try makeTempDirectory()
        try git(["init", "-q", "-b", "main"], in: directory)
        // No commit: HEAD is unborn.

        await #expect(throws: WorktreeCreationError.self) {
            _ = try await WorktreeCreationService.createWorktree(repoRoot: directory)
        }
    }

    // MARK: - Naming unit

    @Test("uniqueName skips taken branches and falls back past the codename list")
    func uniqueNameFallsBack() throws {
        let worktreesDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nonexistent-\(UUID().uuidString)")
        let allTaken = Set(WorktreeCreationService.codenames)

        let name = WorktreeCreationService.uniqueName(
            existingBranches: allTaken,
            worktreesDir: worktreesDir
        )
        #expect(allTaken.contains(name) == false)
        #expect(name.hasPrefix("worktree-"))
    }
}
