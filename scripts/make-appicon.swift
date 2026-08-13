#!/usr/bin/env swift
//
// Zeichnet das Spind-App-Symbol — ein weißer Spind auf schwarzem Grund — und
// schreibt alle PNG-Größen in die beiden Asset-Kataloge.
//
//   swift scripts/make-appicon.swift
//
// Alles ist vektorbasiert und wird für jede Kantenlänge neu gerastert, damit
// auch 16×16 scharf bleibt.

import AppKit

// MARK: - Pfad-Helfer

/// Superellipse — nähert die Squircle-Form der macOS-Symbole an.
func squircle(in rect: CGRect, exponent: CGFloat = 5, samples: Int = 720) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let e = 2 / exponent
    for i in 0..<samples {
        let t = CGFloat(i) / CGFloat(samples) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = rect.midX + a * (c < 0 ? -1 : 1) * pow(abs(c), e)
        let y = rect.midY + b * (s < 0 ? -1 : 1) * pow(abs(s), e)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

/// Rechteck mit einzeln einstellbaren Ecken. Oben ist `minY` — der Kontext ist
/// gespiegelt, damit die Maße unten von oben nach unten gelesen werden können.
func roundedRect(_ r: CGRect, tl: CGFloat, tr: CGFloat, br: CGFloat, bl: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: r.minX + tl, y: r.minY))
    p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.maxY), radius: tr)
    p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.maxY), radius: br)
    p.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.minY), radius: bl)
    p.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.minY), radius: tl)
    p.closeSubpath()
    return p
}

func roundedRect(_ r: CGRect, radius: CGFloat) -> CGPath {
    roundedRect(r, tl: radius, tr: radius, br: radius, bl: radius)
}

// MARK: - Zeichnung

enum Platform {
    case mac  // eigene Squircle-Form, Rand ringsum
    case iOS  // randlos, das System maskiert selbst
}

/// Anteil der Kantenlänge, den die Symbolfläche auf dem Mac einnimmt.
let macPlateRatio: CGFloat = 824.0 / 1024.0

func drawIcon(size: CGFloat, platform: Platform, into ctx: CGContext) {
    ctx.translateBy(x: 0, y: size)
    ctx.scaleBy(x: 1, y: -1)  // ab hier wächst y nach unten
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)

    let plate: CGRect
    let plateShape: CGPath
    switch platform {
    case .mac:
        let side = (size * macPlateRatio).rounded()
        plate = CGRect(x: (size - side) / 2, y: (size - side) / 2, width: side, height: side)
        plateShape = squircle(in: plate)
    case .iOS:
        plate = CGRect(x: 0, y: 0, width: size, height: size)
        plateShape = CGPath(rect: plate, transform: nil)
    }

    // Hintergrund: schwarz, mit einem kaum sichtbaren Verlauf für etwas Tiefe.
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let gradient = CGGradient(
        colorsSpace: space,
        colors: [
            CGColor(srgbRed: 0.078, green: 0.078, blue: 0.086, alpha: 1),
            CGColor(srgbRed: 0.000, green: 0.000, blue: 0.000, alpha: 1),
        ] as CFArray,
        locations: [0, 1]
    )!
    func paintBackground() {
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: plate.midX, y: plate.minY),
            end: CGPoint(x: plate.midX, y: plate.maxY),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
    }

    ctx.saveGState()
    ctx.addPath(plateShape)
    ctx.clip()
    paintBackground()
    ctx.restoreGState()

    // Der Spind selbst, in Anteilen der Symbolfläche.
    let s = plate.width
    func x(_ f: CGFloat) -> CGFloat { plate.minX + f * s }
    func y(_ f: CGFloat) -> CGFloat { plate.minY + f * s }
    func box(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) -> CGRect {
        CGRect(x: x(x0), y: y(y0), width: (x1 - x0) * s, height: (y1 - y0) * s)
    }

    let body = box(0.25, 0.14, 0.75, 0.86)

    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.addPath(roundedRect(body, radius: 0.055 * s))
    ctx.fillPath()

    // Aussparungen: Lüftungsschlitze, Griff, Füße. Sie werden mit demselben
    // Verlauf übermalt, damit der Hintergrund exakt durchscheint.
    let cutouts = CGMutablePath()

    let ventHeight: CGFloat = 0.038
    for row in 0..<3 {
        let top = 0.225 + CGFloat(row) * (ventHeight + 0.032)
        cutouts.addPath(roundedRect(box(0.37, top, 0.63, top + ventHeight), radius: ventHeight * s / 2))
    }

    cutouts.addPath(roundedRect(box(0.653, 0.4625, 0.685, 0.5775), radius: 0.016 * s))

    // Füße: eine Kerbe in der Unterkante, die zwei kurze Beine stehen lässt.
    let notch = box(0.39, 0.815, 0.61, 0.875)
    cutouts.addPath(roundedRect(notch, tl: 0.022 * s, tr: 0.022 * s, br: 0, bl: 0))

    ctx.saveGState()
    ctx.addPath(cutouts)
    ctx.clip()
    paintBackground()
    ctx.restoreGState()

    // Hauchdünner Rand, damit die Kante auf dunklem Untergrund nicht verschwindet.
    if platform == .mac {
        let width = max(1, size * 0.004)
        let inset = plate.insetBy(dx: width / 2, dy: width / 2)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.10))
        ctx.setLineWidth(width)
        ctx.addPath(squircle(in: inset))
        ctx.strokePath()
    }
}

// MARK: - Ausgabe

func renderPNG(size: Int, platform: Platform) -> Data {
    let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    drawIcon(size: CGFloat(size), platform: platform, into: ctx)

    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("PNG konnte nicht geschrieben werden") }
    return data as Data
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let macSet = root.appendingPathComponent("Resources/Assets.xcassets/AppIcon.appiconset")
let iosSet = root.appendingPathComponent("Resources/AssetsMobile.xcassets/AppIcon.appiconset")

guard FileManager.default.fileExists(atPath: macSet.path) else {
    fatalError("Bitte aus dem Projektstammverzeichnis aufrufen")
}

// Mehrere Dateinamen teilen sich dieselbe Pixelgröße (z. B. 16@2x und 32@1x).
let macFiles: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

var cache: [Int: Data] = [:]
for (name, px) in macFiles {
    let png = cache[px] ?? renderPNG(size: px, platform: .mac)
    cache[px] = png
    try png.write(to: macSet.appendingPathComponent(name))
    print("macOS  \(name) — \(px)px")
}

try renderPNG(size: 1024, platform: .iOS).write(to: iosSet.appendingPathComponent("icon_1024.png"))
print("iOS    icon_1024.png — 1024px")
