import CmuxGit
import Foundation

/// Removes a git worktree (and its branch) that cmux created. Pure git logic
/// with no UI so it can be unit-tested; the confirmation prompt for a dirty
/// worktree lives in the caller (`TabManager`).
enum WorktreeRemovalService {
    enum Outcome: Equatable {
        /// The worktree directory was removed (branch deletion is best-effort).
        case removed
        /// The worktree has uncommitted or untracked changes; the caller may
        /// re-run with `force: true` after confirming with the user.
        case dirty
        /// Removal failed for another reason; carries git's message.
        case failed(String)
    }

    static func removeWorktree(worktreePath: String, branch: String, force: Bool) async -> Outcome {
        guard let repoRoot = mainRepositoryRoot(forWorktreeAt: worktreePath) else {
            return .failed("Could not resolve the repository for this worktree.")
        }

        var arguments = ["worktree", "remove"]
        if force { arguments.append("--force") }
        arguments.append(worktreePath)
        let remove = await runGit(arguments, in: repoRoot)
        if remove.status != 0 {
            if !force, indicatesDirtyWorktree(remove.output) {
                return .dirty
            }
            return .failed(remove.output)
        }

        // The worktree is gone — best-effort delete its branch. A failure here
        // (e.g. the branch was already deleted) does not undo the removal, so
        // the worktree is still considered removed.
        _ = await runGit(["branch", "-D", branch], in: repoRoot)
        return .removed
    }

    /// The main working tree's root for a linked worktree. `commonDirectory`
    /// points at the main repository's `.git`; its parent is the root. Derived
    /// from git's own resolution rather than path arithmetic on the worktree.
    private static func mainRepositoryRoot(forWorktreeAt worktreePath: String) -> String? {
        guard let repository = GitMetadataService.resolveGitRepository(containing: worktreePath) else {
            return nil
        }
        return URL(fileURLWithPath: repository.commonDirectory).deletingLastPathComponent().path
    }

    private static func indicatesDirtyWorktree(_ output: String) -> Bool {
        let lowered = output.lowercased()
        return lowered.contains("contains modified or untracked files")
            || lowered.contains("use --force")
            || lowered.contains("is dirty")
    }

    private static func runGit(_ arguments: [String], in directory: String) async -> (status: Int32, output: String) {
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
        do {
            try process.run()
        } catch {
            return (status: -1, output: error.localizedDescription)
        }
        let collector = CmuxExtensionPipeOutputCollector(fileHandle: pipe.fileHandleForReading)
        let status = await termination.wait()
        let output = await collector.finish()
        return (status, String(data: output, encoding: .utf8) ?? "")
    }
}
