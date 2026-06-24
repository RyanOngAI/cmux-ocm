import Foundation
import SwiftTreeSitter
import TreeSitterBash
import TreeSitterC
import TreeSitterCPP
import TreeSitterCSS
import TreeSitterGo
import TreeSitterHTML
import TreeSitterJSON
import TreeSitterJava
import TreeSitterJavaScript
import TreeSitterPython
import TreeSitterRuby
import TreeSitterRust
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
    case json
    case bash
    case html
    case css
    case go
    case rust
    case c
    case cpp
    case ruby
    case java

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
        case "json", "jsonc": return .json
        case "sh", "bash", "zsh": return .bash
        case "html", "htm": return .html
        case "css": return .css
        case "go": return .go
        case "rs": return .rust
        case "c", "h": return .c
        case "cpp", "cc", "cxx", "hpp", "hh", "hxx": return .cpp
        case "rb": return .ruby
        case "java": return .java
        default: return nil
        }
    }

    /// The tree-sitter parser for this language.
    ///
    /// `.ts` uses the TypeScript parser (which handles `<T>` type assertions) while
    /// `.tsx` uses the dedicated TSX parser (which handles JSX); they are deliberately
    /// different grammars. JSX is parsed by the JavaScript grammar.
    public var parserLanguage: Language {
        switch self {
        case .python: return Language(language: tree_sitter_python())
        case .typescript: return Language(language: tree_sitter_typescript())
        case .tsx: return Language(language: tree_sitter_tsx())
        case .javascript, .jsx: return Language(language: tree_sitter_javascript())
        case .json: return Language(language: tree_sitter_json())
        case .bash: return Language(language: tree_sitter_bash())
        case .html: return Language(language: tree_sitter_html())
        case .css: return Language(language: tree_sitter_css())
        case .go: return Language(language: tree_sitter_go())
        case .rust: return Language(language: tree_sitter_rust())
        case .c: return Language(language: tree_sitter_c())
        case .cpp: return Language(language: tree_sitter_cpp())
        case .ruby: return Language(language: tree_sitter_ruby())
        case .java: return Language(language: tree_sitter_java())
        }
    }

    /// SwiftTreeSitter resource-bundle names whose `highlights.scm` files are
    /// concatenated, in order, to form this language's highlight query.
    ///
    /// TypeScript/TSX ship only their language-specific deltas (types, TS keywords),
    /// so they prepend the JavaScript/ECMAScript base — the way tree-sitter grammars
    /// are designed to be combined. Bundle names follow SwiftPM's `<Package>_<Target>`
    /// convention and are verified against the built `.bundle` products.
    var highlightBundleNames: [String] {
        switch self {
        case .python: return ["TreeSitterPython_TreeSitterPython"]
        case .javascript, .jsx: return ["TreeSitterJavaScript_TreeSitterJavaScript"]
        case .typescript:
            return ["TreeSitterJavaScript_TreeSitterJavaScript", "TreeSitterTypeScript_TreeSitterTypeScript"]
        case .tsx:
            return ["TreeSitterJavaScript_TreeSitterJavaScript", "TreeSitterTypeScript_TreeSitterTSX"]
        case .json: return ["TreeSitterJSON_TreeSitterJSON"]
        case .bash: return ["TreeSitterBash_TreeSitterBash"]
        case .html: return ["TreeSitterHTML_TreeSitterHTML"]
        case .css: return ["TreeSitterCSS_TreeSitterCSS"]
        case .go: return ["TreeSitterGo_TreeSitterGo"]
        case .rust: return ["TreeSitterRust_TreeSitterRust"]
        case .c: return ["TreeSitterC_TreeSitterC"]
        case .cpp: return ["TreeSitterCPP_TreeSitterCPP"]
        case .ruby: return ["TreeSitterRuby_TreeSitterRuby"]
        case .java: return ["TreeSitterJava_TreeSitterJava"]
        }
    }

    /// Whether to append the shared JSX highlight rules. The grammar query files
    /// don't color JSX tags/attributes, so we add them for the JSX-capable parsers.
    var includesJSXRules: Bool {
        switch self {
        case .javascript, .jsx, .tsx: return true
        default: return false
        }
    }

    /// Highlight rules for JSX elements and attributes, which the JavaScript/TSX
    /// grammar query files omit. Compiled only against JSX-capable parsers.
    static let jsxHighlightRules = """
    ; JSX (added by cmux — the shipped grammar queries omit these)
    (jsx_opening_element name: (identifier) @tag)
    (jsx_closing_element name: (identifier) @tag)
    (jsx_self_closing_element name: (identifier) @tag)
    ((jsx_opening_element name: (identifier) @type) (#match? @type "^[A-Z]"))
    ((jsx_self_closing_element name: (identifier) @type) (#match? @type "^[A-Z]"))
    (jsx_attribute (property_identifier) @attribute)
    """
}
