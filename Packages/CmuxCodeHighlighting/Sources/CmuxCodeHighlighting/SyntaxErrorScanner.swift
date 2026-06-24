import Foundation
import SwiftTreeSitter

/// Finds the locations of *syntax* errors in source code using tree-sitter's
/// error-recovery parse tree.
///
/// This reports only grammar-level breakage (`ERROR` and `MISSING` nodes) — a file
/// that is syntactically valid but semantically wrong (undefined variable, type
/// mismatch) parses clean here. Semantic diagnostics require a language server and
/// are out of scope.
public enum SyntaxErrorScanner {
    /// Parse `text` for `language` and return the character ranges of syntax errors.
    /// Empty when the document is syntactically valid (or fails to parse at all).
    public static func errorRanges(in text: String, language: CodeLanguage) -> [NSRange] {
        let parser = Parser()
        do {
            try parser.setLanguage(language.parserLanguage)
        } catch {
            return []
        }
        guard let tree = parser.parse(text),
              let root = tree.rootNode,
              root.hasError else {
            return []
        }

        var ranges: [NSRange] = []
        // Iterative pre-order walk, descending only into subtrees that contain an
        // error so a clean document costs almost nothing.
        var stack: [Node] = [root]
        while let node = stack.popLast() {
            if node.nodeType == "ERROR" || node.isMissing {
                ranges.append(node.range)
                continue  // don't descend into the error node itself
            }
            for index in 0..<node.childCount {
                if let child = node.child(at: index), child.hasError {
                    stack.append(child)
                }
            }
        }
        return ranges
    }
}
