import AppKit
import CoreGraphics
import Foundation

/// Renders the menu bar item with a crisp vector 4-point star (supports smooth spin animation during sync).
enum MenuBarRenderer {
    @MainActor
    static func render(columns: [MenuBarColumnItem], spinAngleRadians: CGFloat = 0) -> NSImage {
        let height: CGFloat = 22
        let iconSize: CGFloat = 15
        let leftPadding: CGFloat = 4
        let rightPadding: CGFloat = 4

        if columns.count == 1, let only = columns.first {
            let gap: CGFloat = 5
            let valFont = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .semibold)
            let valAttrs: [NSAttributedString.Key: Any] = [
                .font: valFont,
                .foregroundColor: NSColor(hex: only.valueHex),
            ]
            let valStr = NSAttributedString(string: only.value, attributes: valAttrs)
            let valSize = valStr.size()
            let totalWidth = ceil(leftPadding + iconSize + gap + valSize.width + rightPadding)

            let image = NSImage(size: NSSize(width: totalWidth, height: height), flipped: false) { _ in
                drawFourPointStar(
                    cx: leftPadding + iconSize / 2.0,
                    cy: height / 2.0,
                    radius: iconSize / 2.0,
                    angle: spinAngleRadians
                )
                let valY = (height - valSize.height) / 2.0
                valStr.draw(at: NSPoint(x: leftPadding + iconSize + gap, y: valY))
                return true
            }
            image.isTemplate = false
            return image
        }

        let iconToColGap: CGFloat = columns.isEmpty ? 0 : 7
        let colGap: CGFloat = 9
        let topFont = NSFont.systemFont(ofSize: 7.0, weight: .semibold)
        let valFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)

        let topAttrs: [NSAttributedString.Key: Any] = [
            .font: topFont,
            .foregroundColor: NSColor.white.withAlphaComponent(0.55),
        ]

        var measured: [(top: NSAttributedString, val: NSAttributedString, width: CGFloat)] = []
        for col in columns {
            let topStr = NSAttributedString(string: col.topLabel, attributes: topAttrs)
            let valAttrs: [NSAttributedString.Key: Any] = [
                .font: valFont,
                .foregroundColor: NSColor(hex: col.valueHex),
            ]
            let valStr = NSAttributedString(string: col.value, attributes: valAttrs)
            let w = ceil(max(topStr.size().width, valStr.size().width))
            measured.append((topStr, valStr, w))
        }

        let columnsWidth = measured.reduce(0) { $0 + $1.width } + max(0, CGFloat(measured.count - 1)) * colGap
        let totalWidth = max(24, leftPadding + iconSize + iconToColGap + columnsWidth + rightPadding)

        let image = NSImage(size: NSSize(width: totalWidth, height: height), flipped: false) { _ in
            drawFourPointStar(
                cx: leftPadding + iconSize / 2.0,
                cy: height / 2.0,
                radius: iconSize / 2.0,
                angle: spinAngleRadians
            )

            var x = leftPadding + iconSize + iconToColGap
            for item in measured {
                let topSize = item.top.size()
                let valSize = item.val.size()
                let topX = x + (item.width - topSize.width) / 2.0
                let valX = x + (item.width - valSize.width) / 2.0

                item.top.draw(at: NSPoint(x: topX, y: 12.0))
                item.val.draw(at: NSPoint(x: valX, y: 0.5))

                x += item.width + colGap
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func drawFourPointStar(cx: CGFloat, cy: CGFloat, radius r: CGFloat, angle: CGFloat) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.translateBy(x: cx, y: cy)
        // Base 30-degree clockwise tilt + optional sync spin angle
        let baseTilt: CGFloat = 30.0 * .pi / 180.0
        ctx.rotate(by: -(baseTilt + angle))

        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: r))
        path.addQuadCurve(to: CGPoint(x: r, y: 0), control: CGPoint(x: r * 0.14, y: r * 0.14))
        path.addQuadCurve(to: CGPoint(x: 0, y: -r), control: CGPoint(x: r * 0.14, y: -r * 0.14))
        path.addQuadCurve(to: CGPoint(x: -r, y: 0), control: CGPoint(x: -r * 0.14, y: -r * 0.14))
        path.addQuadCurve(to: CGPoint(x: 0, y: r), control: CGPoint(x: -r * 0.14, y: r * 0.14))
        path.closeSubpath()

        ctx.addPath(path)
        ctx.clip()

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let colors = [
            CGColor(srgbRed: 0.48, green: 0.72, blue: 1.0, alpha: 1.0),
            CGColor(srgbRed: 0.31, green: 0.55, blue: 1.0, alpha: 1.0),
            CGColor(srgbRed: 0.45, green: 0.38, blue: 0.98, alpha: 1.0),
        ] as CFArray
        if let grad = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0.0, 0.55, 1.0]) {
            ctx.drawLinearGradient(
                grad,
                start: CGPoint(x: -r, y: r),
                end: CGPoint(x: r, y: -r),
                options: []
            )
        }
        ctx.restoreGState()
    }
}
