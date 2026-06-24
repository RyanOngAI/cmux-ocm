import AppKit
import Foundation
import Neon
import SwiftTreeSitter

public enum CodeHighlightingError: Error {
    /// A grammar's query resource bundle could not be located at runtime.
    case missingQueryBundle(CodeLanguage)
    /// None of the language's bundles yielded a usable highlights query.
    case emptyHighlightQuery(CodeLanguage)
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
    /// Build the combined highlight query for `language` by concatenating the
    /// `highlights.scm` of each of its grammar bundles (base grammar first), then
    /// appending the shared JSX rules where applicable. Compiled against the
    /// language's parser.
    public static func highlightQuery(for language: CodeLanguage) throws -> Query {
        var combined = ""
        for bundleName in language.highlightBundleNames {
            guard let queriesURL = GrammarBundleLocator.queriesDirectoryURL(forBundleNamed: bundleName) else {
                throw CodeHighlightingError.missingQueryBundle(language)
            }
            let scmURL = queriesURL.appendingPathComponent("highlights.scm")
            if let scm = try? String(contentsOf: scmURL, encoding: .utf8) {
                combined += scm + "\n"
            }
        }
        if language.includesJSXRules {
            combined += "\n" + CodeLanguage.jsxHighlightRules + "\n"
        }
        guard !combined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CodeHighlightingError.emptyHighlightQuery(language)
        }
        return try Query(language: language.parserLanguage, data: Data(combined.utf8))
    }

    /// Build the configuration needed to attach a highlighter for `language`.
    public static func makeConfiguration(
        for language: CodeLanguage,
        theme: CodeTheme = .dark
    ) throws -> CodeHighlighterConfiguration {
        CodeHighlighterConfiguration(
            language: language.parserLanguage,
            highlightQuery: try highlightQuery(for: language),
            attributeProvider: theme.makeAttributeProvider()
        )
    }
}
