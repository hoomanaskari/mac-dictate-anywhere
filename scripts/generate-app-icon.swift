#!/usr/bin/env swift
//
// generate-app-icon.swift
//
// Regenerates every size in AppIcon.appiconset from the logo vector
// (taken from design.pen) and the accent color in
// Assets.xcassets/AccentColor.colorset — so after changing AccentColor
// in Xcode, run this to keep the app icon in sync:
//
//   swift scripts/generate-app-icon.swift
//
import AppKit
import CoreGraphics

// MARK: - Locate assets

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
let repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let assetsURL = repoRoot.appendingPathComponent("Dictate Anywhere/Assets.xcassets")
let iconSetURL = assetsURL.appendingPathComponent("AppIcon.appiconset")
let accentJSONURL = assetsURL.appendingPathComponent("AccentColor.colorset/Contents.json")

// MARK: - Read accent color from the asset catalog

struct AccentComponents {
    var red: CGFloat, green: CGFloat, blue: CGFloat
}

func readAccent() -> AccentComponents {
    func channel(_ any: Any?) -> CGFloat? {
        guard let s = any as? String else { return nil }
        if s.hasPrefix("0x"), let v = UInt8(s.dropFirst(2), radix: 16) {
            return CGFloat(v) / 255
        }
        if let d = Double(s) { return d > 1 ? CGFloat(d) / 255 : CGFloat(d) }
        return nil
    }
    guard
        let data = try? Data(contentsOf: accentJSONURL),
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let colors = json["colors"] as? [[String: Any]],
        let comp = (colors.first?["color"] as? [String: Any])?["components"] as? [String: Any],
        let r = channel(comp["red"]), let g = channel(comp["green"]), let b = channel(comp["blue"])
    else {
        fatalError("could not read \(accentJSONURL.path)")
    }
    return AccentComponents(red: r, green: g, blue: b)
}

let accent = readAccent()
let accentNSColor = NSColor(srgbRed: accent.red, green: accent.green, blue: accent.blue, alpha: 1)
var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0, alp: CGFloat = 0
accentNSColor.getHue(&hue, saturation: &sat, brightness: &bri, alpha: &alp)

func accentVariant(saturation s: CGFloat, brightness b: CGFloat, alpha: CGFloat = 1) -> CGColor {
    NSColor(
        hue: hue,
        saturation: min(sat * s, 1),
        brightness: min(bri * b, 1),
        alpha: alpha
    ).usingColorSpace(.sRGB)!.cgColor
}

// Same multipliers the app's DS.Colors uses, plus icon-specific tints.
let baseColor = accentNSColor.cgColor
let gradientTop = accentVariant(saturation: 0.90, brightness: 1.045)
let gradientDeep = accentVariant(saturation: 1.071, brightness: 0.883)
let glyphShadow = accentVariant(saturation: 1.1, brightness: 0.72, alpha: 0.45)

// MARK: - Logo path from design.pen (viewBox 0 0 206 206)

let geometry = "M9.3479 112.175c4.9584 0 9.7138-1.97 13.2199-5.476 3.5061-3.506 5.4759-8.2618 5.4759-13.2202v-37.3915c0-4.9584 1.9697-9.7138 5.4758-13.2199 3.5062-3.5061 8.2615-5.4759 13.2199-5.4759 4.9584 0 9.7138 1.9698 13.2199 5.4759 3.5062 3.5061 5.4759 8.2615 5.4759 13.2199v121.5227c0 4.958 1.9697 9.713 5.4758 13.22 3.5062 3.506 8.2615 5.475 13.2199 5.475 4.9585 0 9.7138-1.969 13.2199-5.475 3.5062-3.507 5.4762-8.262 5.4762-13.22v-149.5663c0-4.9585 1.969-9.7138 5.476-13.2199 3.506-3.5062 8.261-5.4759 13.219-5.4759 4.959 0 9.714 1.9697 13.22 5.4759 3.506 3.5061 5.476 8.2614 5.476 13.2199v121.5223c0 4.959 1.97 9.714 5.476 13.22 3.506 3.506 8.262 5.476 13.22 5.476 4.958 0 9.714-1.97 13.22-5.476 3.506-3.506 5.476-8.261 5.476-13.22v-37.391c0-4.959 1.969-9.714 5.476-13.2203 3.506-3.5062 8.261-5.4759 13.219-5.4759"

func parsePath(_ d: String) -> CGPath {
    let path = CGMutablePath()
    var numbers: [CGFloat] = []
    var command: Character = " "
    var current = CGPoint.zero
    var numberBuffer = ""

    func flushNumber() {
        if !numberBuffer.isEmpty, let v = Double(numberBuffer) {
            numbers.append(CGFloat(v))
        }
        numberBuffer = ""
    }

    func consume() {
        let isRelative = command.isLowercase
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            isRelative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
        }
        switch Character(command.lowercased()) {
        case "m":
            while numbers.count >= 2 {
                let p = pt(numbers.removeFirst(), numbers.removeFirst())
                if path.isEmpty || command == "M" || command == "m" {
                    path.move(to: p)
                    command = isRelative ? "l" : "L"
                } else {
                    path.addLine(to: p)
                }
                current = p
            }
        case "l":
            while numbers.count >= 2 {
                let p = pt(numbers.removeFirst(), numbers.removeFirst())
                path.addLine(to: p)
                current = p
            }
        case "h":
            while !numbers.isEmpty {
                let x = numbers.removeFirst()
                let p = isRelative ? CGPoint(x: current.x + x, y: current.y) : CGPoint(x: x, y: current.y)
                path.addLine(to: p)
                current = p
            }
        case "v":
            while !numbers.isEmpty {
                let y = numbers.removeFirst()
                let p = isRelative ? CGPoint(x: current.x, y: current.y + y) : CGPoint(x: current.x, y: y)
                path.addLine(to: p)
                current = p
            }
        case "c":
            while numbers.count >= 6 {
                let c1 = pt(numbers.removeFirst(), numbers.removeFirst())
                let c2 = pt(numbers.removeFirst(), numbers.removeFirst())
                let p = pt(numbers.removeFirst(), numbers.removeFirst())
                path.addCurve(to: p, control1: c1, control2: c2)
                current = p
            }
        case "z":
            path.closeSubpath()
        default:
            numbers.removeAll()
        }
    }

    for ch in d {
        if ch.isLetter {
            flushNumber()
            consume()
            command = ch
            if ch.lowercased() == "z" { consume() }
        } else if ch == "," || ch == " " {
            flushNumber()
        } else if ch == "-" {
            flushNumber()
            numberBuffer = "-"
        } else if ch == "." && numberBuffer.contains(".") {
            flushNumber()
            numberBuffer = "."
        } else {
            numberBuffer.append(ch)
        }
    }
    flushNumber()
    consume()
    return path
}

// MARK: - Render 1024 master

let canvas: CGFloat = 1024
let squircleSize: CGFloat = 824
let cornerRadius: CGFloat = 185.4
let inset = (canvas - squircleSize) / 2

guard let ctx = CGContext(
    data: nil, width: Int(canvas), height: Int(canvas),
    bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { fatalError("no context") }

let squircleRect = CGRect(x: inset, y: inset, width: squircleSize, height: squircleSize)
let squircle = CGPath(roundedRect: squircleRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 36, color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.30))
ctx.addPath(squircle)
ctx.setFillColor(baseColor)
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(squircle)
ctx.clip()
let gradient = CGGradient(
    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
    colors: [gradientTop, baseColor, gradientDeep] as CFArray,
    locations: [0.0, 0.45, 1.0]
)!
ctx.drawLinearGradient(
    gradient,
    start: CGPoint(x: canvas / 2, y: canvas - inset),
    end: CGPoint(x: canvas / 2, y: inset),
    options: []
)
let highlight = CGGradient(
    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
    colors: [
        CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.18),
        CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.0),
    ] as CFArray,
    locations: [0.0, 1.0]
)!
ctx.drawLinearGradient(
    highlight,
    start: CGPoint(x: canvas / 2, y: canvas - inset),
    end: CGPoint(x: canvas / 2, y: canvas - inset - 320),
    options: []
)
ctx.restoreGState()

let glyphBox: CGFloat = squircleSize * 0.55
let viewBox: CGFloat = 206
let scale = glyphBox / viewBox
let logo = parsePath(geometry)

ctx.saveGState()
ctx.translateBy(x: (canvas - glyphBox) / 2, y: (canvas + glyphBox) / 2)
ctx.scaleBy(x: scale, y: -scale)
ctx.setShadow(offset: CGSize(width: 0, height: -6 / scale), blur: 16 / scale, color: glyphShadow)
ctx.addPath(logo)
ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
ctx.setLineWidth(18.745)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.strokePath()
ctx.restoreGState()

guard let master = ctx.makeImage() else { fatalError("no image") }

// MARK: - Write every slot in the icon set

func writePNG(_ image: CGImage, size: Int, to url: URL) {
    let scaled = CGContext(
        data: nil, width: size, height: size,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    scaled.interpolationQuality = .high
    scaled.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    let rep = NSBitmapImageRep(cgImage: scaled.makeImage()!)
    rep.size = NSSize(width: size, height: size)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
    print("wrote \(url.lastPathComponent) (\(size)px)")
}

let slots: [(String, Int)] = [
    ("16.png", 16), ("32.png", 32), ("32 1.png", 32), ("64.png", 64),
    ("128.png", 128), ("256.png", 256), ("256 1.png", 256),
    ("512.png", 512), ("512 1.png", 512), ("1024.png", 1024),
]
for (name, size) in slots {
    writePNG(master, size: size, to: iconSetURL.appendingPathComponent(name))
}
print("done — accent \(String(format: "#%02X%02X%02X", Int(accent.red * 255), Int(accent.green * 255), Int(accent.blue * 255)))")
