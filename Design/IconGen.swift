// IconGen.swift — draws the Watchdog "dog with eyeglasses" logo.
// Usage: swift IconGen.swift <color|mono> <size> <out.png>
// color = full app icon with squircle background; mono = black silhouette
// with punched-out glasses, for the template menubar icon.

import CoreGraphics
import ImageIO
import Foundation
import UniformTypeIdentifiers

let mode = CommandLine.arguments[1]
let size = CGFloat(Double(CommandLine.arguments[2])!)
let outPath = CommandLine.arguments[3]

let S = size / 1024.0 // all coordinates are authored on a 1024 canvas
let ctx = CGContext(data: nil, width: Int(size), height: Int(size),
                    bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.scaleBy(x: S, y: S)
// Flip so y grows downward (design coordinates).
ctx.translateBy(x: 0, y: 1024)
ctx.scaleBy(x: 1, y: -1)

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func ellipse(cx: CGFloat, cy: CGFloat, w: CGFloat, h: CGFloat, rot: CGFloat = 0,
             color: CGColor, blend: CGBlendMode = .normal) {
    ctx.saveGState()
    ctx.setBlendMode(blend)
    ctx.translateBy(x: cx, y: cy)
    ctx.rotate(by: rot * .pi / 180)
    ctx.setFillColor(color)
    ctx.fillEllipse(in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
    ctx.restoreGState()
}

let ink = rgb(0x000000)

// MARK: background (color mode only)
if mode == "color" {
    let r: CGFloat = 229 // Apple-ish squircle corner radius at 1024
    let bg = CGPath(roundedRect: CGRect(x: 0, y: 0, width: 1024, height: 1024),
                    cornerWidth: r, cornerHeight: r, transform: nil)
    ctx.addPath(bg)
    ctx.clip()
    let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                          colors: [rgb(0x3F72AF), rgb(0x16283F)] as CFArray,
                          locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 512, y: 0),
                           end: CGPoint(x: 512, y: 1024), options: [])
}

let fur = mode == "color" ? rgb(0xD9A066) : ink
let earFur = mode == "color" ? rgb(0x8C5A2B) : ink

// MARK: floppy ears (behind the head)
ellipse(cx: 250, cy: 380, w: 200, h: 330, rot: 24, color: earFur)
ellipse(cx: 774, cy: 380, w: 200, h: 330, rot: -24, color: earFur)

// MARK: head
ellipse(cx: 512, cy: 540, w: 620, h: 600, color: fur)

if mode == "color" {
    // muzzle, nose, mouth
    ellipse(cx: 512, cy: 700, w: 320, h: 230, color: rgb(0xF2D0A4))
    ellipse(cx: 512, cy: 655, w: 110, h: 80, color: rgb(0x3B2B20))
    ctx.setStrokeColor(rgb(0x3B2B20))
    ctx.setLineWidth(16)
    ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: 512, y: 695))
    ctx.addLine(to: CGPoint(x: 512, y: 740))
    ctx.strokePath()
    ctx.addArc(center: CGPoint(x: 468, y: 742), radius: 44,
               startAngle: 0, endAngle: .pi * 0.9, clockwise: false)
    ctx.strokePath()
    ctx.addArc(center: CGPoint(x: 556, y: 742), radius: 44,
               startAngle: .pi * 0.1, endAngle: .pi, clockwise: false)
    ctx.strokePath()
    // eyes behind the lenses
    ellipse(cx: 392, cy: 488, w: 76, h: 76, color: rgb(0x2B2118))
    ellipse(cx: 632, cy: 488, w: 76, h: 76, color: rgb(0x2B2118))
    ellipse(cx: 406, cy: 473, w: 24, h: 24, color: rgb(0xFFFFFF, 0.9))
    ellipse(cx: 646, cy: 473, w: 24, h: 24, color: rgb(0xFFFFFF, 0.9))
}

// MARK: eyeglasses — the hero element
// mono mode punches them out of the silhouette so the template icon reads.
let glassBlend: CGBlendMode = mode == "mono" ? .clear : .normal
let frame = mode == "color" ? rgb(0x1E1E24) : ink
let lensW: CGFloat = mode == "mono" ? 44 : 34

ctx.saveGState()
ctx.setBlendMode(glassBlend)
ctx.setStrokeColor(frame)
ctx.setLineWidth(lensW)
ctx.setLineCap(.round)
// lenses (separated, bridge between)
ctx.strokeEllipse(in: CGRect(x: 392 - 112, y: 488 - 112, width: 224, height: 224))
ctx.strokeEllipse(in: CGRect(x: 632 - 112, y: 488 - 112, width: 224, height: 224))
// bridge across the top inner edges
ctx.move(to: CGPoint(x: 392 + 98, y: 442))
ctx.addQuadCurve(to: CGPoint(x: 632 - 98, y: 442), control: CGPoint(x: 512, y: 414))
ctx.strokePath()
// temples out to the head edge
ctx.move(to: CGPoint(x: 392 - 110, y: 466))
ctx.addLine(to: CGPoint(x: 216, y: 436))
ctx.move(to: CGPoint(x: 632 + 110, y: 466))
ctx.addLine(to: CGPoint(x: 808, y: 436))
ctx.strokePath()
if mode == "color" {
    // faint lens glass
    ellipse(cx: 392, cy: 488, w: 202, h: 202, color: rgb(0xFFFFFF, 0.10))
    ellipse(cx: 632, cy: 488, w: 202, h: 202, color: rgb(0xFFFFFF, 0.10))
}
ctx.restoreGState()

let img = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: outPath) as CFURL,
                                           UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, img, nil)
CGImageDestinationFinalize(dest)
print("wrote \(outPath)")
