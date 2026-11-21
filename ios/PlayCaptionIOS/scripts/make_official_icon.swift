import AppKit
import Foundation

// Convert upstream's Android launcher icon into a 1024px opaque iOS icon.
// Preserve the original artwork and proportions. Only the background is filled.
guard CommandLine.arguments.count == 3,
      let original = NSImage(contentsOfFile: CommandLine.arguments[1]) else {
    fatalError("Usage: swift make_official_icon.swift source.png destination.png")
}
let size = 1024
guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                   pixelsWide: size, pixelsHigh: size,
                                   bitsPerSample: 8, samplesPerPixel: 3,
                                   hasAlpha: false, isPlanar: false,
                                   colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0),
      let ctx = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fatalError("Cannot prepare icon image")
}
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = ctx
NSColor.black.setFill()
NSRect(x: 0, y: 0, width: size, height: size).fill()
let dimensions = original.size
let scale = min(CGFloat(size) / dimensions.width, CGFloat(size) / dimensions.height)
let width = dimensions.width * scale
let height = dimensions.height * scale
original.draw(in: NSRect(x: (CGFloat(size) - width) / 2,
                         y: (CGFloat(size) - height) / 2,
                         width: width, height: height),
              from: .zero, operation: .sourceOver, fraction: 1.0)
ctx.flushGraphics()
NSGraphicsContext.restoreGraphicsState()
guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Cannot encode icon")
}
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
print("Generated 1024×1024 iOS icon from official PlayCaption Android launcher image.")
