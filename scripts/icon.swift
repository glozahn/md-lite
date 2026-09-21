import AppKit
let directory = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
for pixels in [16, 32, 64, 128, 256, 512, 1024] {
    let image = NSImage(size: NSSize(width: pixels, height: pixels))
    image.lockFocus()
    let scale = CGFloat(pixels) / 1024
    let transform = NSAffineTransform()
    transform.scale(by: scale)
    transform.concat()
    let rect = NSRect(x: 64, y: 64, width: 896, height: 896)
    let shape = NSBezierPath(roundedRect: rect, xRadius: 205, yRadius: 205)
    NSGradient(starting: NSColor(calibratedRed: 0.14, green: 0.29, blue: 0.32, alpha: 1), ending: NSColor(calibratedRed: 0.04, green: 0.10, blue: 0.14, alpha: 1))!.draw(in: shape, angle: -65)
    NSColor.white.withAlphaComponent(0.12).setStroke()
    shape.lineWidth = 3
    shape.stroke()
    let page = NSBezierPath(roundedRect: NSRect(x: 266, y: 222, width: 492, height: 580), xRadius: 48, yRadius: 48)
    NSColor(calibratedRed: 0.80, green: 0.94, blue: 0.90, alpha: 1).setFill()
    page.fill()
    NSColor(calibratedRed: 0.12, green: 0.31, blue: 0.32, alpha: 1).setStroke()
    let mark = NSBezierPath()
    mark.lineWidth = 31
    mark.lineCapStyle = .round
    mark.lineJoinStyle = .round
    mark.move(to: NSPoint(x: 360, y: 530)); mark.line(to: NSPoint(x: 360, y: 668))
    mark.line(to: NSPoint(x: 435, y: 586)); mark.line(to: NSPoint(x: 510, y: 668)); mark.line(to: NSPoint(x: 510, y: 530))
    mark.move(to: NSPoint(x: 634, y: 668)); mark.line(to: NSPoint(x: 634, y: 540))
    mark.move(to: NSPoint(x: 591, y: 584)); mark.line(to: NSPoint(x: 634, y: 535)); mark.line(to: NSPoint(x: 677, y: 584))
    mark.stroke()
    for (y, width) in [(430.0, 310.0), (358.0, 215.0)] {
        NSColor(calibratedRed: 0.12, green: 0.31, blue: 0.32, alpha: 0.25).setFill()
        NSBezierPath(roundedRect: NSRect(x: 358, y: y, width: width, height: 19), xRadius: 9, yRadius: 9).fill()
    }
    image.unlockFocus()
    let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
    let data = rep.representation(using: .png, properties: [:])!
    let names: [String]
    switch pixels {
    case 16: names = ["icon_16x16.png"]
    case 32: names = ["icon_16x16@2x.png", "icon_32x32.png"]
    case 64: names = ["icon_32x32@2x.png"]
    case 128: names = ["icon_128x128.png"]
    case 256: names = ["icon_128x128@2x.png", "icon_256x256.png"]
    case 512: names = ["icon_256x256@2x.png", "icon_512x512.png"]
    default: names = ["icon_512x512@2x.png"]
    }
    for name in names { try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name)) }
}
