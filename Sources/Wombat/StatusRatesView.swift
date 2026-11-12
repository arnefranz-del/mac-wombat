import AppKit
import WombatCore

@MainActor
final class StatusRatesView: NSView {
    static func width(for layout: MenuBarLayout) -> CGFloat {
        switch layout { case .compact: 101; case .standard: 165; case .large: 185 }
    }
    private var reading = NetworkReading(state: .warmingUp)
    private var layout: MenuBarLayout = .standard

    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }

    func update(_ reading: NetworkReading) {
        self.reading = reading
        needsDisplay = true
    }
    func setLayout(_ layout: MenuBarLayout) { self.layout = layout; needsDisplay = true }

    var displayedRates: [Double?] {
        reading.state == .measuring ? [reading.download, reading.upload] : [nil, nil]
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let highlighted = (superview as? NSButton)?.isHighlighted == true
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua || highlighted
        let textColor: NSColor = highlighted ? .white : .labelColor
        let green = dark ? NSColor(red: 0.13, green: 0.77, blue: 0.37, alpha: 1) : NSColor(red: 0.09, green: 0.51, blue: 0.25, alpha: 1)
        let red = dark ? NSColor(red: 0.94, green: 0.27, blue: 0.27, alpha: 1) : NSColor(red: 0.84, green: 0.22, blue: 0.22, alpha: 1)
        let rates = displayedRates
        let middle = bounds.midY
        switch layout {
        case .compact:
            drawComputerSymbol(x: 1, middle: middle, color: textColor)
            drawStack(rates[0], rates[1], x: 19, middle: middle, green: green, red: red, textColor: textColor)
            drawMark(x: 81, middle: middle, color: textColor)
        case .standard:
            drawComputerSymbol(x: 1, middle: middle, color: textColor)
            drawRate(rates[0], arrow: "↓", color: green, rect: NSRect(x: 19, y: middle - 7, width: 50, height: 14), fontSize: 9.5, textColor: textColor, rightAligned: false)
            drawRate(rates[1], arrow: "↑", color: red, rect: NSRect(x: 82, y: middle - 7, width: 50, height: 14), fontSize: 9.5, textColor: textColor, rightAligned: false)
            drawMark(x: 146, middle: middle, color: textColor)
        case .large:
            drawComputerSymbol(x: 1, middle: middle, color: textColor)
            drawRate(rates[0], arrow: "↓", color: green, rect: NSRect(x: 19, y: middle - 8, width: 58, height: 16), fontSize: 11.5, textColor: textColor, rightAligned: false)
            drawRate(rates[1], arrow: "↑", color: red, rect: NSRect(x: 93, y: middle - 8, width: 58, height: 16), fontSize: 11.5, textColor: textColor, rightAligned: false)
            drawMark(x: 166, middle: middle, color: textColor)
        }
    }
    private func drawMark(x: CGFloat, middle: CGFloat, color: NSColor) {
        let points = WombatGlyph.points.map { NSPoint(x: x + 15 * $0.x, y: middle + 6 - 12 * $0.y) }
        let mark = NSBezierPath()
        mark.move(to: points[0])
        for point in points.dropFirst() { mark.line(to: point) }
        mark.lineWidth = 1.6
        mark.lineCapStyle = .round
        mark.lineJoinStyle = .round
        color.setStroke()
        mark.stroke()
    }

    private func drawComputerSymbol(x: CGFloat, middle: CGFloat, color: NSColor) {
        let box = NSRect(x: x, y: middle - 7.5, width: 14, height: 15)
        // Neutral geometric computer marker; no Apple trademark artwork.
        color.setStroke()
        let screen = NSBezierPath(roundedRect: NSRect(x: box.minX + 0.8, y: box.minY + 4,
            width: box.width - 1.6, height: 9), xRadius: 1, yRadius: 1)
        screen.lineWidth = 1.2; screen.stroke()
        let stand = NSBezierPath()
        stand.move(to: NSPoint(x: box.midX, y: box.minY + 4))
        stand.line(to: NSPoint(x: box.midX, y: box.minY + 1.5))
        stand.move(to: NSPoint(x: box.midX - 3, y: box.minY + 1.5))
        stand.line(to: NSPoint(x: box.midX + 3, y: box.minY + 1.5))
        stand.lineWidth = 1.2; stand.stroke()
    }
    private func drawStack(_ down: Double?, _ up: Double?, x: CGFloat, middle: CGFloat, green: NSColor, red: NSColor, textColor: NSColor, fontSize: CGFloat = 9, width: CGFloat = 50) {
        drawRate(down, arrow: "↓", color: green, rect: NSRect(x: x, y: middle + 0.3, width: width, height: 11), fontSize: fontSize, textColor: textColor, rightAligned: false)
        drawRate(up, arrow: "↑", color: red, rect: NSRect(x: x, y: middle - 10.3, width: width, height: 11), fontSize: fontSize, textColor: textColor, rightAligned: false)
    }
    private func drawRate(_ rate: Double?, arrow: String, color: NSColor, rect: NSRect, fontSize: CGFloat, textColor: NSColor, rightAligned: Bool) {
        let (text, font) = Self.fittedRate(rate, width: rect.width, fontSize: fontSize)
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = rightAligned ? .right : .left; paragraph.lineBreakMode = .byTruncatingHead
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor, .paragraphStyle: paragraph]
        (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
        let width = min(rect.width, ceil((text as NSString).size(withAttributes: attributes).width))
        let x = rightAligned ? rect.maxX + 1 : rect.minX + width + 1
        (arrow as NSString).draw(at: NSPoint(x: x, y: rect.minY - 0.5), withAttributes: [.font: NSFont.systemFont(ofSize: fontSize + 1, weight: .bold), .foregroundColor: color])
    }

    static func fittedRate(_ rate: Double?, width: CGFloat, fontSize: CGFloat) -> (String, NSFont) {
        let text = rate.map { RateFormatter.format($0).text } ?? "—"
        var font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .medium)
        let size = (text as NSString).size(withAttributes: [.font: font]).width
        if size > width {
            font = NSFont.monospacedDigitSystemFont(ofSize: max(7, fontSize * width / size), weight: .medium)
        }
        if (text as NSString).size(withAttributes: [.font: font]).width > width {
            return ((rate ?? 0) >= 999_000_000_000 ? ">999 GB/s" : "—", font)
        }
        return (text, font)
    }
}
