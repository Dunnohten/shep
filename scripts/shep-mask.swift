// Makes everything in a screenshot transparent except the rectangles to keep.
//   shep-mask <in.png> <out.png> <capture x,y,w,h> <keep x,y,w,h> [<keep x,y,w,h> ...]
// All rectangles are global points (top-left origin). The capture rectangle is what `screencapture -R` was given, so the
// image's pixels per point is its width over the capture width. scripts/docked-shot.sh keeps the window's bounds and the
// tab's rectangle, so nothing from a window behind the title bar survives next to the tab.
// Exit status: 0 written, 2 bad usage, 3 unreadable image, 4 write failed.
import CoreGraphics
import Foundation
import ImageIO

func fail(_ message: String, _ code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

func parseRect(_ text: String) -> CGRect? {
    let v = text.split(separator: ",").compactMap { Double($0) }
    guard v.count == 4, v.allSatisfy({ $0.isFinite }), v[2] > 0, v[3] > 0 else { return nil }
    return CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
}

let args = CommandLine.arguments
guard args.count >= 5, let capture = parseRect(args[3]) else {
    fail("usage: shep-mask <in.png> <out.png> <capture x,y,w,h> <keep x,y,w,h> [<keep x,y,w,h> ...]", 2)
}
var keeps: [CGRect] = []
for text in args[4...] {
    guard let r = parseRect(text) else { fail("bad rectangle: \(text)", 2) }
    keeps.append(r)
}

guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fail("cannot read \(args[1])", 3) }
let width = image.width, height = image.height
let scaleX = CGFloat(width) / capture.width
let scaleY = CGFloat(height) / capture.height

guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fail("cannot make a bitmap", 3) }
context.clear(CGRect(x: 0, y: 0, width: width, height: height))

// Pixel rectangles with a bottom-left origin (CoreGraphics), clipped to the image.
let imageRect = CGRect(x: 0, y: 0, width: width, height: height)
var clipRects: [CGRect] = []
for k in keeps {
    let px = (k.minX - capture.minX) * scaleX
    let pyTop = (k.minY - capture.minY) * scaleY
    let pw = k.width * scaleX, ph = k.height * scaleY
    let r = CGRect(x: px, y: CGFloat(height) - pyTop - ph, width: pw, height: ph).intersection(imageRect)
    if !r.isNull, r.width > 0, r.height > 0 { clipRects.append(r.integral.intersection(imageRect)) }
}
guard !clipRects.isEmpty else { fail("no keep rectangle lies inside the capture", 2) }
context.clip(to: clipRects)
context.draw(image, in: imageRect)

guard let masked = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL, "public.png" as CFString, 1, nil) else {
    fail("cannot write \(args[2])", 4)
}
CGImageDestinationAddImage(destination, masked, nil)
guard CGImageDestinationFinalize(destination) else { fail("cannot write \(args[2])", 4) }
