import AppKit
import CoreGraphics
import Foundation

/// Renders the menu bar item with a crisp vector 4-point star (supports smooth spin animation during sync)
/// and an ice-blue radial-bloom breathing indicator paired with a cold cyan-white count for running agents.
enum MenuBarRenderer {
    @MainActor
    static func render(
        columns: [MenuBarColumnItem],
        spinAngleRadians: CGFloat = 0,
        runningAgentCount: Int = 0,
        breathingPhase: CGFloat = .pi
    ) -> NSImage {
        let height: CGFloat = 22
        let iconSize: CGFloat = 15
        let leftPadding: CGFloat = 4
        let rightPadding: CGFloat = 4
        let showAgents = runningAgentCount > 0

        // Nonlinear breathing curve: deeper dim valley, fuller glowing peak.
        // At breathingPhase == .pi (Reduce Motion steady state), breath == 1.0.
        let rawPulse = CGFloat((1.0 - cos(Double(breathingPhase))) * 0.5)
        let breath = CGFloat(pow(Double(rawPulse), 1.35))

        // Brand blue (#8EC0FF, matching the 4-point star's #4F8CFF -> #7AB8FF hue) breathing in sync.
        let agentTextColor = NSColor(
            srgbRed: 0.557,
            green: 0.753,
            blue: 1.000,
            alpha: 0.74 + 0.26 * breath
        )

        if columns.count == 1, let only = columns.first {
            let valFont = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .semibold)
            let valAttrs: [NSAttributedString.Key: Any] = [
                .font: valFont,
                .foregroundColor: NSColor(hex: only.valueHex),
            ]
            let valStr = NSAttributedString(string: only.value, attributes: valAttrs)
            let valSize = valStr.size()

            if showAgents {
                let agentFont = NSFont.monospacedDigitSystemFont(ofSize: 11.0, weight: .bold)
                let agentStr = NSAttributedString(
                    string: "\(runningAgentCount)",
                    attributes: [
                        .font: agentFont,
                        .foregroundColor: agentTextColor,
                    ]
                )
                let agentSize = agentStr.size()
                let starToDotGap: CGFloat = 4.0
                let dotSlotWidth: CGFloat = 9.0
                let dotToCountGap: CGFloat = 1.0
                let countToValGap: CGFloat = 9.5

                let totalWidth = ceil(
                    leftPadding + iconSize + starToDotGap + dotSlotWidth + dotToCountGap
                    + agentSize.width + countToValGap
                    + valSize.width + rightPadding
                )

                let image = NSImage(size: NSSize(width: totalWidth, height: height), flipped: false) { _ in
                    drawFourPointStar(
                        cx: leftPadding + iconSize / 2.0,
                        cy: height / 2.0,
                        radius: iconSize / 2.0,
                        angle: spinAngleRadians
                    )
                    var x = leftPadding + iconSize + starToDotGap
                    drawBreathingDot(cx: x + dotSlotWidth / 2.0, cy: height / 2.0, breath: breath)
                    x += dotSlotWidth + dotToCountGap
                    agentStr.draw(at: NSPoint(x: x, y: (height - agentSize.height) / 2.0))
                    x += agentSize.width + countToValGap
                    valStr.draw(at: NSPoint(x: x, y: (height - valSize.height) / 2.0))
                    return true
                }
                image.isTemplate = false
                return image
            }

            let gap: CGFloat = 5
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

        let iconToContentGap: CGFloat = (columns.isEmpty && !showAgents) ? 0 : 7
        let colGap: CGFloat = 9
        let topFont = NSFont.systemFont(ofSize: 7.0, weight: .semibold)
        let valFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)

        let topAttrs: [NSAttributedString.Key: Any] = [
            .font: topFont,
            .foregroundColor: NSColor.white.withAlphaComponent(0.55),
        ]

        let agentCountStr: NSAttributedString?
        let agentColWidth: CGFloat
        if showAgents {
            let agentMultiFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .bold)
            let str = NSAttributedString(
                string: "\(runningAgentCount)",
                attributes: [
                    .font: agentMultiFont,
                    .foregroundColor: agentTextColor,
                ]
            )
            agentCountStr = str
            agentColWidth = ceil(max(11.0, str.size().width))
        } else {
            agentCountStr = nil
            agentColWidth = 0
        }

        let agentToColsGap: CGFloat = (showAgents && !columns.isEmpty) ? 10.0 : 0

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
        let agentSectionWidth = showAgents ? (agentColWidth + agentToColsGap) : 0
        let totalWidth = max(24, ceil(leftPadding + iconSize + iconToContentGap + agentSectionWidth + columnsWidth + rightPadding))

        let image = NSImage(size: NSSize(width: totalWidth, height: height), flipped: false) { _ in
            drawFourPointStar(
                cx: leftPadding + iconSize / 2.0,
                cy: height / 2.0,
                radius: iconSize / 2.0,
                angle: spinAngleRadians
            )

            var x = leftPadding + iconSize + iconToContentGap

            if let agentCountStr {
                let countSize = agentCountStr.size()
                drawBreathingDot(cx: x + agentColWidth / 2.0, cy: 15.5, breath: breath)
                agentCountStr.draw(at: NSPoint(x: x + (agentColWidth - countSize.width) / 2.0, y: 0.5))
                x += agentColWidth + agentToColsGap
            }

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

    private static func drawBreathingDot(cx: CGFloat, cy: CGFloat, breath: CGFloat) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()

        let center = CGPoint(x: cx, y: cy)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

        // 1. Soft radial gradient bloom (#4F8CFF, exact star core blue -> transparent)
        let bloomRadius = 2.4 + 2.1 * breath
        let bloomAlpha = 0.06 + 0.44 * breath
        let bloomColors = [
            CGColor(colorSpace: colorSpace, components: [0.310, 0.549, 1.000, bloomAlpha])!,
            CGColor(colorSpace: colorSpace, components: [0.310, 0.549, 1.000, 0.0])!,
        ] as CFArray
        if let grad = CGGradient(colorsSpace: colorSpace, colors: bloomColors, locations: [0.0, 1.0]) {
            ctx.drawRadialGradient(
                grad,
                startCenter: center,
                startRadius: 0,
                endCenter: center,
                endRadius: bloomRadius,
                options: []
            )
        }

        // 2. Subtle expanding pulse ring (#7AB8FF, exact star highlight blue)
        let ringRadius = 2.05 + 1.15 * breath
        ctx.setStrokeColor(CGColor(colorSpace: colorSpace, components: [0.478, 0.722, 1.000, 0.10 + 0.34 * breath])!)
        ctx.setLineWidth(0.7)
        ctx.strokeEllipse(in: CGRect(x: cx - ringRadius, y: cy - ringRadius, width: ringRadius * 2, height: ringRadius * 2))

        // 3. High-contrast solid core interpolating from #4F8CFF (valley) to #C7E0FF (peak)
        let coreRadius = 1.90 + 0.35 * breath
        let r = 0.310 + (0.780 - 0.310) * breath
        let g = 0.549 + (0.878 - 0.549) * breath
        let b: CGFloat = 1.000
        let coreAlpha = 0.30 + 0.70 * breath
        ctx.setFillColor(CGColor(colorSpace: colorSpace, components: [r, g, b, coreAlpha])!)
        ctx.fillEllipse(in: CGRect(x: cx - coreRadius, y: cy - coreRadius, width: coreRadius * 2, height: coreRadius * 2))

        ctx.restoreGState()
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
