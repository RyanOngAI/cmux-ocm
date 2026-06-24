import Foundation
import SwiftTreeSitter
import TreeSitterJavaScript
import TreeSitterPython
import TreeSitterTSX
import TreeSitterTypeScript

/// A source language cmux can syntax-highlight in the file preview.
///
/// Detection is data-driven so additional grammars can be added without touching
/// the rest of the pipeline. Unsupported file types resolve to `nil`, and the caller
/// falls back to plain-text rendering.
public enum CodeLanguage: String, CaseIterable, Sendable {
    case python
    case typescript
    case tsx
    case javascript
    case jsx

    /// Detect a supported language from a file path. Returns `nil` for unsupported types.
    public static func detect(path: String) -> CodeLanguage? {
        detect(fileExtension: (path as NSString).pathExtension)
    }

    /// Detect a supported language from a (case-insensitive) file extension.
    public static func detect(fileExtension rawExtension: String) -> CodeLanguage? {
        switch rawExtension.lowercased() {
        case "py", "pyi": return .python
        case "ts", "mts", "cts": return .typescript
        case "tsx": return .tsx
        case "js", "mjs", "cjs": return .javascript
        case "jsx": return .jsx
        default: return nil
        }
    }

    /// The tree-sitter parser for this language. JSX is parsed by the JavaScript
    /// grammar; TSX by the dedicated TSX grammar.
    public var tsLanguage: Language {
        switch self {
        case .python: return Language(language: tree_sitter_python())
        case .typescript: return Language(language: tree_sitter_typescript())
        case .tsx: return Language(language: tree_sitter_tsx())
        case .javascript, .jsx: return Language(language: tree_sitter_javascript())
        }
    }

    /// SwiftTreeSitter resource-bundle name carrying this grammar's highlight queries.
    /// These follow SwiftPM's `<Package>_<Target>` convention and are verified against
    /// the built `.bundle` products.
    var queryBundleName: String {
        switch self {
        case .python: return "TreeSitterPython_TreeSitterPython"
        case .typescript: return "TreeSitterTypeScript_TreeSitterTypeScript"
        case .tsx: return "TreeSitterTypeScript_TreeSitterTSX"
        case .javascript, .jsx: return "TreeSitterJavaScript_TreeSitterJavaScript"
        }
    }

    /// Human-readable name passed to `LanguageConfiguration`.
    var configurationName: String {
        switch self {
        case .python: return "Python"
        case .typescript: return "TypeScript"
        case .tsx: return "TSX"
        case .javascript: return "JavaScript"
        case .jsx: return "JSX"
        }
    }
}
