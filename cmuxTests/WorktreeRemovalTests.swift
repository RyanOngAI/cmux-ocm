import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Coverage for the worktree removal git logic. The NSAlert confirmation for a
/// dirty worktree lives in TabManager and is exercised at runtime, not here.
@Suite("Worktree removal service")
struct WorktreeRemovalTests {

    // MARK: - Fixtures

    private func makeTempDirectory() throws -> String {
        let path = NSTemporaryDirectory()
            .appending("WorktreeRemovalTests-\(UUID().uuidString)")
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
                domain: "WorktreeRemovalTests",
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

    // MARK: - Removal

    @Test func removesCleanWorktreeAndBranch() async throws {
        let repo = try makeRepoWithCommit()
        let creation = try await WorktreeCreationService.createWorktree(repoRoot: repo)

        let outcome = await WorktreeRemovalService.removeWorktree(
            worktreePath: creation.worktreePath, branch: creation.branchName, force: false
        )

        #expect(outcome == .removed)
        #expect(FileManager.default.fileExists(atPath: creation.worktreePath) == false)
        let branches = try git(["branch", "--list", creation.branchName], in: repo)
        #expect(branches.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test func reportsDirtyWithoutForceThenRemovesWithForce() async throws {
        let repo = try makeRepoWithCommit()
        let creation = try await WorktreeCreationService.createWorktree(repoRoot: repo)
        // Make the worktree dirty with an untracked file.
        let stray = URL(fileURLWithPath: creation.worktreePath).appendingPathComponent("stray.txt")
        try "wip\n".write(to: stray, atomically: true, encoding: .utf8)

        let dirty = await WorktreeRemovalService.removeWorktree(
            worktreePath: creation.worktreePath, branch: creation.branchName, force: false
        )
        #expect(dirty == .dirty)
        #expect(FileManager.default.fileExists(atPath: creation.worktreePath))

        let forced = await WorktreeRemovalService.removeWorktree(
            worktreePath: creation.worktreePath, branch: creation.branchName, force: true
        )
        #expect(forced == .removed)
        #expect(FileManager.default.fileExists(atPath: creation.worktreePath) == false)
    }

    @Test func reportsFailedWhenRepositoryCannotBeResolved() async throws {
        // A plain temp directory that is not inside any git repository.
        let nonRepo = try makeTempDirectory()

        let outcome = await WorktreeRemovalService.removeWorktree(
            worktreePath: nonRepo, branch: "x", force: false
        )

        guard case .failed = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
    }
}
