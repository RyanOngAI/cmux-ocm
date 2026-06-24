import AppKit

/// A line-number gutter for the file-preview text editor.
///
/// Implemented as a plain overlay `NSView` pinned to the left edge of the scroll
/// view rather than an `NSRulerView`. The `NSScrollView` ruler machinery re-tiles
/// the clip/document views to make room for the ruler, which mis-framed this
/// custom TextKit 1 stack (`autoresizingMask = [.width]`,
/// `isHorizontallyResizable = true`, non-contiguous layout) so the code glyphs
/// laid out outside the visible content rect and rendered invisibly while the
/// ruler still drew its numbers. An overlay view never touches the scroll
/// view's content geometry: the document text view fills the scroll view exactly
/// as it does without a gutter, and the code is simply pushed right by a matching
/// left `textContainerInset` so it does not draw under the gutter.
///
/// Draws 1-based line numbers aligned with each logical line, skipping soft-wrapped
/// continuation fragments. Line starts are cached and rebuilt only when the document
/// length changes, so scrolling a large file stays cheap (the per-line lookup is a
/// binary search rather than an O(n) newline count per frame). Only the visible glyph
/// range is enumerated and drawn each frame.
final class FilePreviewLineNumberRulerView: NSView {
    private weak var textView: NSTextView?
    private weak var scrollView: NSScrollView?

    /// Color of the line-number digits. Set from the editor theme.
    var numberColor: NSColor = .secondaryLabelColor {
        didSet { needsDisplay = true }
    }
    /// Gutter background. `.clear` lets the editor background show through.
    var gutterBackgroundColor: NSColor = .clear {
        didSet { needsDisplay = true }
    }

    /// Horizontal padding between the digits and the gutter's right edge (where the
    /// code begins). The code's left `textContainerInset` is set to `width` so glyphs
    /// never draw under the gutter.
    private static let rightPadding: CGFloat = 8
    /// Minimum gutter width, also the width before any text has been measured.
    private static let minimumWidth: CGFloat = 40

    private var lineStartCache: [Int] = [0]
    private var cachedLength: Int = -1
    private var boundsObserver: NSObjectProtocol?
    private var frameObserver: NSObjectProtocol?

    /// Current resolved gutter width (right edge of the digits column). Drives both
    /// this view's frame and the text view's left `textContainerInset`.
    private(set) var width: CGFloat = FilePreviewLineNumberRulerView.minimumWidth

    init(scrollView: NSScrollView, textView: NSTextView) {
        self.scrollView = scrollView
        self.textView = textView
        super.init(frame: NSRect(x: 0, y: 0, width: FilePreviewLineNumberRulerView.minimumWidth, height: 0))
        // Pin to the left edge and track the scroll view's height. The gutter floats
        // above the clip view; it is not the scroll view's document/content view, so
        // it never participates in (or perturbs) the scroll view's content tiling.
        autoresizingMask = [.height]
        wantsLayer = true

        // Redraw as the document scrolls.
        let clipView = scrollView.contentView
        clipView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clipView,
            queue: .main
        ) { [weak self] _ in
            self?.needsDisplay = true
        }
        // Redraw when the document view reflows (length/font/zoom/wrap changes alter
        // its frame). The line numbers must re-align with the new layout.
        textView.postsFrameChangedNotifications = true
        frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: textView,
            queue: .main
        ) { [weak self] _ in
            // A frame change can mean a font/zoom reflow, which changes the digit font
            // size and thus the gutter width. Recompute (forced, since length may be
            // unchanged) and push the new width back into the text's left inset.
            self?.handleTextViewReflow()
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let boundsObserver {
            NotificationCenter.default.removeObserver(boundsObserver)
        }
        if let frameObserver {
            NotificationCenter.default.removeObserver(frameObserver)
        }
    }

    /// Flip the coordinate system so it matches the text view's top-left origin (y grows
    /// down). Each line fragment's rect is already in that space, so after subtracting the
    /// scroll offset the y maps straight across with no vertical inversion.
    override var isFlipped: Bool { true }

    /// Force a redraw — call when the text changes or the font/zoom changes.
    func refresh() {
        recomputeWidthIfNeeded()
        needsDisplay = true
    }

    /// Resize and reposition the gutter to overlay the left edge of the scroll view's
    /// content area, then make the text leave room for it. Called by the host on layout,
    /// scroll, edit, and theme updates.
    func layoutGutter() {
        guard let scrollView else { return }
        recomputeWidthIfNeeded()
        let contentHeight = scrollView.contentView.bounds.height
        // Anchor to the scroll view's content (clip) frame so the gutter sits over the
        // visible document, inside any scroller insets.
        let clipFrame = scrollView.contentView.frame
        let newFrame = NSRect(x: clipFrame.minX, y: clipFrame.minY, width: width, height: contentHeight)
        if frame != newFrame {
            frame = newFrame
        }
        needsDisplay = true
    }

    /// React to a text-view reflow (font/zoom/wrap change): recompute the gutter width
    /// against the new digit font, push it into the text's left inset if it changed, then
    /// re-layout. Length is often unchanged here, so the recompute is forced.
    private func handleTextViewReflow() {
        let previousWidth = width
        recomputeWidthIfNeeded(force: true)
        if let savingTextView = textView as? SavingTextView, width != previousWidth {
            savingTextView.lineNumberGutterWidth = width
            savingTextView.applyFilePreviewTextEditorInsets()
        }
        layoutGutter()
    }

    /// Largest line number's rendered width plus padding, clamped to a minimum. Recomputed
    /// only when the cached document length changes (i.e. the line count may have changed),
    /// or when `force` is set (e.g. the digit font changed on zoom).
    private func recomputeWidthIfNeeded(force: Bool = false) {
        guard let textView else { return }
        let text = textView.string as NSString
        let lengthChanged = text.length != cachedLength
        rebuildLineStartsIfNeeded(text)
        guard force || lengthChanged || width == Self.minimumWidth else { return }

        let lineCount = max(1, lineStartCache.count)
        let digits = String(lineCount).count
        let sample = String(repeating: "0", count: digits) as NSString
        let measured = sample.size(withAttributes: [.font: digitFont(for: textView)]).width
        width = max(Self.minimumWidth, ceil(measured) + Self.rightPadding * 2)
    }

    private func digitFont(for textView: NSTextView) -> NSFont {
        let editorFont = textView.font ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
        return NSFont.monospacedDigitSystemFont(
            ofSize: max(9, editorFont.pointSize - 1),
            weight: .regular
        )
    }

    private func rebuildLineStartsIfNeeded(_ text: NSString) {
        guard text.length != cachedLength else { return }
        cachedLength = text.length
        var starts: [Int] = [0]
        var index = 0
        while index < text.length {
            let found = text.range(
                of: "\n",
                options: [],
                range: NSRange(location: index, length: text.length - index)
            )
            if found.location == NSNotFound { break }
            starts.append(found.location + 1)
            index = found.location + 1
        }
        lineStartCache = starts
    }

    /// 1-based line number for a character index (largest line start <= index).
    private func lineNumber(forCharacterIndex characterIndex: Int) -> Int {
        var low = 0
        var high = lineStartCache.count - 1
        var answer = 0
        while low <= high {
            let mid = (low + high) / 2
            if lineStartCache[mid] <= characterIndex {
                answer = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return answer + 1
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let textView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }

        if gutterBackgroundColor != .clear {
            gutterBackgroundColor.setFill()
            bounds.fill()
        }

        let text = textView.string as NSString
        rebuildLineStartsIfNeeded(text)

        // Vertical offset from the text view's flipped top-left origin to this gutter's
        // bottom-left origin, accounting for the current scroll position. Each line
        // fragment's rect is in text-view coordinates; convert each one as we draw.
        let inset = textView.textContainerInset.height
        let attributes: [NSAttributedString.Key: Any] = [
            .font: digitFont(for: textView),
            .foregroundColor: numberColor,
        ]

        // Only enumerate the glyphs currently visible in the text view. Using the text
        // view's own visibleRect (NOT the gutter's) is what makes large files cheap and
        // the alignment correct.
        let visibleTextRect = textView.visibleRect
        let visibleGlyphRange = layoutManager.glyphRange(forBoundingRect: visibleTextRect, in: container)
        var lastParagraphStart = -1

        layoutManager.enumerateLineFragments(forGlyphRange: visibleGlyphRange) { fragmentRect, _, _, glyphRange, _ in
            let characterIndex = layoutManager.characterIndexForGlyph(at: glyphRange.location)
            let paragraphRange = text.lineRange(for: NSRange(location: characterIndex, length: 0))
            // Soft-wrapped continuation fragments share a paragraph start; number once.
            guard paragraphRange.location != lastParagraphStart else { return }
            lastParagraphStart = paragraphRange.location

            let number = self.lineNumber(forCharacterIndex: paragraphRange.location) as NSNumber
            let label = number.stringValue as NSString
            let size = label.size(withAttributes: attributes)

            // Fragment top in text-view coordinates (text view is flipped: y grows down).
            // The gutter is flipped too, so y maps straight across once the current
            // scroll offset (visibleTextRect.minY) is removed.
            let fragmentTopInTextView = fragmentRect.minY + inset
            let gutterY = fragmentTopInTextView - visibleTextRect.minY
                + (fragmentRect.height - size.height) / 2
            let x = self.width - size.width - Self.rightPadding
            label.draw(at: NSPoint(x: x, y: gutterY), withAttributes: attributes)
        }
    }
}
