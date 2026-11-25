import AppKit
let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
NSColor(calibratedRed: 0.055, green: 0.09, blue: 0.12, alpha: 1).setFill()
NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1024, height: 1024)).fill()
let screen = NSBezierPath(roundedRect: NSRect(x: 170, y: 300, width: 684, height: 440), xRadius: 84, yRadius: 84)
NSColor(calibratedRed: 0.27, green: 0.9, blue: 0.73, alpha: 1).setStroke()
screen.lineWidth = 38; screen.stroke()
func line(_ points: [NSPoint], _ width: CGFloat) {
    let p = NSBezierPath(); p.move(to: points[0]); for point in points.dropFirst() { p.line(to: point) }
    p.lineWidth = width; p.lineCapStyle = .round; p.lineJoinStyle = .round; p.stroke()
}
line([NSPoint(x: 340, y: 610), NSPoint(x: 455, y: 520), NSPoint(x: 340, y: 430)], 42)
line([NSPoint(x: 520, y: 430), NSPoint(x: 680, y: 430)], 42)
line([NSPoint(x: 512, y: 280), NSPoint(x: 512, y: 215)], 35)
line([NSPoint(x: 350, y: 205), NSPoint(x: 674, y: 205)], 35)
image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "ADBX/Assets.xcassets/AppIcon.appiconset/icon.png"))
