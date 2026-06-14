import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavior-level coverage for the repo-backed group "+" routing: repo-backed
/// groups create a real worktree workspace; non-repo groups fall back to the
/// prior plain-workspace behavior.
@MainActor
@Suite("Workspace group worktree creation")
struct WorkspaceGroupWorktreeCreationTests {

    // MARK: - Fixtures

    private func makeTempDirectory() throws -> String {
        let path = NSTemporaryDirectory()
            .appending("WorkspaceGroupWorktreeCreationTests-\(UUID().uuidString)")
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
        _ = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "WorkspaceGroupWorktreeCreationTests", code: Int(process.terminationStatus))
        }
        return ""
    }

    private func makeRepoWithCommit() throws -> String {
        let directory = try makeTempDirectory()
        try git(["init", "-q", "-b", "main"], in: directory)
        try git(["commit", "-q", "--allow-empty", "-m", "init"], in: directory)
        return directory
    }

    /// Builds a group and points its (freshly created) anchor workspace at
    /// `anchorDirectory`, which is where worktree resolution reads from.
    private func makeGroup(in manager: TabManager, anchorDirectory: String) throws -> UUID {
        let child = manager.addWorkspace(autoWelcomeIfNeeded: false)
        let gid = try #require(manager.createWorkspaceGroup(name: "Repo", childWorkspaceIds: [child.id]))
        let group = try #require(manager.workspaceGroups.first { $0.id == gid })
        let anchor = try #require(manager.tabs.first { $0.id == group.anchorWorkspaceId })
        anchor.currentDirectory = anchorDirectory
        return gid
    }

    // MARK: - Routing

    @Test func repoBackedGroupPlusCreatesWorktreeWorkspace() async throws {
        let repo = try makeRepoWithCommit()
        let manager = TabManager()
        let gid = try makeGroup(in: manager, anchorDirectory: repo)
        let before = manager.tabs.count

        let workspace = try #require(await manager.createWorktreeWorkspaceInGroup(groupId: gid))

        #expect(workspace.groupId == gid)
        #expect(workspace.worktreeBranch != nil)
        #expect(workspace.currentDirectory.contains("/.cmux/worktrees/"))
        #expect(manager.tabs.count == before + 1)
    }

    @Test func nonRepoGroupPlusFallsBackToPlainWorkspace() async throws {
        let nonRepo = try makeTempDirectory()
        let manager = TabManager()
        let gid = try makeGroup(in: manager, anchorDirectory: nonRepo)

        let workspace = try #require(await manager.createWorktreeWorkspaceInGroup(groupId: gid))

        #expect(workspace.groupId == gid)
        #expect(workspace.worktreeBranch == nil)
    }

    @Test func sequentialCreatesYieldDistinctWorktrees() async throws {
        let repo = try makeRepoWithCommit()
        let manager = TabManager()
        let child = manager.addWorkspace(autoWelcomeIfNeeded: false)
        let gid = try #require(manager.createWorkspaceGroup(name: "Repo", childWorkspaceIds: [child.id]))
        let group = try #require(manager.workspaceGroups.first { $0.id == gid })
        let anchor = try #require(manager.tabs.first { $0.id == group.anchorWorkspaceId })

        // The repo cwd is read synchronously before any await, so set it right
        // before each "+". (A freshly built test workspace's currentDirectory
        // can resync from its terminal across an await; a real repo-backed
        // anchor genuinely sits in the repo, so this mirrors production.)
        anchor.currentDirectory = repo
        let first = try #require(await manager.createWorktreeWorkspaceInGroup(groupId: gid))
        anchor.currentDirectory = repo
        let second = try #require(await manager.createWorktreeWorkspaceInGroup(groupId: gid))

        #expect(first.worktreeBranch != nil)
        #expect(second.worktreeBranch != nil)
        #expect(first.worktreeBranch != second.worktreeBranch)
    }
}
