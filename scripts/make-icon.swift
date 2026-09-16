// Renders the Strata app icon (stacked "layers" glyph) to an .iconset directory. Run via scripts/build-app.sh.
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func render(size: Int) -> Data {
    let s = CGFloat(size)
    let image = NSImage(size: NSSize(width: s, height: s))
    image.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    let rect = CGRect(x: 0, y: 0, width: s, height: s).insetBy(dx: s * 0.06, dy: s * 0.06)
    let path = CGPath(roundedRect: rect, cornerWidth: s * 0.22, cornerHeight: s * 0.22, transform: nil)
    ctx.addPath(path); ctx.clip()
    let colors = [CGColor(red: 0.13, green: 0.16, blue: 0.24, alpha: 1), CGColor(red: 0.05, green: 0.07, blue: 0.12, alpha: 1)] as CFArray
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])
    // Three stacked layer plates, offset like strata.
    let plateW = s * 0.56, plateH = s * 0.13, gap = s * 0.19
    let tints: [(CGFloat, CGFloat, CGFloat)] = [(0.36, 0.62, 1.0), (0.55, 0.78, 1.0), (0.85, 0.92, 1.0)]
    for i in 0..<3 {
        let y = s * 0.26 + CGFloat(i) * gap
        let r = CGRect(x: (s - plateW) / 2, y: y, width: plateW, height: plateH)
        let p = CGPath(roundedRect: r, cornerWidth: plateH * 0.35, cornerHeight: plateH * 0.35, transform: nil)
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.03, color: CGColor(gray: 0, alpha: 0.5))
        ctx.setFillColor(CGColor(red: tints[i].0, green: tints[i].1, blue: tints[i].2, alpha: 1))
        ctx.addPath(p); ctx.fillPath()
        // key "caps" on each plate
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        ctx.setFillColor(CGColor(gray: 0.08, alpha: 0.25))
        let n = 5 + i
        let kw = (plateW * 0.86) / CGFloat(n)
        for k in 0..<n {
            let kr = CGRect(x: r.minX + plateW * 0.07 + CGFloat(k) * kw + kw * 0.12, y: r.minY + plateH * 0.3, width: kw * 0.76, height: plateH * 0.4)
            ctx.addPath(CGPath(roundedRect: kr, cornerWidth: kw * 0.12, cornerHeight: kw * 0.12, transform: nil)); ctx.fillPath()
        }
    }
    image.unlockFocus()
    let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
    return rep.representation(using: .png, properties: [:])!
}

for (name, size) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
                     ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
                     ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    try! render(size: size).write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
}
print("wrote \(out)")
