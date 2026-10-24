import AppKit

struct SwitcherLayout {
    static let cell = CGSize(width: 196, height: 156)
    static let gap: CGFloat = 8
    static let padding: CGFloat = 16
    static let footer: CGFloat = 34

    let columns: Int
    let size: CGSize
    var cell: CGSize { Self.cell }
    var gap: CGFloat { Self.gap }
    var padding: CGFloat { Self.padding }
    var footer: CGFloat { Self.footer }

    func frame(for index: Int) -> CGRect {
        let row = index / columns
        let column = index % columns
        let gridWidth = CGFloat(columns) * cell.width + CGFloat(max(0, columns - 1)) * gap
        let originX = (size.width - gridWidth) / 2
        let x = originX + CGFloat(column) * (cell.width + gap)
        let y = size.height - padding - CGFloat(row + 1) * cell.height - CGFloat(row) * gap
        return CGRect(x: x, y: y, width: cell.width, height: cell.height)
    }

    func index(at point: CGPoint, count: Int) -> Int? {
        guard count > 0 else { return nil }
        for index in 0..<count where frame(for: index).contains(point) {
            return index
        }
        return nil
    }

    static func make(count: Int, maxSize: CGSize) -> SwitcherLayout {
        let padding = Self.padding
        let gap = Self.gap
        let footer = Self.footer
        let cell = Self.cell
        let minWidth: CGFloat = 520

        if count == 0 {
            return SwitcherLayout(columns: 1, size: CGSize(width: minWidth, height: 120))
        }

        let availableW = max(cell.width, maxSize.width - padding * 2)
        var columns = max(1, Int((availableW + gap) / (cell.width + gap)))
        columns = min(columns, count)
        var rows = Int(ceil(Double(count) / Double(columns)))
        let availableH = max(cell.height, maxSize.height - padding * 2 - footer)
        while rows > 1 && CGFloat(rows) * cell.height + CGFloat(rows - 1) * gap > availableH && columns < count {
            columns += 1
            rows = Int(ceil(Double(count) / Double(columns)))
        }

        let gridWidth = CGFloat(columns) * cell.width + CGFloat(max(0, columns - 1)) * gap
        let width = max(minWidth, gridWidth + padding * 2)
        let height = padding * 2 + footer + CGFloat(rows) * cell.height + CGFloat(max(0, rows - 1)) * gap
        return SwitcherLayout(columns: columns, size: CGSize(width: width, height: height))
    }
}

final class SwitcherView: NSView {
    var items: [WindowItem] = []
    var selection = 0
    var layout = SwitcherLayout.make(count: 0, maxSize: CGSize(width: 800, height: 600))
    var onSelect: ((Int) -> Void)?
    var needsCapture = false
    // Glass or blur behind the view already gives the backdrop; this is just a light tint over it.
    var backgroundAlpha: CGFloat = 0.94

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let background = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 18, yRadius: 18)
        NSColor(srgbRed: 0.09, green: 0.09, blue: 0.1, alpha: backgroundAlpha).setFill()
        background.fill()
        NSColor.white.withAlphaComponent(0.22).setStroke()
        background.lineWidth = 1
        background.stroke()

        if items.isEmpty {
            drawEmpty()
            drawFooter()
            return
        }

        for (index, item) in items.enumerated() {
            draw(item, at: layout.frame(for: index), selected: index == selection)
        }
        drawFooter()
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = layout.index(at: point, count: items.count) else { return }
        selection = index
        needsDisplay = true
        onSelect?(index)
    }

    private func drawEmpty() {
        let text = "No windows on this screen" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.9),
            .paragraphStyle: centered,
        ]
        let rect = CGRect(x: 16, y: bounds.midY - 8, width: bounds.width - 32, height: 22)
        text.draw(in: rect, withAttributes: attributes)
    }

    private func draw(_ item: WindowItem, at rect: CGRect, selected: Bool) {
        if selected {
            let highlight = NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), xRadius: 12, yRadius: 12)
            NSColor.white.withAlphaComponent(0.16).setFill()
            highlight.fill()
            NSColor.controlAccentColor.withAlphaComponent(0.9).setStroke()
            highlight.lineWidth = 2
            highlight.stroke()
        }

        let thumb = CGRect(x: rect.minX + 8, y: rect.maxY - 108, width: rect.width - 16, height: 100)
        let well = NSBezierPath(roundedRect: thumb, xRadius: 7, yRadius: 7)
        NSGraphicsContext.saveGraphicsState()
        well.addClip()
        NSColor.white.withAlphaComponent(0.06).setFill()
        thumb.fill()
        if let thumbnail = item.thumbnail {
            drawAspectFit(thumbnail, in: thumb)
        } else {
            let iconSide: CGFloat = 32
            let iconRect = CGRect(
                x: thumb.midX - iconSide / 2,
                y: thumb.midY - iconSide / 2,
                width: iconSide,
                height: iconSide
            )
            item.icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 0.9)
        }
        NSGraphicsContext.restoreGraphicsState()

        let badgeSide: CGFloat = 18
        let badge = CGRect(x: thumb.minX + 6, y: thumb.minY + 6, width: badgeSide, height: badgeSide)
        item.icon.draw(in: badge, from: .zero, operation: .sourceOver, fraction: 1)

        let nameRect = CGRect(x: rect.minX + 8, y: thumb.minY - 20, width: rect.width - 16, height: 16)
        draw(
            item.appName,
            in: nameRect,
            font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            color: .white
        )

        guard item.showsTitle else { return }
        let titleRect = CGRect(x: rect.minX + 8, y: nameRect.minY - 16, width: rect.width - 16, height: 14)
        draw(
            item.title,
            in: titleRect,
            font: NSFont.systemFont(ofSize: 11, weight: .regular),
            color: NSColor.white.withAlphaComponent(0.62)
        )
    }

    private func drawAspectFit(_ image: NSImage, in rect: CGRect) {
        let size = image.size
        guard size.width > 1, size.height > 1 else { return }
        let scale = min(rect.width / size.width, rect.height / size.height)
        let width = size.width * scale
        let height = size.height * scale
        let dest = CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
        image.draw(in: dest, from: .zero, operation: .sourceOver, fraction: 1)
    }

    private func drawFooter() {
        let text = (
            needsCapture
                ? "No previews: turn on Screen Recording for Tab Switch"
                : "Release ⌘ to open     Tab next     Esc cancel"
        ) as NSString
        let rect = CGRect(x: 16, y: 10, width: bounds.width - 32, height: 16)
        text.draw(in: rect, withAttributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.48),
            .paragraphStyle: centered,
        ])
    }

    private func draw(_ string: String, in rect: CGRect, font: NSFont, color: NSColor) {
        let style = centered
        style.lineBreakMode = .byTruncatingTail
        (string as NSString).draw(in: rect, withAttributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: style,
        ])
    }

    private var centered: NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        return style
    }
}
