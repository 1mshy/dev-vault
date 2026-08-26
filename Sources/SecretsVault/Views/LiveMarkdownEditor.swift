import SwiftUI
import AppKit

// MARK: - Editor palette

/// Theme tokens resolved to AppKit colors for the live markdown editor.
struct MarkdownEditorPalette {
    let textPrimary: NSColor
    let textSecondary: NSColor
    let heading: NSColor
    let accent: NSColor
    let codeText: NSColor
    let codeBackground: NSColor
    let quoteBar: NSColor
    /// nil keeps the native text background.
    let background: NSColor?
    /// nil keeps the native selection color.
    let selection: NSColor?

    init(theme: Theme) {
        func ns(_ color: Color?) -> NSColor? { color.map { NSColor($0) } }
        let primary = ns(theme.textPrimary) ?? .labelColor
        let accent = ns(theme.accent) ?? .controlAccentColor
        textPrimary = primary
        textSecondary = ns(theme.textSecondary) ?? .secondaryLabelColor
        heading = ns(theme.headingColor) ?? primary
        self.accent = accent
        codeText = ns(theme.codeText) ?? primary
        codeBackground = ns(theme.codeBackground) ?? NSColor.labelColor.withAlphaComponent(0.07)
        quoteBar = ns(theme.quoteBar) ?? accent.withAlphaComponent(0.8)
        background = ns(theme.contentBackground)
        selection = theme.accent == nil ? nil : accent.withAlphaComponent(0.3)
    }
}

// MARK: - Styler

/// Applies Obsidian-style "live preview" attributes to an NSTextStorage:
/// markdown renders in place, syntax markers are concealed, and the
/// paragraph containing the caret shows its raw text.
enum MarkdownStyler {

    static let bodySize: CGFloat = 14
    static let codeSize: CGFloat = 13

    static var bodyFont: NSFont { .systemFont(ofSize: bodySize) }
    static var codeFont: NSFont { .monospacedSystemFont(ofSize: codeSize, weight: .regular) }
    /// Collapses concealed syntax markers to (almost) nothing.
    static var hiddenFont: NSFont { .systemFont(ofSize: 0.1) }

    static func headingFont(_ level: Int) -> NSFont {
        switch level {
        case 1: return .systemFont(ofSize: 26, weight: .bold)
        case 2: return .systemFont(ofSize: 21, weight: .bold)
        case 3: return .systemFont(ofSize: 17, weight: .semibold)
        default: return .systemFont(ofSize: 15, weight: .semibold)
        }
    }

    static func baseAttributes(palette: MarkdownEditorPalette) -> [NSAttributedString.Key: Any] {
        [
            .font: bodyFont,
            .foregroundColor: palette.textPrimary,
            .paragraphStyle: paragraph()
        ]
    }

    private static func paragraph(headIndent: CGFloat = 0) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 3
        p.paragraphSpacing = 6
        p.headIndent = headIndent
        return p
    }

    // Documents larger than this get plain styling only; keeps typing snappy.
    private static let maxStyledLength = 150_000

    // MARK: Regexes

    private static let headingRx = try! NSRegularExpression(pattern: #"^\s{0,3}(#{1,6})(\s+|$)"#)
    private static let bulletRx = try! NSRegularExpression(pattern: #"^(\s*)([-*+])(\s+)"#)
    private static let numberRx = try! NSRegularExpression(pattern: #"^(\s*)(\d+[.)])(\s+)"#)
    private static let quoteRx = try! NSRegularExpression(pattern: #"^\s*((?:>\s?)+)"#)
    private static let ruleRx = try! NSRegularExpression(pattern: #"^\s*(-{3,}|\*{3,}|_{3,})\s*$"#)
    private static let codeSpanRx = try! NSRegularExpression(pattern: #"`([^`\n]+)`"#)
    private static let linkRx = try! NSRegularExpression(pattern: #"\[([^\[\]\n]+)\]\(([^)\n]+)\)"#)
    private static let boldRx = try! NSRegularExpression(pattern: #"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
    private static let asteriskItalicRx = try! NSRegularExpression(pattern: #"(?<!\*)\*(?![\*\s])(.+?)(?<![\s\*])\*(?!\*)"#)
    private static let underscoreItalicRx = try! NSRegularExpression(pattern: #"(?<![\w_])_(?![_\s])(.+?)(?<![\s_])_(?![\w_])"#)
    private static let strikeRx = try! NSRegularExpression(pattern: #"~~(?=\S)(.+?)(?<=\S)~~"#)

    // MARK: Full-document pass

    static func style(_ storage: NSTextStorage, activeRange: NSRange, palette: MarkdownEditorPalette) {
        let ns = storage.string as NSString
        let full = NSRange(location: 0, length: ns.length)

        storage.beginEditing()
        defer { storage.endEditing() }

        storage.setAttributes(baseAttributes(palette: palette), range: full)
        guard ns.length > 0, ns.length <= maxStyledLength else { return }

        let string = storage.string
        var markers: [NSRange] = []
        var inFence = false
        var location = 0

        while location < ns.length {
            var lineStart = 0, lineEnd = 0, contentsEnd = 0
            ns.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd,
                            for: NSRange(location: location, length: 0))
            let line = NSRange(location: lineStart, length: contentsEnd - lineStart)
            let paragraphRange = NSRange(location: lineStart, length: lineEnd - lineStart)
            let trimmed = ns.substring(with: line).trimmingCharacters(in: .whitespaces)
            location = lineEnd

            // Fenced code blocks: fences stay visible but dimmed.
            if trimmed.hasPrefix("```") {
                inFence.toggle()
                storage.addAttributes([
                    .font: codeFont,
                    .foregroundColor: palette.textSecondary,
                    .backgroundColor: palette.codeBackground
                ], range: paragraphRange)
                continue
            }
            if inFence {
                storage.addAttributes([
                    .font: codeFont,
                    .foregroundColor: palette.codeText,
                    .backgroundColor: palette.codeBackground
                ], range: paragraphRange)
                continue
            }
            if trimmed.isEmpty { continue }

            // Horizontal rule
            if ruleRx.firstMatch(in: string, range: line) != nil {
                storage.addAttribute(.foregroundColor, value: palette.textSecondary, range: line)
                continue
            }

            // Heading
            if let m = headingRx.firstMatch(in: string, range: line) {
                let hashes = m.range(at: 1)
                let space = m.range(at: 2)
                let level = hashes.length
                let p = NSMutableParagraphStyle()
                p.lineSpacing = 2
                p.paragraphSpacingBefore = level <= 2 ? 10 : 6
                p.paragraphSpacing = 4
                storage.addAttributes([
                    .font: headingFont(level),
                    .foregroundColor: palette.heading,
                    .paragraphStyle: p
                ], range: paragraphRange)
                let markerEnd = space.location + space.length
                markers.append(NSRange(location: hashes.location, length: markerEnd - hashes.location))
                let content = NSRange(location: markerEnd, length: line.location + line.length - markerEnd)
                styleInline(storage, range: content, palette: palette, markers: &markers)
                continue
            }

            // Block quote
            if let m = quoteRx.firstMatch(in: string, range: line) {
                let marker = m.range(at: 1)
                storage.addAttribute(.foregroundColor, value: palette.textSecondary, range: line)
                storage.addAttribute(.paragraphStyle, value: paragraph(headIndent: 18), range: paragraphRange)
                storage.addAttribute(.foregroundColor, value: palette.quoteBar, range: marker)
                let contentStart = marker.location + marker.length
                let content = NSRange(location: contentStart, length: line.location + line.length - contentStart)
                styleInline(storage, range: content, palette: palette, markers: &markers)
                continue
            }

            // Bullet list
            if let m = bulletRx.firstMatch(in: string, range: line) {
                storage.addAttribute(.foregroundColor, value: palette.accent, range: m.range(at: 2))
                storage.addAttribute(.paragraphStyle, value: paragraph(headIndent: 18), range: paragraphRange)
                let contentStart = m.range.location + m.range.length
                let content = NSRange(location: contentStart, length: line.location + line.length - contentStart)
                styleInline(storage, range: content, palette: palette, markers: &markers)
                continue
            }

            // Numbered list
            if let m = numberRx.firstMatch(in: string, range: line) {
                storage.addAttributes([
                    .foregroundColor: palette.accent,
                    .font: NSFont.monospacedDigitSystemFont(ofSize: bodySize, weight: .regular)
                ], range: m.range(at: 2))
                storage.addAttribute(.paragraphStyle, value: paragraph(headIndent: 22), range: paragraphRange)
                let contentStart = m.range.location + m.range.length
                let content = NSRange(location: contentStart, length: line.location + line.length - contentStart)
                styleInline(storage, range: content, palette: palette, markers: &markers)
                continue
            }

            // Plain paragraph
            styleInline(storage, range: line, palette: palette, markers: &markers)
        }

        // Conceal markers everywhere except the paragraph(s) holding the caret,
        // where they show dimmed — the Obsidian "reveal raw text" behavior.
        for marker in markers {
            if NSIntersectionRange(marker, activeRange).length > 0 {
                storage.addAttribute(.foregroundColor, value: palette.textSecondary, range: marker)
            } else {
                storage.addAttributes([
                    .font: hiddenFont,
                    .foregroundColor: NSColor.clear
                ], range: marker)
            }
        }
    }

    // MARK: Inline pass

    private static func styleInline(_ storage: NSTextStorage, range: NSRange,
                                    palette: MarkdownEditorPalette, markers: inout [NSRange]) {
        guard range.length > 0 else { return }
        let string = storage.string
        var consumed: [NSRange] = []
        func isFree(_ r: NSRange) -> Bool {
            !consumed.contains { NSIntersectionRange($0, r).length > 0 }
        }

        // `code`
        codeSpanRx.enumerateMatches(in: string, range: range) { match, _, _ in
            guard let m = match else { return }
            storage.addAttributes([
                .font: codeFont,
                .foregroundColor: palette.codeText,
                .backgroundColor: palette.codeBackground
            ], range: m.range(at: 1))
            markers.append(NSRange(location: m.range.location, length: 1))
            markers.append(NSRange(location: m.range.location + m.range.length - 1, length: 1))
            consumed.append(m.range)
        }

        // [label](url) — label stays, the rest conceals
        linkRx.enumerateMatches(in: string, range: range) { match, _, _ in
            guard let m = match, isFree(m.range) else { return }
            let label = m.range(at: 1)
            storage.addAttributes([
                .foregroundColor: palette.accent,
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ], range: label)
            markers.append(NSRange(location: m.range.location, length: 1))
            let tailStart = label.location + label.length
            markers.append(NSRange(location: tailStart, length: m.range.location + m.range.length - tailStart))
            consumed.append(m.range)
        }

        // **bold** / __bold__
        boldRx.enumerateMatches(in: string, range: range) { match, _, _ in
            guard let m = match, isFree(m.range) else { return }
            addTrait(.bold, in: m.range(at: 2), storage: storage)
            markers.append(NSRange(location: m.range.location, length: 2))
            markers.append(NSRange(location: m.range.location + m.range.length - 2, length: 2))
        }

        // *italic* / _italic_
        for rx in [asteriskItalicRx, underscoreItalicRx] {
            rx.enumerateMatches(in: string, range: range) { match, _, _ in
                guard let m = match, isFree(m.range) else { return }
                addTrait(.italic, in: m.range(at: 1), storage: storage)
                markers.append(NSRange(location: m.range.location, length: 1))
                markers.append(NSRange(location: m.range.location + m.range.length - 1, length: 1))
            }
        }

        // ~~strikethrough~~
        strikeRx.enumerateMatches(in: string, range: range) { match, _, _ in
            guard let m = match, isFree(m.range) else { return }
            storage.addAttribute(.strikethroughStyle,
                                 value: NSUnderlineStyle.single.rawValue,
                                 range: m.range(at: 1))
            markers.append(NSRange(location: m.range.location, length: 2))
            markers.append(NSRange(location: m.range.location + m.range.length - 2, length: 2))
        }
    }

    private static func addTrait(_ trait: NSFontDescriptor.SymbolicTraits,
                                 in range: NSRange, storage: NSTextStorage) {
        guard range.length > 0 else { return }
        storage.enumerateAttribute(.font, in: range, options: []) { value, sub, _ in
            let base = (value as? NSFont) ?? bodyFont
            let descriptor = base.fontDescriptor.withSymbolicTraits(
                base.fontDescriptor.symbolicTraits.union(trait)
            )
            if let styled = NSFont(descriptor: descriptor, size: base.pointSize) {
                storage.addAttribute(.font, value: styled, range: sub)
            }
        }
    }
}

// MARK: - Live editor

/// Obsidian-style markdown editor: text renders as formatted markdown while
/// you type; clicking into a line reveals its raw syntax for editing.
struct LiveMarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    let theme: Theme

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)

        let textView = NSTextView(frame: .zero, textContainer: container)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.importsGraphics = false
        textView.usesFontPanel = false
        textView.usesFindBar = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 14, height: 12)
        textView.delegate = context.coordinator

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder

        context.coordinator.textView = textView
        context.coordinator.applyTheme(theme, to: textView, scrollView: scrollView)

        context.coordinator.isProgrammatic = true
        textView.string = text
        context.coordinator.isProgrammatic = false
        context.coordinator.restyle()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }

        let themeChanged = context.coordinator.lastThemeID != theme.id
        if themeChanged {
            context.coordinator.applyTheme(theme, to: textView, scrollView: scrollView)
        }

        if textView.string != text {
            // External change (e.g. switching documents): replace and reset.
            context.coordinator.isProgrammatic = true
            textView.string = text
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            context.coordinator.isProgrammatic = false
            context.coordinator.restyle()
            textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        } else if themeChanged {
            context.coordinator.restyle()
        }
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: LiveMarkdownEditor
        weak var textView: NSTextView?
        var isProgrammatic = false
        private(set) var lastThemeID: String
        private var palette: MarkdownEditorPalette
        private var lastActiveParagraph = NSRange(location: NSNotFound, length: 0)

        init(_ parent: LiveMarkdownEditor) {
            self.parent = parent
            self.lastThemeID = parent.theme.id
            self.palette = MarkdownEditorPalette(theme: parent.theme)
        }

        func applyTheme(_ theme: Theme, to textView: NSTextView, scrollView: NSScrollView) {
            lastThemeID = theme.id
            palette = MarkdownEditorPalette(theme: theme)
            if let background = palette.background {
                textView.backgroundColor = background
                textView.drawsBackground = true
                scrollView.backgroundColor = background
                scrollView.drawsBackground = true
            } else {
                textView.backgroundColor = .textBackgroundColor
                textView.drawsBackground = true
                scrollView.drawsBackground = false
            }
            textView.insertionPointColor = palette.accent
            textView.selectedTextAttributes = [
                .backgroundColor: palette.selection ?? NSColor.selectedTextBackgroundColor
            ]
            textView.typingAttributes = MarkdownStyler.baseAttributes(palette: palette)
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            restyle()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isProgrammatic, let textView else { return }
            let active = (textView.string as NSString).paragraphRange(for: textView.selectedRange())
            if active != lastActiveParagraph {
                restyle()
            }
        }

        func restyle() {
            guard let textView, let storage = textView.textStorage else { return }
            let active = (textView.string as NSString).paragraphRange(for: textView.selectedRange())
            lastActiveParagraph = active
            isProgrammatic = true
            MarkdownStyler.style(storage, activeRange: active, palette: palette)
            isProgrammatic = false
        }
    }
}
