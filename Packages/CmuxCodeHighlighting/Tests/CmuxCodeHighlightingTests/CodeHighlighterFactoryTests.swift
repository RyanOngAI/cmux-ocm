import AppKit
import Foundation
import SwiftTreeSitter
import Testing
@testable import CmuxCodeHighlighting

@Suite("CodeHighlighterFactory")
struct CodeHighlighterFactoryTests {
    init() {
        // Under `swift test`, Bundle.main is Xcode's testing helper and cannot reach
        // the SwiftPM build-products directory where the grammar bundles live. Point
        // the locator at it explicitly so the factory's real path is exercised. In the
        // app, Bundle.main.resourceURL resolves the bundles without this.
        if let buildDir = Self.buildProductsDirectory {
            GrammarBundleLocator.additionalSearchDirectories = [buildDir]
        }
    }

    /// The directory containing the built grammar resource bundles, discovered from
    /// this test file's location (package root → `.build` → arch/config dir).
    static let buildProductsDirectory: URL? = {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // CmuxCodeHighlightingTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // package root
        let buildRoot = packageRoot.appendingPathComponent(".build")
        guard let enumerator = FileManager.default.enumerator(
            at: buildRoot,
            includingPropertiesForKeys: nil
        ) else { return nil }
        for case let url as URL in enumerator
        where url.lastPathComponent == "TreeSitterPython_TreeSitterPython.bundle" {
            return url.deletingLastPathComponent()
        }
        return nil
    }()

    /// Every language's combined highlight query must load from its bundles and
    /// compile against its parser — including the TS/TSX concatenation and the
    /// appended JSX rules (the sharp edges flagged in the plan).
    @Test("Highlight query compiles for every language", arguments: CodeLanguage.allCases)
    func highlightQueryCompiles(_ language: CodeLanguage) throws {
        let query = try CodeHighlighterFactory().highlightQuery(for: language)
        #expect(query.patternCount > 0)
    }

    @Test("TSX query includes JSX tag/attribute rules")
    func tsxIncludesJSXCaptures() throws {
        let query = try CodeHighlighterFactory().highlightQuery(for: .tsx)
        let captureNames = Set((0..<query.captureCount).compactMap { query.captureName(for: $0) })
        #expect(captureNames.contains("tag"))
        #expect(captureNames.contains("attribute"))
    }

    @Test("makeConfiguration yields a usable language + query + provider")
    func makeConfigurationSucceeds() throws {
        let config = try CodeHighlighterFactory().makeConfiguration(for: .python)
        #expect(config.highlightQuery.patternCount > 0)
        let attrs = config.attributeProvider(.init(name: "keyword", range: NSRange(location: 0, length: 1)))
        #expect(attrs[.foregroundColor] != nil)
    }
}
