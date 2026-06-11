#!/usr/bin/env swift
// Generates Assets/AppIcon.iconset + AppIcon.icns from Assets/icon-source.jpg
// (artwork by Steve Meyfroidt). Scales the source to fill the standard macOS
// icon grid — a 824/1024 rounded rect, centred, with a hairline edge so the
// icon reads on light backgrounds — and renders every iconset size.
// Usage: swift Scripts/generate_icon.swift

import AppKit
import CoreGraphics
import Foundation

let unit: CGFloat = 1024
let scriptDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let root = scriptDir.deletingLastPathComponent()
let sourceURL = root.appendingPathComponent("Assets/icon-source.jpg")

guard let sourceImage = NSImage(contentsOf: sourceURL),
      let source = sourceImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write(Data("missing or unreadable \(sourceURL.path)\n".utf8))
    exit(1)
}

func draw(in ctx: CGContext, pixels: CGFloat) {
    ctx.saveGState()
    let scale = pixels / unit
    ctx.scaleBy(x: scale, y: scale)
    ctx.interpolationQuality = .high

    // macOS icon grid: 824x824 content area centred in the 1024 canvas.
    let margin: CGFloat = 100
    let rect = CGRect(x: margin, y: margin, width: unit - 2 * margin, height: unit - 2 * margin)
    let radius: CGFloat = 186
    let squircle = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius,
                          transform: nil)

    ctx.addPath(squircle)
    ctx.clip()

    // Scale-to-fill (source is square, so this is a clean fit).
    let sourceAspect = CGFloat(source.width) / CGFloat(source.height)
    var drawRect = rect
    if sourceAspect > 1 {
        drawRect.size.width = rect.height * sourceAspect
        drawRect.origin.x = rect.midX - drawRect.width / 2
    } else if sourceAspect < 1 {
        drawRect.size.height = rect.width / sourceAspect
        drawRect.origin.y = rect.midY - drawRect.height / 2
    }
    ctx.draw(source, in: drawRect)

    // Hairline edge so the squircle reads on light backgrounds.
    ctx.addPath(squircle)
    ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.10))
    ctx.setLineWidth(3)
    ctx.strokePath()

    ctx.restoreGState()
}

func png(at pixels: Int) -> Data {
    let ctx = CGContext(data: nil, width: pixels, height: pixels,
                        bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    draw(in: ctx, pixels: CGFloat(pixels))
    let image = ctx.makeImage()!
    let rep = NSBitmapImageRep(cgImage: image)
    return rep.representation(using: .png, properties: [:])!
}

let iconset = root.appendingPathComponent("Assets/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let entries: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, size) in entries {
    try png(at: size).write(to: iconset.appendingPathComponent(name))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path,
                      "-o", root.appendingPathComponent("Assets/AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()

// Asset catalog for the Xcode app target (ASSETCATALOG_COMPILER_APPICON_NAME).
let catalog = root.appendingPathComponent("Sources/BulkGitHub/Assets.xcassets")
let appiconset = catalog.appendingPathComponent("AppIcon.appiconset")
try? FileManager.default.removeItem(at: appiconset)
try FileManager.default.createDirectory(at: appiconset, withIntermediateDirectories: true)
try Data("""
{"info":{"author":"xcode","version":1}}
""".utf8).write(to: catalog.appendingPathComponent("Contents.json"))

var images: [[String: String]] = []
for (name, _) in entries {
    // icon_16x16@2x.png -> size "16x16", scale "2x"
    let trimmed = name.replacingOccurrences(of: "icon_", with: "")
        .replacingOccurrences(of: ".png", with: "")
    let parts = trimmed.split(separator: "@")
    let size = String(parts[0])
    let scale = parts.count > 1 ? String(parts[1]) : "1x"
    images.append(["idiom": "mac", "size": size, "scale": scale, "filename": name])
    try FileManager.default.copyItem(at: iconset.appendingPathComponent(name),
                                     to: appiconset.appendingPathComponent(name))
}
let manifest: [String: Any] = ["images": images,
                               "info": ["author": "xcode", "version": 1]]
let manifestData = try JSONSerialization.data(withJSONObject: manifest,
                                              options: [.prettyPrinted, .sortedKeys])
try manifestData.write(to: appiconset.appendingPathComponent("Contents.json"))

print(iconutil.terminationStatus == 0
      ? "Wrote Assets/AppIcon.iconset, Assets/AppIcon.icns and Sources/BulkGitHub/Assets.xcassets"
      : "iconutil failed (\(iconutil.terminationStatus))")
