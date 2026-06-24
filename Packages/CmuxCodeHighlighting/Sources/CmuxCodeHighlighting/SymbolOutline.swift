import Foundation
import SwiftTreeSitter

/// A definition (function, class, method, …) found in a source file, for the outline.
public struct CodeSymbol: Identifiable, Hashable, Sendable {
    public var id: Int { nameRange.location }
    /// The symbol's name (e.g. the function or class identifier).
    public let name: String
    /// The tags-query definition kind without the `definition.` prefix
    /// (e.g. `function`, `class`, `method`, `constant`, `interface`, `module`).
    public let kind: String
    /// Character range of the name node — the jump target.
    public let nameRange: NSRange
    /// 1-based line number of the definition.
    public let line: Int
}

/// Extracts the symbol outline from a source file using each grammar's `tags.scm`
/// query (the same data that powers ctags-style navigation). Languages without a
/// `tags.scm` (most config/data formats) yield no symbols.
public enum SymbolOutline {
    public static func symbols(in text: String, language: CodeLanguage) -> [CodeSymbol] {
        // Concatenate each bundle's tags.scm (base grammar first), mirroring how
        // highlight queries are combined: TS/TSX ship only their delta and rely on the
        // JavaScript base for function/class definitions.
        var combined = ""
        for bundleName in language.highlightBundleNames {
            guard let queriesURL = GrammarBundleLocator.queriesDirectoryURL(forBundleNamed: bundleName) else { continue }
            if let scm = try? String(contentsOf: queriesURL.appendingPathComponent("tags.scm"), encoding: .utf8) {
                combined += scm + "\n"
            }
        }
        guard !combined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let query = try? Query(language: language.parserLanguage, data: Data(combined.utf8)) else {
            return []
        }
        let parser = Parser()
        guard (try? parser.setLanguage(language.parserLanguage)) != nil,
              let tree = parser.parse(text),
              let root = tree.rootNode else {
            return []
        }

        let source = text as NSString
        let lineStarts = Self.lineStartIndices(source)
        var symbols: [CodeSymbol] = []
        var seenLocations = Set<Int>()

        for match in query.execute(node: root, in: tree) {
            var nameRange: NSRange?
            var kind: String?
            for capture in match.captures {
                guard let captureName = capture.name else { continue }
                if captureName == "name" {
                    nameRange = capture.node.range
                } else if captureName.hasPrefix("definition.") {
                    kind = String(captureName.dropFirst("definition.".count))
                }
            }
            guard let nameRange, let kind,
                  nameRange.location != NSNotFound,
                  NSMaxRange(nameRange) <= source.length,
                  seenLocations.insert(nameRange.location).inserted else { continue }
            let name = source.substring(with: nameRange)
            guard !name.isEmpty else { continue }
            symbols.append(CodeSymbol(
                name: name,
                kind: kind,
                nameRange: nameRange,
                line: Self.line(for: nameRange.location, in: lineStarts)
            ))
        }
        return symbols.sorted { $0.nameRange.location < $1.nameRange.location }
    }

    private static func lineStartIndices(_ text: NSString) -> [Int] {
        var starts: [Int] = [0]
        var index = 0
        while index < text.length {
            let found = text.range(of: "\n", options: [], range: NSRange(location: index, length: text.length - index))
            if found.location == NSNotFound { break }
            starts.append(found.location + 1)
            index = found.location + 1
        }
        return starts
    }

    private static func line(for characterIndex: Int, in lineStarts: [Int]) -> Int {
        var low = 0
        var high = lineStarts.count - 1
        var answer = 0
        while low <= high {
            let mid = (low + high) / 2
            if lineStarts[mid] <= characterIndex {
                answer = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return answer + 1
    }
}
