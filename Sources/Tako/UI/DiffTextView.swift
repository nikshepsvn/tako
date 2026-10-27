import AppKit
import SwiftUI

/// A diff in one native text view: one layout pass for the whole patch instead of a view per
/// line, so large diffs scroll at full frame rate and select and copy like text.
///
/// Unified diffs are plain paragraphs with a line-number gutter; tints span the full width and
/// are drawn in one pass under the text. Side-by-side diffs are a two-column text table.
struct DiffText: NSViewRepresentable {
    /// Which file and scope this is: the view returns to the top only when it changes, not when
    /// the agent edits the file being read.
    var identity = ""
    let lines: [PatchLine]
    let sideBySide: Bool
    /// New-file line numbers that carry a review comment, marked in the gutter.
    let commented: Set<Int>
    /// Double-click on a line of the new file.
    let onComment: (PatchLine) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let textView = DiffTextView(usingTextLayoutManager: false)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = true
        textView.backgroundColor = Theme.terminalBackground
        textView.textContainerInset = NSSize(width: 0, height: Space.xs)
        // Created at zero size: without an open-ended max size it could never grow to its text.
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.layoutManager?.allowsNonContiguousLayout = true
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.terminalBackground
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? DiffTextView else { return }
        textView.onComment = onComment
        let key = DiffTextView.Content(lines: lines, sideBySide: sideBySide, commented: commented)
        guard textView.content != key else { return }
        let sameLines = textView.content?.lines == lines && textView.content?.sideBySide == sideBySide
        textView.content = key
        textView.lineByID = Dictionary(lines.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        textView.commented = commented
        if sameLines {
            // Only the comment markers changed: redraw, keep the scroll position.
            textView.needsDisplay = true
            return
        }
        let text = sideBySide ? DiffDocument.split(lines) : DiffDocument.unified(lines)
        textView.textStorage?.setAttributedString(text)
        if textView.identity != identity {
            textView.identity = identity
            textView.scroll(.zero)
        }
    }
}

/// Builds the attributed text for a diff.
@MainActor
enum DiffDocument {
    static let kindKey = NSAttributedString.Key("KuronamiDiffKind")
    static let lineKey = NSAttributedString.Key("KuronamiDiffLine")

    private static var font: NSFont { Typeface.codeNS }
    private static let gutter: CGFloat = 44

    static func unified(_ lines: [PatchLine]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .left, location: gutter + Space.s)]
        paragraph.headIndent = gutter + Space.s
        paragraph.lineBreakMode = .byCharWrapping
        let number: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Theme.terminalForeground.withAlphaComponent(0.3)]
        for line in lines {
            let start = result.length
            let numberText = line.kind == .removed ? line.oldNumber.map(String.init) : line.newNumber.map(String.init)
            let padded = String(repeating: " ", count: max(0, 5 - (numberText?.count ?? 0))) + (numberText ?? "")
            result.append(NSAttributedString(string: line.kind == .header ? "" : padded, attributes: number))
            result.append(NSAttributedString(string: "\t" + line.text + "\n", attributes: codeAttributes(line)))
            result.addAttributes([.paragraphStyle: paragraph, kindKey: kindName(line.kind), lineKey: line.id],
                                 range: NSRange(location: start, length: result.length - start))
        }
        return result
    }

    static func split(_ lines: [PatchLine]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let table = NSTextTable()
        table.numberOfColumns = 2
        table.layoutAlgorithm = .automaticLayoutAlgorithm
        table.collapsesBorders = true
        table.hidesEmptyCells = false
        for (row, split) in SplitRow.rows(from: lines).enumerated() {
            if let header = split.header {
                append(header, text: header.text, number: nil, to: result, table: table, row: row, column: 0, span: 2)
                continue
            }
            append(split.left, text: split.left?.text ?? "", number: split.left?.oldNumber, to: result, table: table, row: row, column: 0, span: 1)
            append(split.right, text: split.right?.text ?? "", number: split.right?.newNumber, to: result, table: table, row: row, column: 1, span: 1)
        }
        return result
    }

    private static func append(_ line: PatchLine?, text: String, number: Int?, to result: NSMutableAttributedString,
                               table: NSTextTable, row: Int, column: Int, span: Int) {
        let block = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: span)
        block.setValue(CGFloat(100 / 2 * span), type: .percentageValueType, for: .width)
        block.setWidth(Space.xxs, type: .absoluteValueType, for: .padding)
        if let kind = line?.kind, kind == .added || kind == .removed {
            block.backgroundColor = tint(kind)?.withAlphaComponent(0.1)
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.textBlocks = [block]
        paragraph.lineBreakMode = .byCharWrapping
        paragraph.tabStops = [NSTextTab(textAlignment: .left, location: 36 + Space.xs)]
        paragraph.headIndent = 36 + Space.xs
        let start = result.length
        let numberText = number.map { String(repeating: " ", count: max(0, 4 - String($0).count)) + String($0) } ?? ""
        result.append(NSAttributedString(string: numberText, attributes: [
            .font: font, .foregroundColor: Theme.terminalForeground.withAlphaComponent(0.3),
        ]))
        let attributes = line.map(codeAttributes) ?? [.font: font]
        result.append(NSAttributedString(string: "\t" + text + "\n", attributes: attributes))
        var extra: [NSAttributedString.Key: Any] = [.paragraphStyle: paragraph]
        if let line { extra[lineKey] = line.id }
        result.addAttributes(extra, range: NSRange(location: start, length: result.length - start))
    }

    private static func codeAttributes(_ line: PatchLine) -> [NSAttributedString.Key: Any] {
        [.font: font,
         .foregroundColor: line.kind == .header ? Ink.faint : Theme.terminalForeground]
    }

    static func kindName(_ kind: PatchLine.Kind) -> String {
        switch kind {
        case .added: return "added"
        case .removed: return "removed"
        case .header: return "header"
        case .context: return "context"
        }
    }

    static func tint(_ kind: PatchLine.Kind) -> NSColor? {
        kind.tint.map { NSColor($0) }
    }

    static func tint(named name: String) -> NSColor? {
        switch name {
        case "added": return tint(.added)
        case "removed": return tint(.removed)
        default: return nil
        }
    }
}

/// Draws full-width line tints and comment markers under the text, and turns double-clicks
/// into review comments.
final class DiffTextView: NSTextView {
    struct Content: Equatable {
        let lines: [PatchLine]
        let sideBySide: Bool
        let commented: Set<Int>
    }

    var content: Content?
    var identity: String?
    var lineByID: [Int: PatchLine] = [:]
    var commented: Set<Int> = []
    var onComment: ((PatchLine) -> Void)?

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let layoutManager, let textContainer, let storage = textStorage, storage.length > 0 else { return }
        let origin = textContainerOrigin
        let visible = layoutManager.glyphRange(forBoundingRect: rect.offsetBy(dx: -origin.x, dy: -origin.y), in: textContainer)
        layoutManager.enumerateLineFragments(forGlyphRange: visible) { fragment, _, _, glyphs, _ in
            let index = layoutManager.characterIndexForGlyph(at: glyphs.location)
            guard index < storage.length else { return }
            let line = NSRect(x: 0, y: fragment.minY + origin.y, width: self.bounds.width, height: fragment.height)
            if let kind = storage.attribute(DiffDocument.kindKey, at: index, effectiveRange: nil) as? String,
               let tint = DiffDocument.tint(named: kind) {
                tint.withAlphaComponent(0.1).setFill()
                line.fill()
                tint.withAlphaComponent(0.8).setFill()
                NSRect(x: 0, y: line.minY, width: 2, height: line.height).fill()
            }
            if let id = storage.attribute(DiffDocument.lineKey, at: index, effectiveRange: nil) as? Int,
               let number = self.lineByID[id]?.newNumber, self.commented.contains(number) {
                Ink.accent.setFill()
                NSBezierPath(ovalIn: NSRect(x: 4, y: line.midY - 3, width: 6, height: 6)).fill()
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 2, let storage = textStorage, storage.length > 0 else {
            super.mouseDown(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        if let clamped = characterIndex(onLineAt: point),
           let id = storage.attribute(DiffDocument.lineKey, at: clamped, effectiveRange: nil) as? Int,
           let line = lineByID[id], line.newNumber != nil, line.kind != .header {
            onComment?(line)
        } else {
            super.mouseDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard let storage = textStorage, storage.length > 0 else { return menu }
        if let index = characterIndex(onLineAt: convert(event.locationInWindow, from: nil)),
           let id = storage.attribute(DiffDocument.lineKey, at: index, effectiveRange: nil) as? Int,
           let line = lineByID[id], line.newNumber != nil, line.kind != .header {
            let item = NSMenuItem(title: "Add Review Comment", action: #selector(commentFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            menu.insertItem(item, at: 0)
            menu.insertItem(.separator(), at: 1)
        }
        return menu
    }

    /// The character under `point`, or nil when it isn't on a line: below the last one, the
    /// nearest character would otherwise be the last line's and the comment would land there.
    private func characterIndex(onLineAt point: NSPoint) -> Int? {
        guard let layoutManager, let textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        let origin = textContainerOrigin
        let local = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        let glyph = layoutManager.glyphIndex(for: local, in: textContainer)
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        guard local.y >= fragment.minY, local.y < fragment.maxY else { return nil }
        return min(max(layoutManager.characterIndexForGlyph(at: glyph), 0), storage.length - 1)
    }

    @objc private func commentFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? Int, let line = lineByID[id] else { return }
        onComment?(line)
    }
}
