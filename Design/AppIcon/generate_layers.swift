#!/usr/bin/env swift
import AppKit
import CoreImage
import CoreText

// MARK: - Editable artwork specification

// Icon Composer handles the keycap material, rounded mask, refraction, highlights,
// and shadow. These source layers contain only the two backlit legends.
private let canvasSize: CGFloat = 1_024

private struct TextLegendSpec {
    var text = "Ctrl-Say"
    var fontSize: CGFloat = 108
    var weight: NSFont.Weight = .medium

    // Core Graphics uses a bottom-left origin. This places the legend near the
    // lower-left of the 1024-point Icon Composer canvas.
    var origin = CGPoint(x: 120, y: 154)
}

private struct VoiceLegendSpec {
    // Core Graphics uses a bottom-left origin. Each wave is a true circular arc,
    // not a hand-tuned Bézier curve, so it can't collapse into a V shape.
    var center = CGPoint(x: 766, y: 786)
    var emitterWidth: CGFloat = 14
    var emitterHeight: CGFloat = 30
    var waveThickness: CGFloat = 18
    var innerRadius: CGFloat = 54
    var middleRadius: CGFloat = 92
    var outerRadius: CGFloat = 130
    var arcHalfAngleDegrees: CGFloat = 53
}

private let textSpec = TextLegendSpec()
private let voiceSpec = VoiceLegendSpec()

// MARK: - SVG generation

private func number(_ value: CGFloat) -> String {
    String(format: "%.3f", Double(value))
}

private func svgPathData(from path: CGPath) -> String {
    var commands: [String] = []

    path.applyWithBlock { elementPointer in
        let element = elementPointer.pointee
        switch element.type {
        case .moveToPoint:
            let point = element.points[0]
            commands.append("M \(number(point.x)) \(number(point.y))")
        case .addLineToPoint:
            let point = element.points[0]
            commands.append("L \(number(point.x)) \(number(point.y))")
        case .addQuadCurveToPoint:
            let control = element.points[0]
            let end = element.points[1]
            commands.append(
                "Q \(number(control.x)) \(number(control.y)) "
                    + "\(number(end.x)) \(number(end.y))"
            )
        case .addCurveToPoint:
            let control1 = element.points[0]
            let control2 = element.points[1]
            let end = element.points[2]
            commands.append(
                "C \(number(control1.x)) \(number(control1.y)) "
                    + "\(number(control2.x)) \(number(control2.y)) "
                    + "\(number(end.x)) \(number(end.y))"
            )
        case .closeSubpath:
            commands.append("Z")
        @unknown default:
            break
        }
    }

    return commands.joined(separator: " ")
}

private func textOutlinePath(for spec: TextLegendSpec) -> CGPath {
    let font = NSFont.systemFont(ofSize: spec.fontSize, weight: spec.weight)
    let attributedText = NSAttributedString(
        string: spec.text,
        attributes: [.font: font]
    )
    let line = CTLineCreateWithAttributedString(attributedText)
    let combinedPath = CGMutablePath()

    let runs = CTLineGetGlyphRuns(line) as! [CTRun]
    for run in runs {
        let glyphCount = CTRunGetGlyphCount(run)
        guard glyphCount > 0 else { continue }

        var glyphs = Array(repeating: CGGlyph(), count: glyphCount)
        var positions = Array(repeating: CGPoint.zero, count: glyphCount)
        CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
        CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)

        let attributes = CTRunGetAttributes(run) as NSDictionary
        let runFont = attributes[kCTFontAttributeName] as! CTFont

        for index in 0..<glyphCount {
            guard let glyphPath = CTFontCreatePathForGlyph(runFont, glyphs[index], nil) else {
                continue
            }

            let transform = CGAffineTransform(
                translationX: spec.origin.x + positions[index].x,
                y: spec.origin.y + positions[index].y
            )
            combinedPath.addPath(glyphPath, transform: transform)
        }
    }

    return combinedPath
}

private func voiceOutlinePath(for spec: VoiceLegendSpec) -> CGPath {
    let combinedPath = CGMutablePath()
    let emitterBounds = CGRect(
        x: spec.center.x - spec.emitterWidth / 2,
        y: spec.center.y - spec.emitterHeight / 2,
        width: spec.emitterWidth,
        height: spec.emitterHeight
    )
    combinedPath.addRoundedRect(
        in: emitterBounds,
        cornerWidth: spec.emitterWidth / 2,
        cornerHeight: spec.emitterWidth / 2
    )

    let halfAngle = spec.arcHalfAngleDegrees * .pi / 180
    for radius in [spec.innerRadius, spec.middleRadius, spec.outerRadius] {
        let centerline = CGMutablePath()
        centerline.addArc(
            center: spec.center,
            radius: radius,
            startAngle: -halfAngle,
            endAngle: halfAngle,
            clockwise: false
        )
        let outlinedArc = centerline.copy(
            strokingWithWidth: spec.waveThickness,
            lineCap: .round,
            lineJoin: .round,
            miterLimit: 10
        )
        combinedPath.addPath(outlinedArc)
    }

    return combinedPath
}

private func textLayerSVG(spec: TextLegendSpec) -> String {
    let pathData = svgPathData(from: textOutlinePath(for: spec))
    return """
        <?xml version="1.0" encoding="UTF-8"?>
        <svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
          <title>Ctrl-Say backlit key legend</title>
          <g transform="translate(0 1024) scale(1 -1)">
            <path d="\(pathData)" fill="#FFFFFF"/>
          </g>
        </svg>
        """
}

private func voiceLayerSVG(spec: VoiceLegendSpec) -> String {
    let pathData = svgPathData(from: voiceOutlinePath(for: spec))
    return """
        <?xml version="1.0" encoding="UTF-8"?>
        <svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
          <title>Ctrl-Say listening mark</title>
          <g transform="translate(0 1024) scale(1 -1)">
            <path d="\(pathData)" fill="#FFFFFF"/>
          </g>
        </svg>
        """
}

private func glowPNGData(for path: CGPath) throws -> Data {
    let pixelSize = Int(canvasSize)
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    guard
        let bitmapContext = CGContext(
            data: nil,
            width: pixelSize,
            height: pixelSize,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    else {
        throw NSError(domain: "CtrlSayIcon", code: 1)
    }

    bitmapContext.setFillColor(NSColor.white.cgColor)
    bitmapContext.addPath(path)
    bitmapContext.fillPath()

    guard let sourceImage = bitmapContext.makeImage() else {
        throw NSError(domain: "CtrlSayIcon", code: 2)
    }

    let source = CIImage(cgImage: sourceImage)
    guard
        let blur = CIFilter(name: "CIGaussianBlur"),
        let colorMatrix = CIFilter(name: "CIColorMatrix")
    else {
        throw NSError(domain: "CtrlSayIcon", code: 3)
    }

    blur.setValue(source, forKey: kCIInputImageKey)
    blur.setValue(12.0, forKey: kCIInputRadiusKey)
    guard let blurred = blur.outputImage?.cropped(to: source.extent) else {
        throw NSError(domain: "CtrlSayIcon", code: 4)
    }

    colorMatrix.setValue(blurred, forKey: kCIInputImageKey)
    colorMatrix.setValue(CIVector(x: 1, y: 0, z: 0, w: 0), forKey: "inputRVector")
    colorMatrix.setValue(CIVector(x: 0, y: 1, z: 0, w: 0), forKey: "inputGVector")
    colorMatrix.setValue(CIVector(x: 0, y: 0, z: 1, w: 0), forKey: "inputBVector")
    colorMatrix.setValue(CIVector(x: 0, y: 0, z: 0, w: 0.64), forKey: "inputAVector")

    guard let glow = colorMatrix.outputImage?.cropped(to: source.extent) else {
        throw NSError(domain: "CtrlSayIcon", code: 5)
    }

    let context = CIContext(options: [.cacheIntermediates: false])
    guard
        let data = context.pngRepresentation(
            of: glow,
            format: .RGBA8,
            colorSpace: colorSpace,
            options: [:]
        )
    else {
        throw NSError(domain: "CtrlSayIcon", code: 6)
    }

    return data
}

private let scriptDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
private let outputDirectory = scriptDirectory.appendingPathComponent("Layers", isDirectory: true)
try FileManager.default.createDirectory(
    at: outputDirectory,
    withIntermediateDirectories: true
)

let textGlowURL = outputDirectory.appendingPathComponent("01-Ctrl-Say-Glow.png")
let textLayerURL = outputDirectory.appendingPathComponent("02-Ctrl-Say-Legend.svg")
let voiceGlowURL = outputDirectory.appendingPathComponent("03-Listening-Glow.png")
let voiceLayerURL = outputDirectory.appendingPathComponent("04-Listening-Mark.svg")

try textLayerSVG(spec: textSpec).write(to: textLayerURL, atomically: true, encoding: .utf8)
try voiceLayerSVG(spec: voiceSpec).write(to: voiceLayerURL, atomically: true, encoding: .utf8)
try glowPNGData(for: textOutlinePath(for: textSpec)).write(to: textGlowURL, options: .atomic)
try glowPNGData(for: voiceOutlinePath(for: voiceSpec)).write(to: voiceGlowURL, options: .atomic)

print("Generated:")
print(textGlowURL.path)
print(textLayerURL.path)
print(voiceGlowURL.path)
print(voiceLayerURL.path)
