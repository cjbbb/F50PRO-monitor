import AppKit

/// A two-row readout inside the status button, which keeps handling clicks.
final class MenuBarSpeedView: NSView {
    private let font = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .regular)
    private var upload = ""
    private var download = ""

    func update(upload: String, download: String) -> CGFloat {
        self.upload = upload.replacingOccurrences(of: ".0 ", with: " ")
        self.download = download.replacingOccurrences(of: ".0 ", with: " ")
        needsDisplay = true
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let textWidth = max(
            (self.upload as NSString).size(withAttributes: attributes).width,
            (self.download as NSString).size(withAttributes: attributes).width
        )
        return ceil(textWidth) + 14
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor
        ]
        for (text, color, rowY) in [
            (upload, NSColor.systemRed, CGFloat(11)),
            (download, NSColor.systemBlue, CGFloat(0))
        ] {
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: 1, y: rowY + 2.5, width: 6, height: 6)).fill()
            let textHeight = (text as NSString).size(withAttributes: attributes).height
            (text as NSString).draw(
                at: NSPoint(x: 14, y: rowY + (11 - textHeight) / 2),
                withAttributes: attributes
            )
        }
    }
}
