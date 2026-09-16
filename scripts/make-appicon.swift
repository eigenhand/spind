#!/usr/bin/env swift
//
// Draws the Spind app icon and writes every PNG size into the two asset
// catalogues.
//
//   swift scripts/make-appicon.swift
//
// House style, shared with the other apps (Fundus, PerBu): a flat mark in
// slate on an almost white ground, no perspective, no shadow, a generous
// margin. Outer contour 40/1024, inner marks 18/1024. Everything is vector
// based and rasterised afresh for each edge length, so 16x16 stays crisp.

import AppKit

// MARK: - Path helpers

/// A rectangle with continuously curved corners: straight edges, each
/// corner a quarter superellipse — the squircle of the macOS icons.
func squircle(in r: CGRect, radiusRatio: CGFloat = 0.27, exponent: CGFloat = 4.5) -> CGPath {
    let radius = min(r.width, r.height) * radiusRatio
    let e = 2 / exponent
    let steps = 96

    let up = CGVector(dx: 0, dy: -1), down = CGVector(dx: 0, dy: 1)
    let left = CGVector(dx: -1, dy: 0), right = CGVector(dx: 1, dy: 0)

    // Per corner: the centre of the corner square plus the entering and
    // leaving direction. The curve runs clockwise from edge to edge.
    let corners: [(CGPoint, CGVector, CGVector)] = [
        (CGPoint(x: r.maxX - radius, y: r.minY + radius), up, right),  // oben rechts
        (CGPoint(x: r.maxX - radius, y: r.maxY - radius), right, down),  // unten rechts
        (CGPoint(x: r.minX + radius, y: r.maxY - radius), down, left),  // unten links
        (CGPoint(x: r.minX + radius, y: r.minY + radius), left, up),  // oben links
    ]

    let path = CGMutablePath()
    for (index, corner) in corners.enumerated() {
        let (center, from, to) = corner
        for step in 0...steps {
            let t = CGFloat(step) / CGFloat(steps) * .pi / 2
            let a = pow(cos(t), e), b = pow(sin(t), e)
            let point = CGPoint(
                x: center.x + radius * (from.dx * a + to.dx * b),
                y: center.y + radius * (from.dy * a + to.dy * b)
            )
            if index == 0 && step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
    }
    path.closeSubpath()
    return path
}

func roundedRect(_ r: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// MARK: - Drawing

enum Platform {
    case mac  // its own squircle, with a margin all round
    case iOS  // full bleed, the system masks it itself
}

/// Share of the edge length the tile takes up on the Mac.
let macPlateRatio: CGFloat = 824.0 / 1024.0

/// iOS 18 asks for three versions of an app icon. Light is the one that
/// matters; dark and tinted are drawn on a transparent ground, because the
/// system puts its own backdrop behind them.
enum Theme {
    case light, dark, tinted
}

/// The slate of the other apps, sampled from their icons: #374559.
let slate = CGColor(red: 55 / 255, green: 69 / 255, blue: 89 / 255, alpha: 1)

func markColor(_ theme: Theme) -> CGColor {
    switch theme {
    case .light: return slate
    case .dark: return CGColor(red: 233 / 255, green: 236 / 255, blue: 242 / 255, alpha: 1)
    case .tinted: return CGColor(gray: 1, alpha: 1)
    }
}

func drawIcon(size: CGFloat, platform: Platform, theme: Theme = .light,
              into ctx: CGContext) {
    ctx.translateBy(x: 0, y: size)
    ctx.scaleBy(x: 1, y: -1)  // from here y grows downwards
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)

    // `plate` is the ground, `content` the square the locker is measured
    // against. On the Mac the two coincide; on iOS the ground runs to the
    // edge while the locker keeps its size.
    let plate: CGRect
    let plateShape: CGPath
    let content: CGRect
    switch platform {
    case .mac:
        let side = (size * macPlateRatio).rounded()
        plate = CGRect(x: (size - side) / 2, y: (size - side) / 2, width: side, height: side)
        plateShape = squircle(in: plate)
        content = plate
    case .iOS:
        plate = CGRect(x: 0, y: 0, width: size, height: size)
        plateShape = CGPath(rect: plate, transform: nil)
        content = plate
    }

    // The ground: almost white, with a barely visible diagonal gradient so
    // the tile has an edge on a light background without drawing a border.
    if theme == .light {
    ctx.saveGState()
    ctx.addPath(plateShape)
    ctx.clip()
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let gradient = CGGradient(
        colorsSpace: space,
        colors: [
            CGColor(red: 252 / 255, green: 252 / 255, blue: 253 / 255, alpha: 1),
            CGColor(red: 241 / 255, green: 243 / 255, blue: 247 / 255, alpha: 1),
        ] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: plate.minX, y: plate.minY),
        end: CGPoint(x: plate.maxX, y: plate.maxY),
        options: []
    )
    ctx.restoreGState()
    }

    let detail: Detail = size >= 256 ? .full : (size >= 64 ? .medium : .minimal)
    drawLocker(in: content, detail: detail, theme: theme, into: ctx)
}

/// How much detail a size can carry. Below a certain edge length the
/// contour and the door seam land on the same pixel and turn to mud, so
/// the small sizes get their own, blunter drawing — the way Apple's own
/// icons do.
enum Detail {
    case full     // body, door seam, vents, handle
    case medium   // body, vents, handle — the seam would blur
    case minimal  // a solid door: at 16 pixels an outline is grey soup
}

/// The locker, seen from the front: body, door, three vents, one handle.
/// Nothing else — at small sizes every extra line turns into mud.
func drawLocker(in content: CGRect, detail: Detail, theme: Theme,
                into ctx: CGContext) {
    let unit = content.width / 1024  // all measurements are for a 1024 canvas
    func u(_ value: CGFloat) -> CGFloat { value * unit }
    func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: content.minX + u(x), y: content.minY + u(y), width: u(w), height: u(h))
    }

    ctx.setStrokeColor(markColor(theme))
    ctx.setFillColor(markColor(theme))
    ctx.setLineJoin(.round)
    ctx.setLineCap(.round)

    if detail == .minimal {
        // Solid, and larger: what survives here is the silhouette, so it
        // may as well be a confident one. Vents and handle are punched out
        // of it rather than drawn on top.
        ctx.addPath(roundedRect(rect(196, 104, 632, 816), radius: u(96)))
        ctx.fillPath()
        ctx.setBlendMode(.clear)
        ctx.addPath(roundedRect(rect(360, 260, 304, 72), radius: u(36)))
        ctx.addPath(roundedRect(rect(628, 520, 64, 180), radius: u(32)))
        ctx.fillPath()
        ctx.setBlendMode(.normal)
        return
    }

    // Body: portrait, filling the frame as confidently as the other icons.
    let bodyStroke: CGFloat = detail == .full ? 40 : 56
    let body = rect(216, 124, 592, 776)
    ctx.setLineWidth(u(bodyStroke))
    ctx.addPath(roundedRect(body.insetBy(dx: u(bodyStroke / 2), dy: u(bodyStroke / 2)),
                            radius: u(56)))
    ctx.strokePath()

    // Door: a seam inside the body, or the shape would read as a crate.
    // The gap is as wide as the contour, so the two lines stay apart
    // instead of blurring into one thick edge.
    if detail == .full {
        let doorStroke: CGFloat = 18
        let door = rect(296, 204, 432, 616)
        ctx.setLineWidth(u(doorStroke))
        ctx.addPath(roundedRect(door.insetBy(dx: u(doorStroke / 2), dy: u(doorStroke / 2)),
                                radius: u(32)))
        ctx.strokePath()
    }

    // Vents in the upper third, solid like the marks in the other icons.
    let ventHeight: CGFloat = detail == .full ? 26 : 40
    let ventGap: CGFloat = detail == .full ? 52 : 66
    for row in 0..<3 {
        ctx.addPath(roundedRect(
            rect(427, 288 + CGFloat(row) * ventGap, 170, ventHeight),
            radius: u(ventHeight / 2)
        ))
    }
    ctx.fillPath()

    // Handle on the closing edge, at the height where a hand would grip.
    let handleWidth: CGFloat = detail == .full ? 26 : 40
    ctx.addPath(roundedRect(rect(640, 528, handleWidth, 132), radius: u(handleWidth / 2)))
    ctx.fillPath()
}

// MARK: - Ausgabe

func renderPNG(size: Int, platform: Platform, theme: Theme = .light) -> Data {
    let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    drawIcon(size: CGFloat(size), platform: platform, theme: theme, into: ctx)

    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("could not write PNG") }
    return data as Data
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let macSet = root.appendingPathComponent("Resources/Assets.xcassets/AppIcon.appiconset")
let iosSet = root.appendingPathComponent("Resources/AssetsMobile.xcassets/AppIcon.appiconset")

guard FileManager.default.fileExists(atPath: macSet.path) else {
    fatalError("Bitte aus dem Projektstammverzeichnis aufrufen")
}

// Several filenames share one pixel size (16@2x and 32@1x, for instance).
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

for (name, theme) in [("icon_1024.png", Theme.light),
                      ("icon_1024-dark.png", .dark),
                      ("icon_1024-tinted.png", .tinted)] {
    try renderPNG(size: 1024, platform: .iOS, theme: theme)
        .write(to: iosSet.appendingPathComponent(name))
    print("iOS    \(name) — 1024px")
}
