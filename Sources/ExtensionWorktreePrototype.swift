import CmuxFoundation
import Foundation

struct CmuxExtensionWorktreeCreationResult: Sendable {
    let worktreePath: String
    let workspaceTitle: String
    /// A convenience command (e.g. a sample dev-server launcher) that should run
    /// inside the new workspace's interactive shell. This is *setup*, never the
    /// workspace's primary process.
    let setupCommand: String
}

/// Arguments for spawning a workspace in a freshly created worktree.
///
/// A workspace closes the moment its main process exits, so the worktree
/// `setupCommand` must be delivered as terminal *input* typed into the
/// interactive login shell — never as the surface's primary process. This type
/// deliberately has **no** primary-command field: the workspace's main process
/// is structurally always the login shell, so the "setup command became the
/// main process and the tab died when it exited" bug cannot be expressed here.
struct CmuxExtensionWorktreeWorkspaceSpawnArgs: Sendable, Equatable {
    let title: String
    let workingDirectory: String
    /// Setup command typed into the interactive shell after spawn (with a
    /// trailing newline so it executes), or `nil` when there is no setup.
    let initialTerminalInput: String?
    let inheritWorkingDirectory: Bool
}

extension CmuxExtensionWorktreeCreationResult {
    /// Builds the workspace spawn arguments for this worktree.
    ///
    /// The returned arguments always leave the workspace's main process as the
    /// login shell and deliver ``setupCommand`` as terminal input.
    func workspaceSpawnArgs() -> CmuxExtensionWorktreeWorkspaceSpawnArgs {
        // Worktree creation already ran as a pre-spawn step, so the setup
        // command is delivered as interactive shell input (with a trailing
        // newline so it executes) rather than as the surface's primary process.
        CmuxExtensionWorktreeWorkspaceSpawnArgs(
            title: workspaceTitle,
            workingDirectory: worktreePath,
            initialTerminalInput: setupCommand.isEmpty ? nil : setupCommand + "\n",
            inheritWorkingDirectory: false
        )
    }
}

final class CmuxExtensionProcessTermination: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32?
    private var continuation: CheckedContinuation<Int32, Never>?

    func complete(_ status: Int32) {
        let continuation: CheckedContinuation<Int32, Never>?
        lock.lock()
        if let pendingContinuation = self.continuation {
            self.continuation = nil
            continuation = pendingContinuation
        } else {
            self.status = status
            continuation = nil
        }
        lock.unlock()
        continuation?.resume(returning: status)
    }

    func wait() async -> Int32 {
        await withCheckedContinuation { continuation in
            let completedStatus: Int32?
            lock.lock()
            if let status {
                completedStatus = status
            } else {
                self.continuation = continuation
                completedStatus = nil
            }
            lock.unlock()

            if let completedStatus {
                continuation.resume(returning: completedStatus)
            }
        }
    }
}

/// Demo-grade worktree entrypoint used by the extension-sidebar prototype.
///
/// The real git work — repo validation, `.cmux/` ignore, branch naming, and
/// `git worktree add` — lives in ``WorktreeCreationService`` so there is exactly
/// one worktree-creation path in cmux. This prototype only layers a throwaway
/// sample dev server on top to demonstrate the setup-command flow.
enum CmuxExtensionWorktreePrototype {
    static func createWorktree(projectRootPath: String) async throws -> CmuxExtensionWorktreeCreationResult {
        let creation = try await WorktreeCreationService.createWorktree(repoRoot: projectRootPath)
        let worktree = URL(fileURLWithPath: creation.worktreePath, isDirectory: true)
        let projectName = URL(fileURLWithPath: projectRootPath, isDirectory: true)
            .standardizedFileURL.lastPathComponent
        try writeSampleDevServerFiles(in: worktree, projectName: projectName)

        let port = 4_100 + abs(creation.branchName.hashValue % 800)
        let samplePath = shellEscaped(worktree.appendingPathComponent("cmux-sample-dev", isDirectory: true).path)
        return CmuxExtensionWorktreeCreationResult(
            worktreePath: creation.worktreePath,
            workspaceTitle: creation.branchName,
            setupCommand: "cd \(samplePath) && python3 -m http.server \(port)"
        )
    }

    private static func writeSampleDevServerFiles(in worktree: URL, projectName: String) throws {
        let sample = worktree.appendingPathComponent("cmux-sample-dev", isDirectory: true)
        try FileManager.default.createDirectory(at: sample, withIntermediateDirectories: true)
        let escapedProject = projectName
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let html = """
        <!doctype html>
        <html>
          <head><meta charset="utf-8"><title>cmux worktree</title></head>
          <body style="font: 15px -apple-system; padding: 32px;">
            <h1>\(escapedProject) worktree</h1>
            <p>This page is served from a git worktree created by CmuxExtensionKit.</p>
          </body>
        </html>
        """
        try html.write(to: sample.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
    }

    private static func shellEscaped(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

final class CmuxExtensionPipeOutputCollector: @unchecked Sendable {
    private struct ReadHandle: @unchecked Sendable {
        let fileHandle: FileHandle
    }

    private let readTask: Task<Data, Never>

    init(fileHandle: FileHandle) {
        let readHandle = ReadHandle(fileHandle: fileHandle)
        readTask = Task.detached(priority: .utility) {
            let data = readHandle.fileHandle.readDataToEndOfFileOrEmpty()
            try? readHandle.fileHandle.close()
            return data
        }
    }

    func finish() async -> Data {
        await readTask.value
    }
}
