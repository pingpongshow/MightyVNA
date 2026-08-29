#!/usr/bin/env swift
// Generates Resources/AppIcon.icns — a Smith chart on a dark instrument face.
// Run with:  swift Scripts/make_icon.swift

import AppKit
import Foundation

let outputDirectory = FileManager.default.currentDirectoryPath + "/Resources"
let iconsetDirectory = outputDirectory + "/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: iconsetDirectory, withIntermediateDirectories: true)

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let context = NSGraphicsContext.current?.cgContext else { image.unlockFocus(); return image }

    let inset = size * 0.055
    let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let corner = rect.width * 0.2237

    // Body: deep navy gradient.
    let body = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)
    context.saveGState()
    context.addPath(body)
    context.clip()
    let colours = [
        CGColor(red: 0.09, green: 0.11, blue: 0.16, alpha: 1),
        CGColor(red: 0.03, green: 0.04, blue: 0.07, alpha: 1)
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: colours, locations: [0, 1]) {
        context.drawLinearGradient(gradient,
                                   start: CGPoint(x: rect.minX, y: rect.maxY),
                                   end: CGPoint(x: rect.maxX, y: rect.minY),
                                   options: [])
    }

    // Smith chart.
    let centre = CGPoint(x: rect.midX, y: rect.midY)
    let radius = rect.width * 0.33

    context.setLineWidth(max(0.8, size * 0.0035))
    context.setStrokeColor(CGColor(red: 0.35, green: 0.62, blue: 0.85, alpha: 0.45))

    context.saveGState()
    context.addEllipse(in: CGRect(x: centre.x - radius, y: centre.y - radius,
                                  width: radius * 2, height: radius * 2))
    context.clip()
    // Constant-resistance circles.
    for r in [0.0, 0.33, 1.0, 3.0] {
        let cx = centre.x + CGFloat(r / (1 + r)) * radius
        let rr = CGFloat(1 / (1 + r)) * radius
        context.addEllipse(in: CGRect(x: cx - rr, y: centre.y - rr, width: rr * 2, height: rr * 2))
    }
    // Constant-reactance arcs.
    for x in [0.5, 1.0, 2.5] {
        for sign in [1.0, -1.0] {
            let cy = centre.y + CGFloat(sign / x) * radius
            let rr = CGFloat(1 / x) * radius
            context.addEllipse(in: CGRect(x: centre.x + radius - rr, y: cy - rr,
                                          width: rr * 2, height: rr * 2))
        }
    }
    context.strokePath()
    context.restoreGState()

    // Outer ring.
    context.setLineWidth(max(1.2, size * 0.008))
    context.setStrokeColor(CGColor(red: 0.45, green: 0.72, blue: 0.95, alpha: 0.85))
    context.strokeEllipse(in: CGRect(x: centre.x - radius, y: centre.y - radius,
                                     width: radius * 2, height: radius * 2))

    // A measured trace spiralling in, in the app's amber.
    context.setLineWidth(max(1.5, size * 0.0135))
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.setStrokeColor(CGColor(red: 1.0, green: 0.78, blue: 0.20, alpha: 1))
    let path = CGMutablePath()
    let turns = 2.15
    let steps = 260
    for i in 0...steps {
        let t = Double(i) / Double(steps)
        let angle: Double = t * turns * 2 * .pi - .pi / 2
        let r = radius * CGFloat(0.94 - 0.72 * t)
        let point = CGPoint(x: centre.x + CGFloat(cos(angle)) * r, y: centre.y + CGFloat(sin(angle)) * r)
        if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    context.addPath(path)
    context.strokePath()

    // Marker dot where the trace ends.
    let endAngle: Double = turns * 2 * .pi - .pi / 2
    let endRadius = radius * 0.22
    let end = CGPoint(x: centre.x + CGFloat(cos(endAngle)) * endRadius, y: centre.y + CGFloat(sin(endAngle)) * endRadius)
    context.setFillColor(CGColor(red: 1, green: 0.95, blue: 0.6, alpha: 1))
    context.fillEllipse(in: CGRect(x: end.x - size * 0.022, y: end.y - size * 0.022,
                                   width: size * 0.044, height: size * 0.044))

    // Soft top-down sheen, no hard edge.
    if let sheen = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [CGColor(gray: 1, alpha: 0.10), CGColor(gray: 1, alpha: 0)] as CFArray,
                              locations: [0, 1]) {
        context.drawLinearGradient(sheen,
                                   start: CGPoint(x: rect.midX, y: rect.maxY),
                                   end: CGPoint(x: rect.midX, y: rect.minY),
                                   options: [])
    }

    context.restoreGState()

    // Border.
    context.addPath(body)
    context.setLineWidth(max(1, size * 0.004))
    context.setStrokeColor(CGColor(gray: 1, alpha: 0.12))
    context.strokePath()

    image.unlockFocus()
    return image
}

func writePNG(_ image: NSImage, to path: String) {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: URL(fileURLWithPath: path))
}

let variants: [(String, CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]

for (name, size) in variants {
    writePNG(drawIcon(size: size), to: "\(iconsetDirectory)/\(name).png")
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconsetDirectory, "-o", outputDirectory + "/AppIcon.icns"]
try? task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
