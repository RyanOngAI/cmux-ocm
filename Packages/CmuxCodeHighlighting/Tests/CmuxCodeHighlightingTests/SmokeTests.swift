import Testing
@testable import CmuxCodeHighlighting

@Suite("CmuxCodeHighlighting U1 smoke")
struct SmokeTests {
    @Test(
        "Every grammar compiles, links, and parses on this toolchain",
        arguments: CmuxCodeHighlightingSmoke.Grammar.allCases
    )
    func grammarParses(_ grammar: CmuxCodeHighlightingSmoke.Grammar) throws {
        let childCount = try CmuxCodeHighlightingSmoke.smokeParse(grammar)
        #expect(childCount > 0)
    }
}
