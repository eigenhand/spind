#!/usr/bin/env swift
//
// Zeichnet das Spind-App-Symbol — ein weißer Spind auf schwarzem Grund — und
// schreibt alle PNG-Größen in die beiden Asset-Kataloge.
//
//   swift scripts/make-appicon.swift
//
// Der Spind steht als Quader im Raum: 30° um die Hochachse gedreht, dazu eine
// leichte Neigung, sodass Front, linke Seite und Deckel sichtbar sind. Alles
// ist vektorbasiert und wird für jede Kantenlänge neu gerastert, damit auch
// 16×16 scharf bleibt.

import AppKit

// MARK: - Pfad-Helfer

/// Rechteck mit stetig gekrümmten Ecken — gerade Kanten, Ecken als Viertel einer
/// Superellipse. Nähert die Squircle-Form der macOS-Symbole an.
func squircle(in r: CGRect, radiusRatio: CGFloat = 0.27, exponent: CGFloat = 4.5) -> CGPath {
    let radius = min(r.width, r.height) * radiusRatio
    let e = 2 / exponent
    let steps = 96

    let up = CGVector(dx: 0, dy: -1), down = CGVector(dx: 0, dy: 1)
    let left = CGVector(dx: -1, dy: 0), right = CGVector(dx: 1, dy: 0)

    // Je Ecke: Mittelpunkt des Eckquadrats sowie Anfangs- und Endrichtung. Die
    // Kurve läuft im Uhrzeigersinn von einer Kante zur nächsten.
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

/// Konvexe Hülle nach Andrew — liefert den Umriss des projizierten Quaders.
func convexHull(_ points: [CGPoint]) -> [CGPoint] {
    let sorted = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
    func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
    }
    func chain(_ points: [CGPoint]) -> [CGPoint] {
        var result: [CGPoint] = []
        for point in points {
            while result.count >= 2, cross(result[result.count - 2], result[result.count - 1], point) <= 0 {
                result.removeLast()
            }
            result.append(point)
        }
        result.removeLast()
        return result
    }
    return chain(sorted) + chain(sorted.reversed())
}

/// Polygon mit gebrochenen Ecken. Der Radius wird je Ecke auf die halbe Länge
/// der angrenzenden Kanten begrenzt, damit kurze Kanten nicht ausbrechen.
func roundedPolygon(_ points: [CGPoint], radius: CGFloat) -> CGPath {
    let path = CGMutablePath()
    guard points.count >= 3 else { return path }

    func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }
    func length(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(b.x - a.x, b.y - a.y)
    }

    path.move(to: midpoint(points[points.count - 1], points[0]))
    for index in points.indices {
        let previous = points[(index + points.count - 1) % points.count]
        let corner = points[index]
        let next = points[(index + 1) % points.count]
        let limit = min(length(previous, corner), length(corner, next)) / 2
        path.addArc(
            tangent1End: corner,
            tangent2End: midpoint(corner, next),
            radius: min(radius, limit)
        )
    }
    path.closeSubpath()
    return path
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

    // `plate` ist der schwarze Grund, `content` das Quadrat, auf das sich die
    // Maße des Spinds beziehen. Auf dem Mac fallen beide zusammen; auf iOS geht
    // der Grund randlos bis zur Kante, der Spind bleibt aber gleich groß.
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
        let side = (size * 0.86).rounded()
        content = CGRect(x: (size - side) / 2, y: (size - side) / 2, width: side, height: side)
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

    // MARK: Quader im Raum

    // Unter 32 px reicht die Auflösung für die Türfuge nicht mehr — dort steht
    // ein Spind ohne Fuge, mit gröberen Schlitzen und größerem Griff.
    let compact = size <= 32

    let s = content.width
    let halfWidth: CGFloat = 0.23, halfHeight: CGFloat = 0.325, halfDepth: CGFloat = 0.125
    let yaw = 30 * CGFloat.pi / 180  // Drehung um die Hochachse
    let pitch = 9 * CGFloat.pi / 180  // Neigung, damit der Deckel sichtbar wird

    /// Parallelprojektion: erst um die Hoch-, dann um die Querachse drehen. Der
    /// Blick liegt leicht über dem Spind, näher Liegendes rutscht also nach unten.
    func project(_ x: CGFloat, _ y: CGFloat, _ z: CGFloat) -> CGPoint {
        let rx = x * cos(yaw) + z * sin(yaw)
        let rz = -x * sin(yaw) + z * cos(yaw)
        let ry = y * cos(pitch) + rz * sin(pitch)
        return CGPoint(x: content.midX + rx * s, y: content.midY + ry * s)
    }

    func quad(_ corners: [(CGFloat, CGFloat, CGFloat)]) -> CGPath {
        let path = CGMutablePath()
        path.addLines(between: corners.map { project($0.0, $0.1, $0.2) })
        path.closeSubpath()
        return path
    }

    let (w, h, d) = (halfWidth, halfHeight, halfDepth)
    var vertices: [CGPoint] = []
    for sx in [-w, w] {
        for sy in [-h, h] {
            for sz in [-d, d] { vertices.append(project(sx, sy, sz)) }
        }
    }
    let silhouette = roundedPolygon(convexHull(vertices), radius: 0.020 * s)

    // Der ganze Umriss zuerst in Weiß, danach die abgewandten Flächen dunkler
    // darüber. So bleiben außen die gebrochenen Ecken, innen scharfe Kanten.
    ctx.saveGState()
    ctx.addPath(silhouette)
    ctx.clip()

    ctx.setFillColor(CGColor(gray: 1.00, alpha: 1))
    ctx.fill(content.insetBy(dx: -s, dy: -s))

    ctx.setFillColor(CGColor(gray: 0.42, alpha: 1))
    ctx.addPath(quad([(-w, -h, -d), (-w, -h, d), (-w, h, d), (-w, h, -d)]))  // linke Seite
    ctx.fillPath()

    ctx.setFillColor(CGColor(gray: 0.70, alpha: 1))
    ctx.addPath(quad([(-w, -h, -d), (w, -h, -d), (w, -h, d), (-w, -h, d)]))  // Deckel
    ctx.fillPath()

    // MARK: Tür auf der Frontfläche

    // Die Projektion einer Ebene ist affin — deshalb genügt ein
    // CGAffineTransform, um flach gezeichnete Pfade auf die Front zu legen.
    let faceOrigin = project(0, 0, d)
    let faceX = project(1, 0, d)
    let faceY = project(0, 1, d)
    let toFace = CGAffineTransform(
        a: faceX.x - faceOrigin.x, b: faceX.y - faceOrigin.y,
        c: faceY.x - faceOrigin.x, d: faceY.y - faceOrigin.y,
        tx: faceOrigin.x, ty: faceOrigin.y
    )

    /// Aussparungen werden mit demselben Verlauf übermalt, damit der Hintergrund
    /// exakt durchscheint.
    func knockOut(_ path: CGPath, rule: CGPathFillRule = .winding) {
        var transform = toFace
        guard let projected = path.copy(using: &transform) else { return }
        ctx.saveGState()
        ctx.addPath(projected)
        ctx.clip(using: rule)
        paintBackground()
        ctx.restoreGState()
    }

    // Türfuge — ein schmaler Ring, der den Korpus von der Tür trennt.
    let frame: CGFloat = 0.035
    let door = CGRect(x: -w + frame, y: -h + frame, width: 2 * (w - frame), height: 2 * (h - frame))
    if !compact {
        let seam = CGMutablePath()
        seam.addPath(roundedRect(door, radius: 0.030))
        seam.addPath(roundedRect(door.insetBy(dx: 0.013, dy: 0.013), radius: 0.022))
        knockOut(seam, rule: .evenOdd)
    }

    // Lüftungsschlitze und Griff.
    let details = CGMutablePath()
    let ventHeight: CGFloat = compact ? 0.036 : 0.026
    let ventWidth: CGFloat = compact ? 0.150 : 0.125
    let ventGap: CGFloat = compact ? 0.026 : 0.019
    for row in 0..<3 {
        let top = door.minY + 0.065 + CGFloat(row) * (ventHeight + ventGap)
        let slit = CGRect(x: -ventWidth, y: top, width: 2 * ventWidth, height: ventHeight)
        details.addPath(roundedRect(slit, radius: ventHeight / 2))
    }
    let handle = compact
        ? CGRect(x: 0.120, y: 0.045, width: 0.034, height: 0.105)
        : CGRect(x: 0.130, y: 0.010, width: 0.024, height: 0.090)
    details.addPath(roundedRect(handle, radius: handle.width / 2))
    knockOut(details)

    ctx.restoreGState()

    // Hauchdünner Rand, damit die Kante auf dunklem Untergrund nicht verschwindet.
    if platform == .mac {
        let width = max(1, size * 0.004)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.10))
        ctx.setLineWidth(width)
        ctx.addPath(squircle(in: plate.insetBy(dx: width / 2, dy: width / 2)))
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
