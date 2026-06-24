import Foundation
import Testing
@testable import CmuxCodeHighlighting

@Suite("SymbolOutline")
struct SymbolOutlineTests {
    init() {
        if let buildDir = CodeHighlighterFactoryTests.buildProductsDirectory {
            GrammarBundleLocator.additionalSearchDirectories = [buildDir]
        }
    }

    @Test("Extracts Python functions and classes with names and lines")
    func pythonSymbols() {
        let source = """
        def first():
            return 1

        class Widget:
            def method(self):
                return 2

        def second():
            return 3
        """
        let symbols = SymbolOutline().symbols(in: source, language: .python)
        let names = symbols.map(\.name)
        #expect(names.contains("first"))
        #expect(names.contains("Widget"))
        #expect(names.contains("second"))
        // The class definition appears before the trailing function.
        let widgetLine = symbols.first { $0.name == "Widget" }?.line ?? 0
        let secondLine = symbols.first { $0.name == "second" }?.line ?? 0
        #expect(widgetLine > 0)
        #expect(secondLine > widgetLine)
    }

    @Test("Extracts TypeScript function/class definitions")
    func typescriptSymbols() {
        let source = """
        export function load(): void {}
        class Store {}
        """
        let names = SymbolOutline().symbols(in: source, language: .typescript).map(\.name)
        #expect(names.contains("load"))
        #expect(names.contains("Store"))
    }

    @Test("Returns no symbols for formats without a tags grammar")
    func noSymbolsForJSON() {
        #expect(SymbolOutline().symbols(in: "{\"a\": 1}", language: .json).isEmpty)
    }
}
