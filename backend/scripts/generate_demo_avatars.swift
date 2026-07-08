// Generates the bundled demo-seed avatar images (macOS-only dev tool; run manually, commit the output).
//
//   swift backend/scripts/generate_demo_avatars.swift
//
// Writes PNGs into backend/app/integrations/dev_seed/assets/. The demo seeder (dev_seed/seeder.py) uploads
// these to MinIO as real custom avatars for the connected partner "Jamie" and the two sample groups, so the
// demo shows photos instead of monogram placeholders. The art is drawn from scratch (gradient + simple white
// shapes / a monogram) so there is no third-party image or emoji artwork to license.
import AppKit

let size = CGFloat(640)
let outDir = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("app/integrations/dev_seed/assets")

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

/// Render one avatar: a diagonal gradient background + a `draw` closure for the white foreground art.
func render(_ name: String, from: UInt32, to: UInt32, draw: () -> Void) {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    NSGradient(starting: color(from), ending: color(to))?.draw(in: rect, angle: -45)
    NSColor.white.setFill()
    NSColor.white.setStroke()
    draw()
    image.unlockFocus()
    guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        fputs("failed to encode \(name)\n", stderr); exit(1)
    }
    let url = outDir.appendingPathComponent(name)
    try! png.write(to: url)
    print("wrote \(url.path)")
}

// Jamie (user): a bold white "J" monogram on a violet -> pink gradient.
render("jamie.png", from: 0x7C3AED, to: 0xEC4899) {
    let text = "J" as NSString
    let font = NSFont(name: "AvenirNext-Bold", size: 380) ?? NSFont.boldSystemFont(ofSize: 380)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
    let bounds = text.size(withAttributes: attrs)
    text.draw(at: NSPoint(x: (size - bounds.width) / 2, y: (size - bounds.height) / 2), withAttributes: attrs)
}

// Apartment (group): a simple white house (roof triangle + body + door) on a teal -> green gradient.
render("apartment.png", from: 0x0EA5A4, to: 0x10B981) {
    let body = NSBezierPath(rect: NSRect(x: 210, y: 170, width: 220, height: 190))
    body.fill()
    let roof = NSBezierPath()
    roof.move(to: NSPoint(x: 180, y: 350))
    roof.line(to: NSPoint(x: 320, y: 470))
    roof.line(to: NSPoint(x: 460, y: 350))
    roof.close()
    roof.fill()
    // Door punched out of the body with the gradient showing through would need compositing; instead draw a
    // contrasting door by overlaying a translucent dark rect.
    NSColor(white: 0, alpha: 0.22).setFill()
    NSBezierPath(rect: NSRect(x: 295, y: 170, width: 50, height: 95)).fill()
}

// Weekend Trip (group): white mountains + a sun on a orange -> red gradient.
render("weekend_trip.png", from: 0xFB923C, to: 0xEF4444) {
    let sun = NSBezierPath(ovalIn: NSRect(x: 400, y: 400, width: 90, height: 90))
    sun.fill()
    let mtn = NSBezierPath()
    mtn.move(to: NSPoint(x: 120, y: 200))
    mtn.line(to: NSPoint(x: 270, y: 420))
    mtn.line(to: NSPoint(x: 360, y: 300))
    mtn.line(to: NSPoint(x: 470, y: 440))
    mtn.line(to: NSPoint(x: 560, y: 200))
    mtn.close()
    mtn.fill()
}
