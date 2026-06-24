import AppKit
import Neon

/// A dark, readable syntax color theme.
///
/// Maps tree-sitter highlight capture names (e.g. `keyword`, `string`, `function`)
/// to colors, then builds a Neon `TokenAttributeProvider` that styles each token.
/// Colors are tuned for contrast against cmux's dark preview background; unmapped
/// captures fall back to the foreground color so text is never invisible.
///
/// `@unchecked Sendable`: the stored `NSColor`s are immutable value-like color
/// objects, safe to read across threads.
public struct CodeTheme: @unchecked Sendable {
    public var foreground: NSColor
    public var keyword: NSColor
    public var string: NSColor
    public var comment: NSColor
    public var number: NSColor
    public var function: NSColor
    public var type: NSColor
    public var variable: NSColor
    public var property: NSColor
    public var constant: NSColor
    public var punctuation: NSColor

    public init(
        foreground: NSColor,
        keyword: NSColor,
        string: NSColor,
        comment: NSColor,
        number: NSColor,
        function: NSColor,
        type: NSColor,
        variable: NSColor,
        property: NSColor,
        constant: NSColor,
        punctuation: NSColor
    ) {
        self.foreground = foreground
        self.keyword = keyword
        self.string = string
        self.comment = comment
        self.number = number
        self.function = function
        self.type = type
        self.variable = variable
        self.property = property
        self.constant = constant
        self.punctuation = punctuation
    }

    /// Default dark theme, tuned for readability against a dark editor background.
    public static let dark = CodeTheme(
        foreground: NSColor(srgbRed: 0.86, green: 0.87, blue: 0.89, alpha: 1),  // near-white
        keyword: NSColor(srgbRed: 0.78, green: 0.57, blue: 0.92, alpha: 1),     // purple
        string: NSColor(srgbRed: 0.60, green: 0.84, blue: 0.50, alpha: 1),      // green
        comment: NSColor(srgbRed: 0.48, green: 0.52, blue: 0.58, alpha: 1),     // muted gray
        number: NSColor(srgbRed: 0.92, green: 0.68, blue: 0.42, alpha: 1),      // orange
        function: NSColor(srgbRed: 0.45, green: 0.74, blue: 0.96, alpha: 1),    // blue
        type: NSColor(srgbRed: 0.36, green: 0.81, blue: 0.78, alpha: 1),        // teal
        variable: NSColor(srgbRed: 0.86, green: 0.87, blue: 0.89, alpha: 1),    // foreground
        property: NSColor(srgbRed: 0.82, green: 0.76, blue: 0.97, alpha: 1),    // light purple
        constant: NSColor(srgbRed: 0.95, green: 0.55, blue: 0.55, alpha: 1),    // red
        punctuation: NSColor(srgbRed: 0.66, green: 0.72, blue: 0.80, alpha: 1)  // soft gray-blue
    )

    /// Resolve a tree-sitter capture name to a color, honoring dotted refinements
    /// (e.g. `keyword.return` → `keyword`) by matching on the leading component.
    public func color(forCaptureName name: String) -> NSColor {
        let root = name.split(separator: ".").first.map(String.init) ?? name
        switch root {
        case "keyword", "tag": return keyword
        case "string", "escape": return string
        case "comment": return comment
        case "number", "float", "integer", "boolean": return number
        case "function", "method": return function
        case "type", "constructor", "namespace", "module": return type
        case "constant": return constant
        case "property", "field", "attribute": return property
        case "variable", "parameter", "label": return variable
        case "punctuation", "operator", "delimiter", "bracket": return punctuation
        default: return foreground
        }
    }

    /// Build a Neon attribute provider that colors each token via this theme.
    ///
    /// Only the foreground color is set — never the font — so the text view's base
    /// monospace font (and live zoom, which rewrites `NSTextView.font`) applies
    /// uniformly to highlighted and unhighlighted text alike.
    public func makeAttributeProvider() -> TokenAttributeProvider {
        let theme = self
        return { token in
            [.foregroundColor: theme.color(forCaptureName: token.name)]
        }
    }
}
