import AppKit

let directory = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let size = base * scale
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        let s = CGFloat(size)
        let rect = NSRect(x: s * 0.06, y: s * 0.06, width: s * 0.88, height: s * 0.88)
        let background = NSBezierPath(roundedRect: rect, xRadius: s * 0.2, yRadius: s * 0.2)
        NSGradient(starting: NSColor(srgbRed: 0.12, green: 0.37, blue: 0.32, alpha: 1), ending: NSColor(srgbRed: 0.07, green: 0.18, blue: 0.18, alpha: 1))!.draw(in: background, angle: 90)
        let ring = NSBezierPath()
        ring.appendArc(withCenter: NSPoint(x: s / 2, y: s / 2), radius: s * 0.30, startAngle: 45, endAngle: 315, clockwise: false)
        ring.lineWidth = s * 0.035
        ring.lineCapStyle = .round
        NSColor(srgbRed: 0.52, green: 0.88, blue: 0.72, alpha: 1).setStroke()
        ring.stroke()
        let text = "C" as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: s * 0.43, weight: .semibold), .foregroundColor: NSColor.white]
        let textSize = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: (s - textSize.width) / 2, y: (s - textSize.height) / 2), withAttributes: attributes)
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(directory)/icon_\(base)x\(base)\(suffix).png"))
    }
}
