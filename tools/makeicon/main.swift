import AppKit
import Foundation

/// Renders the app icon to an .iconset and hands it to `iconutil`.
///
/// The shield geometry is duplicated from `ShieldNotch` in the app target
/// rather than shared, because the app is an executable target and cannot be
/// imported by a tool. The icon is a build artifact committed once, so the
/// duplication is checked by eye when the mark changes — not a hot path.
///
/// Usage: swift run makeicon [outputDir]

let coral = NSColor(srgbRed: 0.85, green: 0.46, blue: 0.34, alpha: 1)
let ink = NSColor(srgbRed: 0.055, green: 0.052, blue: 0.048, alpha: 1)

func shieldPath(in rect: CGRect) -> NSBezierPath {
    let w = rect.width, h = rect.height, x = rect.minX, y = rect.minY
    func p(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint {
        // Flip y: the design is expressed top-down, AppKit draws bottom-up.
        CGPoint(x: x + w * fx, y: y + h * (1 - fy))
    }
    let path = NSBezierPath()
    path.move(to: p(0.06, 0.10))
    path.line(to: p(0.34, 0.10))
    path.line(to: p(0.34, 0.24))
    path.line(to: p(0.66, 0.24))
    path.line(to: p(0.66, 0.10))
    path.line(to: p(0.94, 0.10))
    path.line(to: p(0.94, 0.55))
    path.curve(to: p(0.50, 0.97), controlPoint1: p(0.94, 0.78), controlPoint2: p(0.78, 0.92))
    path.curve(to: p(0.06, 0.55), controlPoint1: p(0.22, 0.92), controlPoint2: p(0.06, 0.78))
    path.close()
    return path
}

func render(size: Int) -> NSImage {
    let s = CGFloat(size)
    let image = NSImage(size: NSSize(width: s, height: s), flipped: false) { rect in
        // Rounded-rect backdrop in the app's ink, matching macOS icon geometry.
        let bg = NSBezierPath(roundedRect: rect, xRadius: s * 0.2237, yRadius: s * 0.2237)
        ink.setFill()
        bg.fill()

        let inset = rect.insetBy(dx: s * 0.20, dy: s * 0.20)
        coral.setFill()
        shieldPath(in: inset).fill()

        // The sentry's eye, sized so it survives downscaling to 16pt.
        let eyeW = inset.width * 0.17, eyeH = inset.height * 0.34
        let eye = NSBezierPath(roundedRect: CGRect(
            x: inset.midX - eyeW / 2,
            y: inset.midY - eyeH / 2 - inset.height * 0.06,
            width: eyeW, height: eyeH), xRadius: eyeW / 2, yRadius: eyeW / 2)
        ink.setFill()
        eye.fill()
        return true
    }
    return image
}

func png(_ image: NSImage, size: Int) -> Data? {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else { return nil }
    rep.size = NSSize(width: size, height: size)
    return rep.representation(using: .png, properties: [:])
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let iconset = "\(outDir)/SentryNotch.iconset"
try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

// The set macOS expects; omitting any of these makes iconutil refuse.
let variants: [(name: String, px: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for v in variants {
    guard let data = png(render(size: v.px), size: v.px) else {
        FileHandle.standardError.write(Data("failed to render \(v.name)\n".utf8))
        exit(1)
    }
    try data.write(to: URL(fileURLWithPath: "\(iconset)/\(v.name).png"))
}

let convert = Process()
convert.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
convert.arguments = ["-c", "icns", iconset, "-o", "\(outDir)/SentryNotch.icns"]
try convert.run()
convert.waitUntilExit()
guard convert.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}
try? FileManager.default.removeItem(atPath: iconset)
print("wrote \(outDir)/SentryNotch.icns")
