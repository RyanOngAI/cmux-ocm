import Foundation
import SwiftTreeSitter
import TreeSitterPython
import TreeSitterTypeScript
import TreeSitterTSX
import TreeSitterJavaScript
// Importing Neon here forces it to compile against the resolved SwiftTreeSitter
// version, so the U1 smoke build also validates Neon<->SwiftTreeSitter compatibility.
import Neon

/// U1 validation surface: proves every tree-sitter grammar's C symbols link and the
/// SwiftTreeSitter / Neon stack compiles on this toolchain. Replaced by the real
/// language/theme API in U2.
public enum CmuxCodeHighlightingSmoke {
    /// The grammars wired into the package, each paired with a snippet to parse.
    public enum Grammar: CaseIterable, Sendable {
        case python, typescript, tsx, javascript

        var tsLanguage: Language {
            switch self {
            case .python: return Language(language: tree_sitter_python())
            case .typescript: return Language(language: tree_sitter_typescript())
            case .tsx: return Language(language: tree_sitter_tsx())
            case .javascript: return Language(language: tree_sitter_javascript())
            }
        }

        var sampleSource: String {
            switch self {
            case .python: return "def f():\n    return 1\n"
            case .typescript: return "const x: number = 1\nfunction f(): void {}\n"
            case .tsx: return "const App = () => <div className=\"a\">hi</div>\n"
            case .javascript: return "const x = 1\nfunction f() { return x }\n"
            }
        }
    }

    /// Parses `grammar`'s sample snippet and returns the number of top-level children
    /// of the parse-tree root. A value > 0 means the grammar compiled, linked, and
    /// parsed successfully.
    public static func smokeParse(_ grammar: Grammar) throws -> Int {
        let parser = Parser()
        try parser.setLanguage(grammar.tsLanguage)
        guard let tree = parser.parse(grammar.sampleSource),
              let root = tree.rootNode else {
            return 0
        }
        return root.childCount
    }
}
