//
//  CompanionScreenAnnotationUtility.swift
//  leanring-buddy
//
//  Legacy/debug helper for drawing visual-scene markers onto a screenshot.
//  The normal realtime path sends raw screenshots instead.
//

import AppKit

@MainActor
enum CompanionScreenAnnotationUtility {
    private static let maxAnnotatedTargets = 40

    static func annotatedJPEGData(from imageData: Data, visualScene: VisualScene?) -> Data {
        guard let visualScene,
              let image = NSImage(data: imageData),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return imageData
        }

        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return imageData }

        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [.alphaNonpremultiplied],
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        guard let bitmap else { return imageData }
        let imageSize = NSSize(width: CGFloat(width), height: CGFloat(height))
        bitmap.size = imageSize

        let scaleX = CGFloat(width) / CGFloat(max(1, visualScene.screenWidth))
        let scaleY = CGFloat(height) / CGFloat(max(1, visualScene.screenHeight))

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current?.imageInterpolation = .high
        NSImage(cgImage: cgImage, size: imageSize).draw(in: CGRect(origin: .zero, size: imageSize))

        for target in visualScene.targets.prefix(maxAnnotatedTargets) {
            draw(target: target, imageWidth: CGFloat(width), imageHeight: CGFloat(height), scaleX: scaleX, scaleY: scaleY)
        }

        NSGraphicsContext.restoreGraphicsState()

        guard let annotatedData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.82]),
              let annotatedRep = NSBitmapImageRep(data: annotatedData),
              annotatedRep.pixelsWide == width,
              annotatedRep.pixelsHigh == height else {
            print("⚠️ CompanionScreenAnnotationUtility: annotation changed image dimensions; using original screenshot")
            return imageData
        }

        return annotatedData
    }

    private static func draw(target: VisualTarget, imageWidth: CGFloat, imageHeight: CGFloat, scaleX: CGFloat, scaleY: CGFloat) {
        guard let marker = target.marker, !marker.isEmpty else { return }
        let rect = CGRect(
            x: CGFloat(target.box.x) * scaleX,
            y: CGFloat(target.box.y) * scaleY,
            width: CGFloat(target.box.width) * scaleX,
            height: CGFloat(target.box.height) * scaleY
        )
        guard rect.width >= 6, rect.height >= 6 else { return }

        let color = target.kind == .appWindow ? NSColor.systemOrange : NSColor.systemBlue
        let border = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        color.withAlphaComponent(0.9).setStroke()
        border.lineWidth = 2
        border.stroke()

        let fontSize = 10.0
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        let textSize = marker.size(withAttributes: attributes)
        let badgeWidth = max(22, textSize.width + 10)
        let badgeHeight: CGFloat = 18
        let badgeX = min(max(0, rect.minX), max(0, imageWidth - badgeWidth))
        let preferredBadgeY = rect.minY - badgeHeight - 2
        let fallbackBadgeY = min(max(0, rect.minY + 2), max(0, imageHeight - badgeHeight))
        let badgeY = preferredBadgeY >= 0 ? preferredBadgeY : fallbackBadgeY
        let badgeRect = CGRect(x: badgeX, y: badgeY, width: badgeWidth, height: badgeHeight)
        let badgePath = NSBezierPath(roundedRect: badgeRect, xRadius: 6, yRadius: 6)
        color.withAlphaComponent(0.92).setFill()
        badgePath.fill()
        NSColor.white.withAlphaComponent(0.95).setStroke()
        badgePath.lineWidth = 0.7
        badgePath.stroke()

        let textRect = CGRect(
            x: badgeRect.midX - textSize.width / 2,
            y: badgeRect.midY - textSize.height / 2,
            width: textSize.width,
            height: textSize.height
        )
        marker.draw(in: textRect, withAttributes: attributes)
    }
}
