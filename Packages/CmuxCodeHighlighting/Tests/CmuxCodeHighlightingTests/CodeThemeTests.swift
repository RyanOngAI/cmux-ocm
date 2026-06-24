import AppKit
import Neon
import Testing
@testable import CmuxCodeHighlighting

@Suite("CodeTheme")
struct CodeThemeTests {
    @Test("Core captures get distinct, non-background colors")
    func distinctColorsForCoreCaptures() {
        let theme = CodeTheme.dark
        for name in ["keyword", "string", "comment", "function", "type", "number"] {
            #expect(theme.color(forCaptureName: name) != theme.foreground)
        }
        let colors = ["keyword", "string", "comment", "function", "type", "number"]
            .map { theme.color(forCaptureName: $0).description }
        #expect(Set(colors).count >= 5)
    }

    @Test("Dotted captures resolve to their root style")
    func dottedCaptureResolvesToRoot() {
        let theme = CodeTheme.dark
        #expect(theme.color(forCaptureName: "keyword.return") == theme.color(forCaptureName: "keyword"))
        #expect(theme.color(forCaptureName: "string.special") == theme.color(forCaptureName: "string"))
    }

    @Test("Unknown captures fall back to the readable foreground color")
    func unknownCaptureFallsBackToForeground() {
        let theme = CodeTheme.dark
        #expect(theme.color(forCaptureName: "totally.unknown.capture") == theme.foreground)
    }

    @Test("Attribute provider returns the capture color and the supplied font")
    func providerReturnsColorAndFont() {
        let theme = CodeTheme.dark
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let provider = theme.makeAttributeProvider(font: font)
        let attrs = provider(Token(name: "keyword", range: NSRange(location: 0, length: 1)))
        #expect(attrs[.foregroundColor] as? NSColor == theme.keyword)
        #expect(attrs[.font] as? NSFont == font)
    }
}
