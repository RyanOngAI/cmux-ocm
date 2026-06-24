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

    /// Validates the runtime query-bundle loading flagged as a risk in the plan:
    /// every grammar's `highlights.scm` must resolve and parse — including TSX, whose
    /// queries are a known sharp edge (inheritance from the JS/TS base grammars).
    @Test("Highlight queries load for every language", arguments: CodeLanguage.allCases)
    func loadsHighlightQuery(_ language: CodeLanguage) throws {
        let config = try CodeHighlighterFactory.languageConfiguration(for: language)
        let highlights = try #require(config.queries[.highlights])
        #expect(highlights.patternCount > 0)
    }

    @Test("makeConfiguration yields a usable language + query + provider")
    func makeConfigurationSucceeds() throws {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let config = try CodeHighlighterFactory.makeConfiguration(for: .python, font: font)
        #expect(config.highlightQuery.patternCount > 0)
        let attrs = config.attributeProvider(.init(name: "keyword", range: NSRange(location: 0, length: 1)))
        #expect(attrs[.foregroundColor] != nil)
    }
}
