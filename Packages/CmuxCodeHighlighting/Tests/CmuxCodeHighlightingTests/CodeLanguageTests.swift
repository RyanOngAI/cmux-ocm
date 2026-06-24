import Testing
@testable import CmuxCodeHighlighting

@Suite("CodeLanguage detection")
struct CodeLanguageTests {
    @Test("Detects supported languages by extension, case-insensitively")
    func detectsByExtension() {
        #expect(CodeLanguage.detect(fileExtension: "py") == .python)
        #expect(CodeLanguage.detect(fileExtension: "PY") == .python)
        #expect(CodeLanguage.detect(fileExtension: "ts") == .typescript)
        #expect(CodeLanguage.detect(fileExtension: "mts") == .typescript)
        #expect(CodeLanguage.detect(fileExtension: "tsx") == .tsx)
        #expect(CodeLanguage.detect(fileExtension: "js") == .javascript)
        #expect(CodeLanguage.detect(fileExtension: "jsx") == .jsx)
    }

    @Test("Detects the additional common languages by extension")
    func detectsAdditionalLanguages() {
        #expect(CodeLanguage.detect(fileExtension: "json") == .json)
        #expect(CodeLanguage.detect(fileExtension: "sh") == .bash)
        #expect(CodeLanguage.detect(fileExtension: "zsh") == .bash)
        #expect(CodeLanguage.detect(fileExtension: "html") == .html)
        #expect(CodeLanguage.detect(fileExtension: "css") == .css)
        #expect(CodeLanguage.detect(fileExtension: "go") == .go)
        #expect(CodeLanguage.detect(fileExtension: "rs") == .rust)
        #expect(CodeLanguage.detect(fileExtension: "c") == .c)
        #expect(CodeLanguage.detect(fileExtension: "cpp") == .cpp)
        #expect(CodeLanguage.detect(fileExtension: "rb") == .ruby)
        #expect(CodeLanguage.detect(fileExtension: "java") == .java)
    }

    @Test("Returns nil for unsupported or empty extensions")
    func ignoresUnsupported() {
        #expect(CodeLanguage.detect(fileExtension: "md") == nil)
        #expect(CodeLanguage.detect(fileExtension: "png") == nil)
        #expect(CodeLanguage.detect(fileExtension: "") == nil)
    }

    @Test("Detects from a full path, including no-extension files")
    func detectsByPath() {
        #expect(CodeLanguage.detect(path: "/a/b/main.py") == .python)
        #expect(CodeLanguage.detect(path: "/a/b/App.tsx") == .tsx)
        #expect(CodeLanguage.detect(path: "/a/b/README.md") == nil)
        #expect(CodeLanguage.detect(path: "/a/b/Makefile") == nil)
    }
}
