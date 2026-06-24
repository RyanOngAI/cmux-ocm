import AppKit
import CmuxCodeHighlighting
import Neon
import SwiftUI

/// Skip syntax-error scanning above this document length (UTF-16 units) to protect
/// typing latency. Lives at file scope because `FilePreviewTextEditor` is generic and
/// its nested `Coordinator` cannot hold static stored properties.
private let filePreviewMaxErrorScanLength = 500_000

@MainActor
protocol FilePreviewTextEditingPanel: AnyObject {
    var textContent: String { get }

    func attachTextView(_ textView: NSTextView)
    func retryPendingFocus()
    func updateTextContent(_ nextContent: String)
    @discardableResult
    func saveTextContent() -> Task<Void, Never>?
}

struct FilePreviewTextEditor<PanelModel>: NSViewRepresentable where PanelModel: ObservableObject & FilePreviewTextEditingPanel {
    @ObservedObject var panel: PanelModel
    let isVisibleInUI: Bool
    let themeBackgroundColor: NSColor
    let themeForegroundColor: NSColor
    let drawsBackground: Bool
    /// Whether long lines soft-wrap at the editor's right edge. Sourced from
    /// the persisted `fileEditor.wordWrap` setting; updates apply live.
    let wordWrap: Bool
    /// Whether tree-sitter syntax highlighting is enabled, from the persisted
    /// `fileEditor.syntaxHighlighting` setting; updates apply live.
    let syntaxHighlightingEnabled: Bool
    /// The language detected for the open file, or `nil` for unsupported types.
    /// Highlighting attaches only when this is non-nil and highlighting is enabled.
    let codeLanguage: CodeLanguage?

    func makeCoordinator() -> Coordinator {
        Coordinator(panel: panel)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.isHidden = !isVisibleInUI
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = drawsBackground

        let textView = SavingTextView.makeFilePreviewTextView()
        textView.panel = panel
        textView.delegate = context.coordinator
        textView.drawsBackground = drawsBackground
        textView.string = panel.textContent
        panel.attachTextView(textView)

        scrollView.documentView = textView
        textView.applyFilePreviewWordWrap(wordWrap, scrollView: scrollView)
        Self.applyTheme(
            to: scrollView,
            backgroundColor: themeBackgroundColor,
            foregroundColor: themeForegroundColor,
            drawsBackground: drawsBackground
        )
        context.coordinator.updateHighlighting(
            on: textView,
            enabled: syntaxHighlightingEnabled,
            language: codeLanguage,
            foregroundColor: themeForegroundColor
        )

        // Line-number gutter as a left-pinned OVERLAY view (not an NSRulerView).
        // NSScrollView's ruler machinery re-tiled this custom TextKit 1 document and
        // hid the code; an overlay never touches the scroll view's content geometry,
        // so the text view fills the scroll view exactly as it does without a gutter.
        // The code is pushed right by a matching left textContainerInset instead.
        let gutter = FilePreviewLineNumberRulerView(scrollView: scrollView, textView: textView)
        scrollView.addFloatingSubview(gutter, for: .vertical)
        context.coordinator.lineNumberGutter = gutter
        context.coordinator.updateLineNumberColors(
            foreground: themeForegroundColor,
            background: drawsBackground ? themeBackgroundColor : .clear
        )
        textView.lineNumberGutterWidth = gutter.width
        textView.applyFilePreviewTextEditorInsets()
        gutter.layoutGutter()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.panel = panel
        scrollView.isHidden = !isVisibleInUI
        Self.applyTheme(
            to: scrollView,
            backgroundColor: themeBackgroundColor,
            foregroundColor: themeForegroundColor,
            drawsBackground: drawsBackground
        )
        guard let textView = scrollView.documentView as? SavingTextView else { return }
        textView.panel = panel
        if let gutter = context.coordinator.lineNumberGutter {
            gutter.refresh()
            textView.lineNumberGutterWidth = gutter.width
        }
        textView.applyFilePreviewTextEditorInsets()
        textView.applyFilePreviewWordWrap(wordWrap, scrollView: scrollView)
        panel.attachTextView(textView)
        context.coordinator.updateHighlighting(
            on: textView,
            enabled: syntaxHighlightingEnabled,
            language: codeLanguage,
            foregroundColor: themeForegroundColor
        )
        context.coordinator.updateLineNumberColors(
            foreground: themeForegroundColor,
            background: drawsBackground ? themeBackgroundColor : .clear
        )
        context.coordinator.lineNumberGutter?.layoutGutter()
        guard textView.string != panel.textContent else { return }
        context.coordinator.isApplyingPanelUpdate = true
        textView.string = panel.textContent
        context.coordinator.isApplyingPanelUpdate = false
    }

    static func applyTheme(
        to scrollView: NSScrollView,
        backgroundColor: NSColor,
        foregroundColor: NSColor,
        drawsBackground: Bool
    ) {
        let resolvedBackgroundColor = drawsBackground ? backgroundColor : .clear
        scrollView.drawsBackground = drawsBackground
        scrollView.backgroundColor = resolvedBackgroundColor
        scrollView.contentView.drawsBackground = drawsBackground
        scrollView.contentView.backgroundColor = resolvedBackgroundColor
        if let textView = scrollView.documentView as? NSTextView {
            textView.drawsBackground = drawsBackground
            textView.backgroundColor = resolvedBackgroundColor
            textView.textColor = foregroundColor
            textView.insertionPointColor = foregroundColor
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var panel: PanelModel
        var isApplyingPanelUpdate = false

        /// The active Neon highlighter, retained so it keeps styling the view. Neon
        /// becomes the `NSTextStorage` delegate (a different slot than this object's
        /// `NSTextView` delegate role, so `textDidChange` — and thus saving — still
        /// fires while highlighting is attached).
        private var highlighter: TextViewHighlighter?
        private var highlightedLanguage: CodeLanguage?
        /// The line-number gutter overlay, retained so it can be refreshed on edits.
        var lineNumberGutter: FilePreviewLineNumberRulerView?
        /// Debounced syntax-error scan; cancelled and rescheduled on each edit.
        private var errorScanTask: Task<Void, Never>?

        init(panel: PanelModel) {
            self.panel = panel
        }

        deinit {
            errorScanTask?.cancel()
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingPanelUpdate,
                  let textView = notification.object as? SavingTextView else { return }
            panel.updateTextContent(textView.string)
            scheduleSyntaxErrorScan(on: textView, language: highlightedLanguage)
            // A length change can widen the largest line number (and thus the gutter),
            // which feeds back into the text's left inset; recompute then re-layout.
            if let gutter = lineNumberGutter {
                gutter.refresh()
                if textView.lineNumberGutterWidth != gutter.width {
                    textView.lineNumberGutterWidth = gutter.width
                    textView.applyFilePreviewTextEditorInsets()
                }
                gutter.layoutGutter()
            }
        }

        /// Update the gutter colors to match the editor theme. The digits use a dimmed
        /// foreground so they recede behind the code.
        @MainActor
        func updateLineNumberColors(foreground: NSColor, background: NSColor) {
            lineNumberGutter?.numberColor = foreground.withAlphaComponent(0.45)
            lineNumberGutter?.gutterBackgroundColor = background
        }

        /// Attach, replace, or detach the syntax highlighter to match the requested
        /// enabled state and language. Idempotent: a no-op when nothing changed.
        @MainActor
        func updateHighlighting(
            on textView: SavingTextView,
            enabled: Bool,
            language: CodeLanguage?,
            foregroundColor: NSColor
        ) {
            let desired: CodeLanguage? = enabled ? language : nil
            let isAttached = highlighter != nil
            guard desired != highlightedLanguage || (desired != nil) != isAttached else { return }

            if isAttached {
                detachHighlighter(from: textView, foregroundColor: foregroundColor)
            }
            guard let language = desired else { return }

            do {
                let configuration = try CodeHighlighterFactory.makeConfiguration(for: language)
                highlighter = try TextViewHighlighter(
                    textView: textView,
                    language: configuration.language,
                    highlightQuery: configuration.highlightQuery,
                    attributeProvider: configuration.attributeProvider
                )
                highlightedLanguage = language
                primeInitialParse(on: textView)
            } catch {
                // Leave the view as plain text if the grammar/queries fail to load.
                highlighter = nil
                highlightedLanguage = nil
            }
            scheduleSyntaxErrorScan(on: textView, language: highlightedLanguage)
        }

        /// Force tree-sitter to parse text that was already in the storage when the highlighter
        /// attached. Neon parses only through its `NSTextStorageDelegate` edit callbacks, but the
        /// text view's content is set in `makeNSView` BEFORE the highlighter becomes that delegate,
        /// so the parser's tree stays `nil` and every color query fails (`stateInvalid`) — the pane
        /// renders unhighlighted. Async-loaded files dodge this because their text arrives later via
        /// `updateNSView`; a split pane is born with the text already present, so nothing re-sets it,
        /// which is why split panes specifically came up white. Re-assigning the string fires an
        /// `.editedCharacters` change that drives the initial parse and first highlight. No-op for
        /// empty storage. `isApplyingPanelUpdate` keeps this from looking like a user edit, undo is
        /// suppressed so the no-op replacement leaves no entry, and `textView.string =` re-applies
        /// the view's typing attributes so the monospaced font is preserved.
        @MainActor
        private func primeInitialParse(on textView: SavingTextView) {
            guard let storage = textView.textStorage, storage.length > 0 else { return }
            let text = textView.string
            isApplyingPanelUpdate = true
            textView.undoManager?.disableUndoRegistration()
            textView.string = text
            textView.undoManager?.enableUndoRegistration()
            isApplyingPanelUpdate = false
        }

        /// Drop the highlighter and restore the uniform foreground color, clearing any
        /// per-token colors it applied so disabling highlighting fully reverts the view.
        @MainActor
        private func detachHighlighter(from textView: SavingTextView, foregroundColor: NSColor) {
            highlighter = nil
            highlightedLanguage = nil
            guard let storage = textView.textStorage else { return }
            let fullRange = NSRange(location: 0, length: storage.length)
            storage.removeAttribute(.foregroundColor, range: fullRange)
            storage.addAttribute(.foregroundColor, value: foregroundColor, range: fullRange)
        }

        /// Debounced, size-capped syntax-error scan. Underlines `ERROR`/`MISSING`
        /// ranges using layout-manager temporary attributes (the spell-check
        /// mechanism), which are independent of Neon's text-storage color attributes
        /// and so coexist with highlighting. A `nil` language clears the underlines.
        @MainActor
        func scheduleSyntaxErrorScan(on textView: SavingTextView, language: CodeLanguage?) {
            errorScanTask?.cancel()
            errorScanTask = Task { @MainActor [weak self, weak textView] in
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled, let self, let textView else { return }
                self.runSyntaxErrorScan(on: textView, language: language)
            }
        }

        @MainActor
        private func runSyntaxErrorScan(on textView: SavingTextView, language: CodeLanguage?) {
            guard let layoutManager = textView.layoutManager,
                  let storage = textView.textStorage else { return }
            let fullRange = NSRange(location: 0, length: storage.length)
            layoutManager.removeTemporaryAttribute(.underlineStyle, forCharacterRange: fullRange)
            layoutManager.removeTemporaryAttribute(.underlineColor, forCharacterRange: fullRange)

            guard let language, storage.length <= filePreviewMaxErrorScanLength else { return }
            let underline: [NSAttributedString.Key: Any] = [
                .underlineStyle: NSUnderlineStyle.thick.rawValue | NSUnderlineStyle.patternDot.rawValue,
                .underlineColor: NSColor.systemRed,
            ]
            for range in SyntaxErrorScanner.errorRanges(in: textView.string, language: language) {
                let clamped = NSIntersectionRange(range, fullRange)
                if clamped.length > 0 {
                    layoutManager.addTemporaryAttributes(underline, forCharacterRange: clamped)
                }
            }
        }
    }
}

enum FilePreviewTextEditorLayout {
    static let textContainerInset = NSSize(width: 12, height: 10)
    static let lineFragmentPadding: CGFloat = 0
}

extension SavingTextView {
    /// Builds the File Preview text view configured for large plain-text files.
    ///
    /// File Preview opens files up to `FilePreviewPanel.maximumLoadedTextBytes` (16 MB), which can
    /// be hundreds of thousands of lines. Selection responsiveness on that content is the reason
    /// this configuration is centralized; see `manaflow-ai/cmux#4576`.
    static func makeFilePreviewTextView() -> SavingTextView {
        // Build an EXPLICIT TextKit 1 stack so this view is never TextKit 2.
        //
        // A default `NSTextView()` is TextKit 2: selection/hit-testing then runs through
        // `NSTextSelectionNavigation`, whose work is O(N) in line-fragment count, so clicking or
        // drag-selecting in a large document pegs the main thread inside AppKit's modal
        // mouse-tracking loop and freezes the whole app (`manaflow-ai/cmux#4576`, `#5255`).
        //
        // Merely *reading* `.layoutManager` afterward — the previous mitigation — only drops the
        // view to TextKit 2 *compatibility* mode: `textLayoutManager` stays non-nil and the slow
        // selection path remains active (confirmed by live `sample` captures of the hung process).
        // Constructing the view from an `NSTextStorage` / `NSLayoutManager` / `NSTextContainer`
        // stack is the only way to guarantee `textLayoutManager == nil`, i.e. a pure TextKit 1 view
        // whose hit-testing uses `NSLayoutManager` (O(log N) with non-contiguous layout).
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        // Lazy glyph layout so multi-hundred-thousand-line documents still open instantly.
        layoutManager.allowsNonContiguousLayout = true
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(
            size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        )
        // No-wrap baseline; `applyFilePreviewWordWrap(_:scrollView:)` flips this live per the
        // `fileEditor.wordWrap` setting.
        textContainer.widthTracksTextView = false
        layoutManager.addTextContainer(textContainer)

        let textView = SavingTextView(frame: .zero, textContainer: textContainer)
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFindPanel = true
        textView.usesFontPanel = false
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        textView.applyFilePreviewTextEditorInsets()
        return textView
    }
}

extension NSTextView {
    /// Configures the text view and its scroll view for soft line wrapping
    /// (`wrap == true`) or the no-wrap baseline with a horizontal scroller
    /// (`wrap == false`). Idempotent, so it is safe to call on every SwiftUI
    /// update; toggling the `fileEditor.wordWrap` setting reflows open editors.
    func applyFilePreviewWordWrap(_ wrap: Bool, scrollView: NSScrollView) {
        guard let textContainer else { return }
        scrollView.hasHorizontalScroller = !wrap
        isHorizontallyResizable = !wrap
        if wrap {
            textContainer.widthTracksTextView = true
            // `widthTracksTextView` keeps the container pinned to the text view
            // width, so wrapping is correct even before the scroll view is laid
            // out. Only snap the frame/container to a real measured width to
            // avoid collapsing to a zero-width container during `makeNSView`,
            // before the clip view has a size; `updateNSView` re-runs once laid
            // out and reflows.
            let visibleWidth = scrollView.contentSize.width
            if visibleWidth > 0 {
                textContainer.size = NSSize(width: visibleWidth, height: .greatestFiniteMagnitude)
                setFrameSize(NSSize(width: visibleWidth, height: frame.height))
            }
        } else {
            textContainer.widthTracksTextView = false
            textContainer.size = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
        }
    }

    func applyFilePreviewTextEditorInsets() {
        let base = FilePreviewTextEditorLayout.textContainerInset
        // The line-number gutter is a left-pinned overlay; push the code right by the
        // gutter width so glyphs never draw under it. `textContainerInset` is symmetric
        // in AppKit, so this also widens the right inset by the same amount, which is
        // harmless (extra right margin in no-wrap mode, a slightly narrower wrap width
        // in wrap mode). `lineNumberGutterWidth` is 0 on plain NSTextView subclasses,
        // so non-gutter callers keep the original inset.
        let gutterWidth = (self as? SavingTextView)?.lineNumberGutterWidth ?? 0
        let targetWidth = base.width + gutterWidth
        if textContainerInset.width != targetWidth || textContainerInset.height != base.height {
            textContainerInset = NSSize(width: targetWidth, height: base.height)
        }
        if textContainer?.lineFragmentPadding != FilePreviewTextEditorLayout.lineFragmentPadding {
            textContainer?.lineFragmentPadding = FilePreviewTextEditorLayout.lineFragmentPadding
        }
    }
}

final class SavingTextView: NSTextView {
    private static let defaultPreviewFontSize: CGFloat = 13
    private static let minimumPreviewFontSize: CGFloat = 8
    private static let maximumPreviewFontSize: CGFloat = 36

    weak var panel: (any FilePreviewTextEditingPanel)?
    /// Width reserved on the left for the line-number gutter overlay. Added to the
    /// text container's left inset by `applyFilePreviewTextEditorInsets()` so code
    /// never draws under the gutter. 0 until a gutter is attached.
    var lineNumberGutterWidth: CGFloat = 0
    private var previewFontSize: CGFloat = 13
    private var pendingSaveShortcutChordPrefix: ShortcutStroke?

    deinit {}

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyFilePreviewTextEditorInsets()
        panel?.retryPendingFocus()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else {
            return super.performKeyEquivalent(with: event)
        }
        guard let shouldSave = saveShortcutMatch(for: event) else {
            return super.performKeyEquivalent(with: event)
        }
        if shouldSave {
            panel?.saveTextContent()
        }
        return true
    }

    override func magnify(with event: NSEvent) {
        let factor = 1.0 + event.magnification
        guard factor.isFinite, factor > 0 else { return }
        adjustPreviewFontSize(by: factor)
    }

    override func scrollWheel(with event: NSEvent) {
        guard FilePreviewInteraction.hasZoomModifier(event) else {
            super.scrollWheel(with: event)
            return
        }
        adjustPreviewFontSize(by: FilePreviewInteraction.zoomFactor(forScroll: event))
    }

    override func smartMagnify(with event: NSEvent) {
        if previewFontSize == Self.defaultPreviewFontSize {
            setPreviewFontSize(18)
        } else {
            setPreviewFontSize(Self.defaultPreviewFontSize)
        }
    }

    private func adjustPreviewFontSize(by factor: CGFloat) {
        setPreviewFontSize(previewFontSize * factor)
    }

    private func setPreviewFontSize(_ nextFontSize: CGFloat) {
        let clamped = min(max(nextFontSize, Self.minimumPreviewFontSize), Self.maximumPreviewFontSize)
        guard clamped.isFinite else { return }
        previewFontSize = clamped
        let nextFont = NSFont.monospacedSystemFont(ofSize: clamped, weight: .regular)
        font = nextFont
        typingAttributes[.font] = nextFont
    }

    private func saveShortcutMatch(for event: NSEvent) -> Bool? {
        let shortcut = KeyboardShortcutSettings.shortcut(for: .saveFilePreview)
        guard shortcut.hasChord else {
            pendingSaveShortcutChordPrefix = nil
            return shortcut.matches(event: event) ? true : nil
        }

        if let pendingPrefix = pendingSaveShortcutChordPrefix {
            pendingSaveShortcutChordPrefix = nil
            guard pendingPrefix == shortcut.firstStroke,
                  let secondStroke = shortcut.secondStroke else {
                return nil
            }
            return secondStroke.matches(event: event) ? true : nil
        }

        if shortcut.firstStroke.matches(event: event) {
            pendingSaveShortcutChordPrefix = shortcut.firstStroke
            return false
        }
        return nil
    }
}
