import Foundation
import Testing
@testable import CmuxCodeHighlighting

@Suite("SyntaxErrorScanner")
struct SyntaxErrorScannerTests {
    @Test("Valid code reports no syntax errors")
    func validCodeHasNoErrors() {
        #expect(SyntaxErrorScanner.errorRanges(in: "def f():\n    return 1\n", language: .python).isEmpty)
        #expect(SyntaxErrorScanner.errorRanges(in: "const x: number = 1\n", language: .typescript).isEmpty)
    }

    @Test("Malformed Python reports at least one error range")
    func malformedPythonHasError() {
        let ranges = SyntaxErrorScanner.errorRanges(in: "def f(:\n    return\n", language: .python)
        #expect(!ranges.isEmpty)
    }

    @Test("Malformed TSX (unclosed tag) reports at least one error range")
    func malformedTSXHasError() {
        let ranges = SyntaxErrorScanner.errorRanges(in: "const a = <div>hi\n", language: .tsx)
        #expect(!ranges.isEmpty)
    }
}
