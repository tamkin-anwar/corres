// App Store screenshot: a Simulator capture under a headline, on Corres's
// own Obsidian, at the capture's exact pixel size (what App Store Connect
// asks for: 1320 × 2868 for iPhone 6.9", 2064 × 2752 for iPad 13").
//
//   swift Scripts/RenderStoreShot.swift <capture.png> <out.png> "Headline." "One line under it." [WxH]
//
// A Mac window capture (wider than tall) goes on a 2880 × 1800 canvas, or
// the size given, as the Mac App Store asks.
import AppKit

let args = CommandLine.arguments
guard args.count >= 5, let shot = NSImage(contentsOfFile: args[1]),
      let rep = shot.representations.first else {
    print("usage: RenderStoreShot <capture.png> <out.png> <headline> <subhead> [WxH]"); exit(1)
}
let isMac = rep.pixelsWide > rep.pixelsHigh
var width = rep.pixelsWide, height = rep.pixelsHigh
if isMac {
    let size = (args.count > 5 ? args[5] : "2880x1800").split(separator: "x").compactMap { Int($0) }
    width = size[0]; height = size[1]
}
let isPad = !isMac && Double(width) / Double(height) > 0.6

guard let canvas = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: canvas) else { exit(1) }
NSGraphicsContext.current = context
let cg = context.cgContext
let W = CGFloat(width), H = CGFloat(height)

// Obsidian, with the sapphire glow the website uses behind the mark.
cg.setFillColor(NSColor(srgbRed: 0.039, green: 0.039, blue: 0.047, alpha: 1).cgColor)
cg.fill(CGRect(x: 0, y: 0, width: W, height: H))
let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                      colors: [NSColor(srgbRed: 0.18, green: 0.36, blue: 0.62, alpha: 0.42).cgColor,
                               NSColor(srgbRed: 0.18, green: 0.36, blue: 0.62, alpha: 0).cgColor] as CFArray,
                      locations: [0, 1])!
cg.drawRadialGradient(glow, startCenter: CGPoint(x: W * 0.5, y: H * 0.86), startRadius: 0,
                      endCenter: CGPoint(x: W * 0.5, y: H * 0.86), endRadius: W * 0.85, options: [])

// Headline in New York, the line under it in SF.
func font(_ size: CGFloat, serif: Bool, weight: NSFont.Weight) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    guard serif, let descriptor = base.fontDescriptor.withDesign(.serif) else { return base }
    return NSFont(descriptor: descriptor, size: size) ?? base
}
let paragraph = NSMutableParagraphStyle()
paragraph.alignment = .center
paragraph.lineBreakMode = .byWordWrapping
let margin = W * 0.08
let headSize = W * (isMac ? 0.034 : isPad ? 0.058 : 0.088)
let head = NSAttributedString(string: args[3], attributes: [
    .font: font(headSize, serif: true, weight: .regular),
    .foregroundColor: NSColor(srgbRed: 0.95, green: 0.95, blue: 0.96, alpha: 1),
    .paragraphStyle: paragraph, .kern: -headSize * 0.012,
])
let sub = NSAttributedString(string: args[4], attributes: [
    .font: font(headSize * 0.44, serif: false, weight: .regular),
    .foregroundColor: NSColor(srgbRed: 0.63, green: 0.64, blue: 0.67, alpha: 1),
    .paragraphStyle: paragraph,
])
let textWidth = W - margin * 2
let headRect = head.boundingRect(with: CGSize(width: textWidth, height: H), options: [.usesLineFragmentOrigin])
let subRect = sub.boundingRect(with: CGSize(width: textWidth, height: H), options: [.usesLineFragmentOrigin])
let top = H * (isMac ? 0.07 : 0.055)
head.draw(with: CGRect(x: margin, y: H - top - headRect.height, width: textWidth, height: headRect.height),
          options: [.usesLineFragmentOrigin])
let gap = headSize * 0.42
sub.draw(with: CGRect(x: margin, y: H - top - headRect.height - gap - subRect.height, width: textWidth, height: subRect.height),
         options: [.usesLineFragmentOrigin])

// The capture, scaled down and rounded like the device, running off the
// bottom edge.
let scale: CGFloat = isMac ? 0.80 : isPad ? 0.80 : 0.82
let shotW = W * scale
let shotH = isMac ? shotW * CGFloat(rep.pixelsHigh) / CGFloat(rep.pixelsWide) : H * scale
let shotTop = top + headRect.height + gap + subRect.height + H * 0.04
let frame = CGRect(x: (W - shotW) / 2, y: H - shotTop - shotH, width: shotW, height: shotH)
let radius = shotW * (isMac ? 0.0105 : isPad ? 0.035 : 0.115)
let path = CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil)
cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: -W * 0.01), blur: W * 0.05,
             color: NSColor(white: 0, alpha: 0.6).cgColor)
cg.addPath(path); cg.setFillColor(NSColor.black.cgColor); cg.fillPath()
cg.restoreGState()
cg.saveGState()
cg.addPath(path); cg.clip()
shot.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1)
cg.restoreGState()
cg.addPath(path)
cg.setStrokeColor(NSColor(white: 1, alpha: 0.14).cgColor)
cg.setLineWidth(W * 0.003)
cg.strokePath()

NSGraphicsContext.current = nil
// No alpha channel: App Store Connect refuses screenshots with one.
guard let cgImage = canvas.cgImage,
      let opaque = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { exit(1) }
opaque.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
let final = NSBitmapImageRep(cgImage: opaque.makeImage()!)
try! final.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
print("\(args[2]) \(width)x\(height)")
