import AppKit
import Neon
import SwiftTreeSitter

public enum CodeHighlightingError: Error {
    /// The grammar's query resource bundle could not be located at runtime.
    case missingQueryBundle(CodeLanguage)
    /// The grammar's resource bundle did not contain a highlights query.
    case missingHighlightQuery(CodeLanguage)
}

/// Everything U4 needs to attach a Neon `TextViewHighlighter` for one language:
/// the parser language, its highlight query, and a theme-backed attribute provider.
public struct CodeHighlighterConfiguration {
    public let language: Language
    public let highlightQuery: Query
    public let attributeProvider: TokenAttributeProvider
}

/// Builds the per-language pieces needed to highlight a text view. Kept free of any
/// `NSTextView` reference so it is unit-testable without a live view.
public enum CodeHighlighterFactory {
    /// Load the tree-sitter `LanguageConfiguration` (and its bundled highlight queries)
    /// for `language`. Throws if the grammar's resource bundle cannot be found or parsed.
    public static func languageConfiguration(for language: CodeLanguage) throws -> LanguageConfiguration {
        guard let queriesURL = GrammarBundleLocator.queriesDirectoryURL(forBundleNamed: language.queryBundleName) else {
            throw CodeHighlightingError.missingQueryBundle(language)
        }
        return try LanguageConfiguration(
            language.tsLanguage,
            name: language.configurationName,
            queriesURL: queriesURL
        )
    }

    /// Build the configuration needed to attach a highlighter for `language`.
    public static func makeConfiguration(
        for language: CodeLanguage,
        theme: CodeTheme = .dark
    ) throws -> CodeHighlighterConfiguration {
        let languageConfig = try languageConfiguration(for: language)
        guard let highlightQuery = languageConfig.queries[.highlights] else {
            throw CodeHighlightingError.missingHighlightQuery(language)
        }
        return CodeHighlighterConfiguration(
            language: language.tsLanguage,
            highlightQuery: highlightQuery,
            attributeProvider: theme.makeAttributeProvider()
        )
    }
}
