import Foundation
import Testing
@testable import CmuxGit

@Suite("Git default branch resolver")
struct GitDefaultBranchResolverTests {
    /// Builds a `runGit` stub from a table keyed by the joined argument string.
    /// Unlisted commands return exit status 1 with empty output — the shape git
    /// uses for "ref does not exist".
    private func stub(
        _ table: [String: GitDefaultBranchResolver.CommandResult]
    ) -> (_ arguments: [String]) async -> GitDefaultBranchResolver.CommandResult? {
        { arguments in
            table[arguments.joined(separator: " ")]
                ?? GitDefaultBranchResolver.CommandResult(exitStatus: 1, firstLine: "")
        }
    }

    private func ok(_ firstLine: String = "") -> GitDefaultBranchResolver.CommandResult {
        GitDefaultBranchResolver.CommandResult(exitStatus: 0, firstLine: firstLine)
    }

    @Test("honors the cmux.changes.base override when it resolves to a commit")
    func usesConfiguredBase() async {
        let run = stub([
            "config --get cmux.changes.base": ok("myfork/main"),
            "rev-parse --verify --quiet myfork/main^{commit}": ok("deadbeef"),
        ])
        #expect(await GitDefaultBranchResolver.resolveBaseRef(runGit: run)
            == .resolved(baseRef: "myfork/main"))
    }

    @Test("ignores an unresolvable override and falls through to origin/HEAD")
    func fallsThroughUnresolvableOverride() async {
        let run = stub([
            "config --get cmux.changes.base": ok("bogus/ref"),
            // override verify is unlisted → status 1 → falls through.
            "symbolic-ref --quiet --short refs/remotes/origin/HEAD": ok("origin/main"),
        ])
        #expect(await GitDefaultBranchResolver.resolveBaseRef(runGit: run)
            == .resolved(baseRef: "origin/main"))
    }

    @Test("prefers origin/HEAD when no override is configured")
    func prefersOriginHead() async {
        let run = stub([
            "symbolic-ref --quiet --short refs/remotes/origin/HEAD": ok("origin/trunk"),
        ])
        #expect(await GitDefaultBranchResolver.resolveBaseRef(runGit: run)
            == .resolved(baseRef: "origin/trunk"))
    }

    @Test("falls back to local main, then master")
    func fallsBackToLocalDefaults() async {
        let mainOnly = stub([
            "rev-parse --verify --quiet refs/heads/main^{commit}": ok("deadbeef"),
        ])
        #expect(await GitDefaultBranchResolver.resolveBaseRef(runGit: mainOnly)
            == .resolved(baseRef: "main"))

        let masterOnly = stub([
            "rev-parse --verify --quiet refs/heads/master^{commit}": ok("deadbeef"),
        ])
        #expect(await GitDefaultBranchResolver.resolveBaseRef(runGit: masterOnly)
            == .resolved(baseRef: "master"))
    }

    @Test("resolves to nil when no default branch exists")
    func resolvesNilWhenNoDefault() async {
        #expect(await GitDefaultBranchResolver.resolveBaseRef(runGit: stub([:]))
            == .resolved(baseRef: nil))
    }

    @Test("reports a process failure when a git invocation fails")
    func reportsProcessFailure() async {
        let run: (_ arguments: [String]) async -> GitDefaultBranchResolver.CommandResult? = { _ in nil }
        #expect(await GitDefaultBranchResolver.resolveBaseRef(runGit: run) == .processFailure)
    }

    @Test("reports a process failure at each later step of the chain")
    func reportsProcessFailureAtEachStep() async {
        // Step 1b: configured override present, but its commit-verify fails to launch.
        let atOverrideVerify: (_ a: [String]) async -> GitDefaultBranchResolver.CommandResult? = { args in
            if args == ["config", "--get", "cmux.changes.base"] { return self.ok("myfork/main") }
            if args == ["rev-parse", "--verify", "--quiet", "myfork/main^{commit}"] { return nil }
            return GitDefaultBranchResolver.CommandResult(exitStatus: 1, firstLine: "")
        }
        #expect(await GitDefaultBranchResolver.resolveBaseRef(runGit: atOverrideVerify) == .processFailure)

        // Step 2: no override; origin/HEAD lookup fails to launch.
        let atOriginHead: (_ a: [String]) async -> GitDefaultBranchResolver.CommandResult? = { args in
            args == ["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"]
                ? nil
                : GitDefaultBranchResolver.CommandResult(exitStatus: 1, firstLine: "")
        }
        #expect(await GitDefaultBranchResolver.resolveBaseRef(runGit: atOriginHead) == .processFailure)

        // Step 3: local-branch probe fails to launch.
        let atLocalMain: (_ a: [String]) async -> GitDefaultBranchResolver.CommandResult? = { args in
            args == ["rev-parse", "--verify", "--quiet", "refs/heads/main^{commit}"]
                ? nil
                : GitDefaultBranchResolver.CommandResult(exitStatus: 1, firstLine: "")
        }
        #expect(await GitDefaultBranchResolver.resolveBaseRef(runGit: atLocalMain) == .processFailure)
    }
}
