import AppKit
import Foundation

@main
@MainActor
enum IconGenerator {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw IconError.missingOutputDirectory
        }

        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let variants: [(name: String, pixels: Int)] = [
            ("icon_16x16.png", 16),
            ("icon_16x16@2x.png", 32),
            ("icon_32x32.png", 32),
            ("icon_32x32@2x.png", 64),
            ("icon_128x128.png", 128),
            ("icon_128x128@2x.png", 256),
            ("icon_256x256.png", 256),
            ("icon_256x256@2x.png", 512),
            ("icon_512x512.png", 512),
            ("icon_512x512@2x.png", 1024)
        ]

        for variant in variants {
            let data = try render(size: variant.pixels)
            try data.write(to: output.appendingPathComponent(variant.name), options: .atomic)
        }
    }

    private static func render(size: Int) throws -> Data {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: size,
            pixelsHigh: size,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw IconError.renderFailed
        }

        bitmap.size = NSSize(width: size, height: size)
        NSGraphicsContext.saveGraphicsState()
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            NSGraphicsContext.restoreGraphicsState()
            throw IconError.renderFailed
        }
        NSGraphicsContext.current = context

        let canvas = NSRect(x: 0, y: 0, width: size, height: size)
        NSColor.clear.setFill()
        canvas.fill()

        let inset = CGFloat(size) * 0.035
        let iconRect = canvas.insetBy(dx: inset, dy: inset)
        let background = NSBezierPath(
            roundedRect: iconRect,
            xRadius: CGFloat(size) * 0.225,
            yRadius: CGFloat(size) * 0.225
        )
        background.addClip()

        let gradient = NSGradient(colors: [
            NSColor(red: 0.23, green: 0.24, blue: 0.25, alpha: 1),
            NSColor(red: 0.12, green: 0.13, blue: 0.14, alpha: 1)
        ])!
        gradient.draw(in: iconRect, angle: -45)

        let glow = NSGradient(colors: [
            NSColor.white.withAlphaComponent(0.045),
            NSColor.white.withAlphaComponent(0)
        ])!
        glow.draw(in: NSBezierPath(ovalIn: NSRect(
            x: -CGFloat(size) * 0.15,
            y: CGFloat(size) * 0.45,
            width: CGFloat(size) * 0.9,
            height: CGFloat(size) * 0.75
        )), relativeCenterPosition: .zero)

        drawAnnoyOHorn(size: CGFloat(size), context: context)

        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw IconError.renderFailed
        }
        return png
    }

    private static func drawAnnoyOHorn(size: CGFloat, context: NSGraphicsContext) {
        let scale = size / 1024
        let ivory = NSColor(red: 0.957, green: 0.957, blue: 0.941, alpha: 1)
        let bellInterior = NSColor(red: 0.141, green: 0.145, blue: 0.165, alpha: 1)

        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: x * scale, y: (1024 - y) * scale)
        }

        NSGraphicsContext.saveGraphicsState()
        context.cgContext.translateBy(x: size / 2, y: size / 2)
        context.cgContext.rotate(by: 8 * .pi / 180)
        context.cgContext.translateBy(x: -size / 2, y: -size / 2)

        let tubing = NSBezierPath()
        tubing.move(to: point(207, 464))
        tubing.line(to: point(424, 464))
        tubing.curve(
            to: point(548, 580),
            controlPoint1: point(500, 464),
            controlPoint2: point(548, 510)
        )
        tubing.curve(
            to: point(429, 692),
            controlPoint1: point(548, 650),
            controlPoint2: point(500, 692)
        )
        tubing.line(to: point(390, 692))
        tubing.curve(
            to: point(269, 585),
            controlPoint1: point(317, 692),
            controlPoint2: point(269, 649)
        )
        tubing.curve(
            to: point(377, 490),
            controlPoint1: point(269, 526),
            controlPoint2: point(310, 490)
        )
        tubing.line(to: point(617, 490))
        tubing.lineWidth = 48 * scale
        tubing.lineCapStyle = .round
        tubing.lineJoinStyle = .round
        ivory.setStroke()
        tubing.stroke()

        ivory.setFill()
        NSBezierPath(
            roundedRect: NSRect(
                x: 149 * scale,
                y: (1024 - 488) * scale,
                width: 82 * scale,
                height: 48 * scale
            ),
            xRadius: 24 * scale,
            yRadius: 24 * scale
        ).fill()
        NSBezierPath(
            roundedRect: NSRect(
                x: 205 * scale,
                y: (1024 - 524) * scale,
                width: 45 * scale,
                height: 73 * scale
            ),
            xRadius: 22 * scale,
            yRadius: 22 * scale
        ).fill()

        let bell = NSBezierPath()
        bell.move(to: point(576, 447))
        bell.curve(
            to: point(824, 354),
            controlPoint1: point(669, 442),
            controlPoint2: point(745, 408)
        )
        bell.curve(
            to: point(864, 378),
            controlPoint1: point(844, 340),
            controlPoint2: point(864, 354)
        )
        bell.line(to: point(864, 610))
        bell.curve(
            to: point(824, 634),
            controlPoint1: point(864, 634),
            controlPoint2: point(844, 648)
        )
        bell.curve(
            to: point(576, 541),
            controlPoint1: point(745, 580),
            controlPoint2: point(669, 546)
        )
        bell.close()
        bell.fill()

        NSBezierPath(
            roundedRect: NSRect(
                x: 555 * scale,
                y: (1024 - 527) * scale,
                width: 75 * scale,
                height: 66 * scale
            ),
            xRadius: 31 * scale,
            yRadius: 31 * scale
        ).fill()
        NSBezierPath(
            roundedRect: NSRect(
                x: 574 * scale,
                y: (1024 - 549) * scale,
                width: 31 * scale,
                height: 111 * scale
            ),
            xRadius: 15 * scale,
            yRadius: 15 * scale
        ).fill()
        NSBezierPath(ovalIn: NSRect(
            x: 812 * scale,
            y: (1024 - 631) * scale,
            width: 76 * scale,
            height: 274 * scale
        )).fill()

        bellInterior.setFill()
        NSBezierPath(ovalIn: NSRect(
            x: 830 * scale,
            y: (1024 - 596) * scale,
            width: 40 * scale,
            height: 204 * scale
        )).fill()

        NSGraphicsContext.restoreGraphicsState()
    }
}

private enum IconError: Error {
    case missingOutputDirectory
    case renderFailed
}
