import AppKit

/// A line-number gutter for the file-preview text editor.
///
/// Draws 1-based line numbers aligned with each logical line, skipping soft-wrapped
/// continuation fragments. Line starts are cached and rebuilt only when the document
/// length changes, so scrolling a large file stays cheap (the per-line lookup is a
/// binary search rather than an O(n) newline count per frame).
final class FilePreviewLineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?

    /// Color of the line-number digits. Set from the editor theme.
    var numberColor: NSColor = .secondaryLabelColor {
        didSet { needsDisplay = true }
    }
    /// Gutter background. `.clear` lets the editor background show through.
    var gutterBackgroundColor: NSColor = .clear {
        didSet { needsDisplay = true }
    }

    private var lineStartCache: [Int] = [0]
    private var cachedLength: Int = -1
    private var boundsObserver: NSObjectProtocol?

    init(scrollView: NSScrollView, textView: NSTextView) {
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        self.textView = textView
        clientView = textView
        ruleThickness = 46

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
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let boundsObserver {
            NotificationCenter.default.removeObserver(boundsObserver)
        }
    }

    /// Force a redraw — call when the text changes or the font/zoom changes.
    func refresh() {
        needsDisplay = true
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

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }

        if gutterBackgroundColor != .clear {
            gutterBackgroundColor.setFill()
            rect.fill()
        }

        let text = textView.string as NSString
        rebuildLineStartsIfNeeded(text)

        let inset = textView.textContainerInset.height
        let relativePoint = convert(NSPoint.zero, from: textView)

        let editorFont = textView.font ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
        let digitFont = NSFont.monospacedDigitSystemFont(
            ofSize: max(9, editorFont.pointSize - 1),
            weight: .regular
        )
        let attributes: [NSAttributedString.Key: Any] = [
            .font: digitFont,
            .foregroundColor: numberColor,
        ]

        let visibleGlyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: container)
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
            let y = relativePoint.y + fragmentRect.minY + inset + (fragmentRect.height - size.height) / 2
            let x = self.ruleThickness - size.width - 8
            label.draw(at: NSPoint(x: x, y: y), withAttributes: attributes)
        }
    }
}
