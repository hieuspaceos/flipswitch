import Cocoa

// flipswitch icon: rounded purple→blue gradient + toggle pill glyph.
// Usage: swift make_icon.swift <outdir>

let sizes = [16, 32, 64, 128, 256, 512, 1024]
let out = CommandLine.arguments[1]

for s in sizes {
    let scale: CGFloat = 1
    let px = s
    let img = NSImage(size: NSSize(width: px, height: px))
    img.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { continue }

    let f = CGFloat(px)
    // rounded squircle bg
    let r = CGRect(x: f*0.03, y: f*0.03, width: f*0.94, height: f*0.94)
    let path = CGPath(roundedRect: r, cornerWidth: f*0.22, cornerHeight: f*0.22,
                      transform: nil)
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [CGColor(red: 0.42, green: 0.35, blue: 0.95, alpha: 1),
                 CGColor(red: 0.2, green: 0.55, blue: 1.0, alpha: 1)] as CFArray,
        locations: [0, 1])!
    ctx.saveGState(); ctx.addPath(path); ctx.clip()
    ctx.drawLinearGradient(grad,
        start: CGPoint(x: 0, y: 0), end: CGPoint(x: f, y: f), options: [])
    ctx.restoreGState()

    // toggle pill: white pill with knob slid right (ON state)
    let pw = f * 0.62, ph = f * 0.34
    let pr = CGRect(x: (f - pw)/2, y: (f - ph)/2 - f*0.02, width: pw, height: ph)
    ctx.setFillColor(CGColor(gray: 1, alpha: 0.28))
    ctx.addPath(CGPath(roundedRect: pr, cornerWidth: ph/2, cornerHeight: ph/2, transform: nil))
    ctx.fillPath()
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.9)); ctx.setLineWidth(f*0.015)
    ctx.addPath(CGPath(roundedRect: pr, cornerWidth: ph/2, cornerHeight: ph/2, transform: nil))
    ctx.strokePath()
    // knob
    let kd = ph * 0.78
    let kr = CGRect(x: pr.maxX - kd - ph*0.11, y: pr.midY - kd/2, width: kd, height: kd)
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fillEllipse(in: kr)

    img.unlockFocus()
    if let t = img.tiffRepresentation,
       let rep = NSBitmapImageRep(data: t),
       let png = rep.representation(using: .png, properties: [:]) {
        let name = s == 1024 ? "icon_512x512@2x.png" : "icon_\(s)x\(s).png"
        try? png.write(to: URL(fileURLWithPath: "\(out)/\(name)"))
    }
}
