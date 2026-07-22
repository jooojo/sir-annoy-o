import AppKit
import SwiftUI

struct StatusBarIcon: View {
    let isPlaying: Bool

    var body: some View {
        Image(nsImage: isPlaying ? StatusBarHornImage.playing : StatusBarHornImage.idle)
            .renderingMode(.template)
            .resizable()
            .interpolation(.high)
            .frame(width: 18, height: 18)
            .accessibilityLabel("AnnoyO")
    }
}

private enum StatusBarHornImage {
    static let idle = makeImage(isPlaying: false)
    static let playing = makeImage(isPlaying: true)

    private static func makeImage(isPlaying: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let ink = NSColor.black

            let tubing = NSBezierPath()
            tubing.move(to: NSPoint(x: 2.0, y: 9.8))
            tubing.line(to: NSPoint(x: 7.2, y: 9.8))
            tubing.curve(
                to: NSPoint(x: 10.0, y: 7.4),
                controlPoint1: NSPoint(x: 9.0, y: 9.8),
                controlPoint2: NSPoint(x: 10.0, y: 8.9)
            )
            tubing.curve(
                to: NSPoint(x: 7.3, y: 4.8),
                controlPoint1: NSPoint(x: 10.0, y: 5.8),
                controlPoint2: NSPoint(x: 8.9, y: 4.8)
            )
            tubing.line(to: NSPoint(x: 6.2, y: 4.8))
            tubing.curve(
                to: NSPoint(x: 3.8, y: 7.0),
                controlPoint1: NSPoint(x: 4.7, y: 4.8),
                controlPoint2: NSPoint(x: 3.8, y: 5.7)
            )
            tubing.curve(
                to: NSPoint(x: 6.0, y: 8.8),
                controlPoint1: NSPoint(x: 3.8, y: 8.1),
                controlPoint2: NSPoint(x: 4.6, y: 8.8)
            )
            tubing.line(to: NSPoint(x: 11.0, y: 8.8))
            tubing.lineWidth = isPlaying ? 1.7 : 1.5
            tubing.lineCapStyle = .round
            tubing.lineJoinStyle = .round
            ink.setStroke()
            tubing.stroke()

            ink.setFill()
            NSBezierPath(
                roundedRect: NSRect(x: 0.9, y: 9.05, width: 2.6, height: 1.5),
                xRadius: 0.75,
                yRadius: 0.75
            ).fill()

            let bell = NSBezierPath()
            bell.move(to: NSPoint(x: 10.2, y: 10.65))
            bell.curve(
                to: NSPoint(x: 15.1, y: 13.0),
                controlPoint1: NSPoint(x: 12.0, y: 10.8),
                controlPoint2: NSPoint(x: 13.6, y: 11.65)
            )
            bell.curve(
                to: NSPoint(x: 16.0, y: 12.3),
                controlPoint1: NSPoint(x: 15.65, y: 13.4),
                controlPoint2: NSPoint(x: 16.0, y: 13.0)
            )
            bell.line(to: NSPoint(x: 16.0, y: 7.1))
            bell.curve(
                to: NSPoint(x: 15.1, y: 6.45),
                controlPoint1: NSPoint(x: 16.0, y: 6.4),
                controlPoint2: NSPoint(x: 15.65, y: 6.05)
            )
            bell.curve(
                to: NSPoint(x: 10.2, y: 8.75),
                controlPoint1: NSPoint(x: 13.6, y: 7.8),
                controlPoint2: NSPoint(x: 12.0, y: 8.6)
            )
            bell.close()
            bell.fill()

            if isPlaying {
                let sound = NSBezierPath()
                sound.move(to: NSPoint(x: 16.65, y: 12.05))
                sound.line(to: NSPoint(x: 17.55, y: 12.75))
                sound.move(to: NSPoint(x: 16.8, y: 9.7))
                sound.line(to: NSPoint(x: 17.75, y: 9.7))
                sound.move(to: NSPoint(x: 16.65, y: 7.35))
                sound.line(to: NSPoint(x: 17.55, y: 6.65))
                sound.lineWidth = 1.05
                sound.lineCapStyle = .round
                sound.stroke()
            }

            return true
        }
        image.isTemplate = true
        return image
    }
}
