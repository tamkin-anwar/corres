// A real screenshot inside one of Apple's Product Bezels (Apple Design
// Resources), for the website. The bezel is drawn over the screenshot as
// Apple supplies it, never redrawn, tilted or recolored; the screenshot
// fills the bezel's transparent screen, found by walking out from the
// middle of the image.
//
//   swift Scripts/RenderDeviceShot.swift <bezel.png> <screenshot.png> <out.png> [background #RRGGBB] [fit]
//
// A screenshot whose shape doesn't match the screen, or any screenshot
// given a fit below 1 (a Mac window, shadow and all, on a MacBook display), sits
// on the background color at that share of the screen, centered below
// the camera notch.
import AppKit

let args = CommandLine.arguments
guard args.count >= 4,
      let bezel = NSBitmapImageRep(data: (try? Data(contentsOf: URL(fileURLWithPath: args[1]))) ?? Data()),
      let shot = NSImage(contentsOfFile: args[2]) else {
    print("usage: RenderDeviceShot <bezel.png> <screenshot.png> <out.png> [background #RRGGBB]"); exit(1)
}
let width = bezel.pixelsWide, height = bezel.pixelsHigh

/// The screen: the transparent area around the middle of the bezel.
func screenRect() -> CGRect {
    func clear(_ x: Int, _ y: Int) -> Bool { (bezel.colorAt(x: x, y: y)?.alphaComponent ?? 1) < 0.5 }
    let cx = width / 2
    // A MacBook's display sits above the middle of the image; walk up the
    // centre line to the first transparent pixel.
    var cy = height / 2
    while cy > 0 && !clear(cx, cy) { cy -= 1 }
    var left = cx, right = cx
    while left > 0 && clear(left - 1, cy) { left -= 1 }
    while right < width - 1 && clear(right + 1, cy) { right += 1 }
    // Up and down a quarter of the way in: the middle column runs into the
    // Dynamic Island or the camera notch, and the edges into the corners.
    let column = left + (right - left) / 4
    var top = cy, bottom = cy
    while top > 0 && clear(column, top - 1) { top -= 1 }
    while bottom < height - 1 && clear(column, bottom + 1) { bottom += 1 }
    // The corner radius: in from the top-left corner along the diagonal,
    // past whatever is outside the device and then the frame, to the
    // screen; on a circular corner that's r(1 - 1/√2) in.
    let limit = min(right - left, bottom - top) / 2
    var d = 0
    while d < limit && clear(left + d, top + d) { d += 1 }
    if d > 0 || !clear(left, top) { while d < limit && !clear(left + d, top + d) { d += 1 } }
    radius = CGFloat(d) / (1 - 1 / 2.0.squareRoot())
    // Image rows run top-down; the drawing context runs bottom-up.
    return CGRect(x: left, y: height - 1 - bottom, width: right - left + 1, height: bottom - top + 1)
}

var radius: CGFloat = 0
let screen = screenRect()
guard let canvas = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: canvas) else { exit(1) }
NSGraphicsContext.current = context
let cg = context.cgContext

let shotSize = shot.representations.first.map { CGSize(width: $0.pixelsWide, height: $0.pixelsHigh) } ?? shot.size
// Clipped to the screen's own corners, so nothing shows past the glass.
let clip = screen.insetBy(dx: -2, dy: -2)
cg.addPath(CGPath(roundedRect: clip, cornerWidth: min(radius + 2, clip.width / 2), cornerHeight: min(radius + 2, clip.height / 2), transform: nil))
cg.clip()
let fit = args.count > 5 ? CGFloat(Double(args[5]) ?? 1) : 1
let sameShape = fit >= 1 && abs(shotSize.width / shotSize.height - screen.width / screen.height) < 0.02
if sameShape {
    // Slightly past the edges, under the bezel, so no hairline shows.
    shot.draw(in: screen.insetBy(dx: -2, dy: -2))
} else {
    let hex = args.count > 4 ? args[4] : "#0A0A0C"
    let v = Int(hex.dropFirst(), radix: 16) ?? 0
    cg.setFillColor(NSColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255,
                            blue: CGFloat(v & 255) / 255, alpha: 1).cgColor)
    cg.fill(screen.insetBy(dx: -2, dy: -2))
    let scale = min(screen.width / shotSize.width, screen.height / shotSize.height) * min(fit, 1)
    let size = CGSize(width: shotSize.width * scale, height: shotSize.height * scale)
    // Centered in what's left below the top 4%, where a MacBook's notch is.
    let below = screen.height * 0.96
    shot.draw(in: CGRect(x: screen.midX - size.width / 2, y: screen.minY + (below - size.height) / 2,
                         width: size.width, height: size.height))
}
cg.resetClip()
NSImage(cgImage: bezel.cgImage!, size: NSSize(width: width, height: height))
    .draw(in: CGRect(x: 0, y: 0, width: width, height: height))
NSGraphicsContext.current = nil

guard let png = canvas.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: args[3]))
print("\(args[3]): screen \(Int(screen.width)) × \(Int(screen.height)) at (\(Int(screen.minX)), \(height - Int(screen.maxY))), corners \(Int(radius))")
