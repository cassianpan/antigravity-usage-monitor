import AppKit
import Foundation

/// Renders the menu bar item:
/// - Single 5H column (default): clean single-line `[Icon] 3%` without the `5H` caption.
/// - Multiple columns: compact two-line stacked columns (`5H / WEEK / ...` above values).
enum MenuBarRenderer {
    @MainActor
    static func render(columns: [MenuBarColumnItem]) -> NSImage {
        let height: CGFloat = 22
        let iconSize: CGFloat = 13
        let leftPadding: CGFloat = 4
        let rightPadding: CGFloat = 4

        // Single-column compact mode: omit the redundant "5H" caption.
        if columns.count == 1, let only = columns.first {
            let gap: CGFloat = 5
            let valFont = NSFont.monospacedDigitSystemFont(ofSize: 12.0, weight: .semibold)
            let valAttrs: [NSAttributedString.Key: Any] = [
                .font: valFont,
                .foregroundColor: NSColor(hex: only.valueHex),
            ]
            let valStr = NSAttributedString(string: only.value, attributes: valAttrs)
            let valSize = valStr.size()
            let totalWidth = ceil(leftPadding + iconSize + gap + valSize.width + rightPadding)

            let image = NSImage(size: NSSize(width: totalWidth, height: height), flipped: false) { _ in
                drawBrandIcon(x: leftPadding, height: height, iconSize: iconSize)
                let valY = (height - valSize.height) / 2.0
                valStr.draw(at: NSPoint(x: leftPadding + iconSize + gap, y: valY))
                return true
            }
            image.isTemplate = false
            return image
        }

        // Multi-column stacked mode (or icon-only when 0 columns)
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
            drawBrandIcon(x: leftPadding, height: height, iconSize: iconSize)

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

    private static func drawBrandIcon(x: CGFloat, height: CGFloat, iconSize: CGFloat) {
        if let symbol = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Antigravity") {
            let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
                .applying(.init(paletteColors: [NSColor(hex: Palette.accentHex)]))
            let configured = symbol.withSymbolConfiguration(config) ?? symbol
            let iconRect = NSRect(
                x: x,
                y: (height - iconSize) / 2.0,
                width: iconSize,
                height: iconSize
            )
            configured.draw(in: iconRect)
        }
    }
}
