import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let output = URL(fileURLWithPath: CommandLine.arguments[1])
let rounded = CommandLine.arguments.count > 2 && CommandLine.arguments[2] == "rounded"
let size = 1024
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                 isPlanar: false, colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0),
      let graphics = NSGraphicsContext(bitmapImageRep: rep) else { fatalError("Bitmap unavailable") }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = graphics
let context = graphics.cgContext
context.setAllowsAntialiasing(true)
context.setShouldAntialias(true)
let bounds = CGRect(x: 0, y: 0, width: size, height: size)
context.setFillColor(NSColor(calibratedRed: 0.065, green: 0.087, blue: 0.13, alpha: 1).cgColor)
if rounded { context.addPath(CGPath(roundedRect: bounds.insetBy(dx: 28, dy: 28), cornerWidth: 225, cornerHeight: 225, transform: nil)) }
else { context.addRect(bounds) }
context.fillPath()

let blue = NSColor(calibratedRed: 0.25, green: 0.49, blue: 0.99, alpha: 1).cgColor
let pale = NSColor(calibratedRed: 0.66, green: 0.79, blue: 1, alpha: 1).cgColor

// Two offset directional marks suggest a quick, two-way handoff without copying a paper-plane logo.
context.setStrokeColor(blue)
context.setLineWidth(94)
context.setLineCap(.round)
context.move(to: CGPoint(x: 220, y: 326))
context.addLine(to: CGPoint(x: 706, y: 700))
context.strokePath()
let head = CGMutablePath()
head.move(to: CGPoint(x: 592, y: 808))
head.addLine(to: CGPoint(x: 810, y: 792))
head.addLine(to: CGPoint(x: 782, y: 570))
head.addLine(to: CGPoint(x: 714, y: 657))
head.addLine(to: CGPoint(x: 711, y: 712))
head.addLine(to: CGPoint(x: 664, y: 708))
head.closeSubpath()
context.addPath(head)
context.setFillColor(blue)
context.fillPath()

context.setStrokeColor(pale)
context.setLineWidth(58)
context.move(to: CGPoint(x: 660, y: 285))
context.addLine(to: CGPoint(x: 389, y: 495))
context.strokePath()
let smallHead = CGMutablePath()
smallHead.move(to: CGPoint(x: 397, y: 415))
smallHead.addLine(to: CGPoint(x: 310, y: 548))
smallHead.addLine(to: CGPoint(x: 471, y: 511))
smallHead.closeSubpath()
context.addPath(smallHead)
context.setFillColor(pale)
context.fillPath()

graphics.flushGraphics()
NSGraphicsContext.restoreGraphicsState()
if rounded {
    guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("PNG unavailable") }
    try png.write(to: output)
} else {
    guard let opaque = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                 bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
          let image = rep.cgImage,
          let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("Opaque bitmap unavailable")
    }
    opaque.draw(image, in: bounds)
    guard let outputImage = opaque.makeImage() else { fatalError("Image unavailable") }
    CGImageDestinationAddImage(destination, outputImage, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("PNG export failed") }
}
