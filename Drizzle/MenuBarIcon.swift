import AppKit

/// CodexBar menu-bar meters: two capsule bars, session on top and weekly underneath.
enum MenuBarIcon {
    private static let outputSize = NSSize(width: 18, height: 18)
    private static let outputScale: CGFloat = 2
    private static let canvasPx = 36

    static func image(sessionRemaining: Double?, weeklyRemaining: Double?, stale: Bool) -> NSImage {
        let image = self.render {
            let baseFill = NSColor.labelColor
            let trackFillAlpha: CGFloat = stale ? 0.18 : 0.28
            let trackStrokeAlpha: CGFloat = stale ? 0.28 : 0.44
            let fillColor = baseFill.withAlphaComponent(stale ? 0.55 : 1)
            let barWidthPx = 30
            let barXPx = (self.canvasPx - barWidthPx) / 2
            let top = RectPx(x: barXPx, y: 19, w: barWidthPx, h: 12)
            let bottom = RectPx(x: barXPx, y: 5, w: barWidthPx, h: 8)
            let prominent = RectPx(x: barXPx, y: 14, w: barWidthPx, h: 16)

            if let weeklyRemaining, weeklyRemaining > 0 {
                self.drawBar(
                    top,
                    remaining: sessionRemaining,
                    trackFillAlpha: trackFillAlpha,
                    trackStrokeAlpha: trackStrokeAlpha,
                    fillColor: fillColor)
                self.drawBar(
                    bottom,
                    remaining: weeklyRemaining,
                    trackFillAlpha: trackFillAlpha,
                    trackStrokeAlpha: trackStrokeAlpha,
                    fillColor: fillColor)
            } else if sessionRemaining == nil, let weeklyRemaining {
                self.drawBar(
                    prominent,
                    remaining: weeklyRemaining,
                    trackFillAlpha: trackFillAlpha,
                    trackStrokeAlpha: trackStrokeAlpha,
                    fillColor: fillColor)
            } else {
                self.drawBar(
                    prominent,
                    remaining: sessionRemaining,
                    trackFillAlpha: trackFillAlpha,
                    trackStrokeAlpha: trackStrokeAlpha,
                    fillColor: fillColor)
                if weeklyRemaining != nil {
                    self.drawBar(
                        RectPx(x: barXPx, y: 4, w: barWidthPx, h: 6),
                        remaining: weeklyRemaining,
                        trackFillAlpha: trackFillAlpha,
                        trackStrokeAlpha: trackStrokeAlpha,
                        fillColor: fillColor)
                }
            }
        }
        image.isTemplate = true
        return image
    }

    private struct RectPx {
        let x: Int
        let y: Int
        let w: Int
        let h: Int

        func rect() -> CGRect {
            CGRect(
                x: CGFloat(self.x) / outputScale,
                y: CGFloat(self.y) / outputScale,
                width: CGFloat(self.w) / outputScale,
                height: CGFloat(self.h) / outputScale)
        }
    }

    private static func drawBar(
        _ rectPx: RectPx,
        remaining: Double?,
        trackFillAlpha: CGFloat,
        trackStrokeAlpha: CGFloat,
        fillColor: NSColor)
    {
        let rect = rectPx.rect()
        let radius = CGFloat(rectPx.h) / 2 / self.outputScale
        let track = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        NSColor.labelColor.withAlphaComponent(trackFillAlpha).setFill()
        track.fill()

        let inset = 1
        let strokeRect = CGRect(
            x: CGFloat(rectPx.x + inset) / self.outputScale,
            y: CGFloat(rectPx.y + inset) / self.outputScale,
            width: CGFloat(max(0, rectPx.w - inset * 2)) / self.outputScale,
            height: CGFloat(max(0, rectPx.h - inset * 2)) / self.outputScale)
        let stroke = NSBezierPath(
            roundedRect: strokeRect,
            xRadius: max(0, radius - CGFloat(inset) / self.outputScale),
            yRadius: max(0, radius - CGFloat(inset) / self.outputScale))
        stroke.lineWidth = 1
        NSColor.labelColor.withAlphaComponent(trackStrokeAlpha).setStroke()
        stroke.stroke()

        if let remaining {
            let clamped = max(0, min(remaining / 100, 1))
            let fillWidth = Int((CGFloat(rectPx.w) * CGFloat(clamped)).rounded())
            if fillWidth > 0 {
                NSGraphicsContext.current?.cgContext.saveGState()
                track.addClip()
                fillColor.setFill()
                NSBezierPath(rect: CGRect(
                    x: CGFloat(rectPx.x) / self.outputScale,
                    y: CGFloat(rectPx.y) / self.outputScale,
                    width: CGFloat(fillWidth) / self.outputScale,
                    height: CGFloat(rectPx.h) / self.outputScale)).fill()
                NSGraphicsContext.current?.cgContext.restoreGState()
            }
        }
    }

    private static func render(_ draw: () -> Void) -> NSImage {
        let image = NSImage(size: self.outputSize)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: self.canvasPx,
            pixelsHigh: self.canvasPx,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0)
        else {
            return image
        }
        rep.size = self.outputSize
        image.addRepresentation(rep)
        NSGraphicsContext.saveGraphicsState()
        if let context = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = context
            context.cgContext.setShouldAntialias(true)
            context.cgContext.interpolationQuality = .none
            draw()
        }
        NSGraphicsContext.restoreGraphicsState()
        return image
    }
}
