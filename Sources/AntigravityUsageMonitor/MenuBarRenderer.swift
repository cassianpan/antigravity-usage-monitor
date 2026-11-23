import AppKit
import Foundation

/// Renders the compact stacked-column menu bar item matching claude-usage-monitor's hero bar:
/// [Brand Icon]  5H    WEEK   TODAY
///               8%    10%    $288
enum MenuBarRenderer {
    @MainActor
    static func render(columns: [MenuBarColumnItem]) -> NSImage {
        let height: CGFloat = 22
        let iconSize: CGFloat = 13
        let leftPadding: CGFloat = 4
        let iconToColGap: CGFloat = columns.isEmpty ? 4 : 7
        let colGap: CGFloat = 9
        let rightPadding: CGFloat = 4

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
            // Draw tinted Antigravity icon
            if let symbol = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Antigravity") {
                let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
                    .applying(.init(paletteColors: [NSColor(hex: Palette.accentHex)]))
                let configured = symbol.withSymbolConfiguration(config) ?? symbol
                let iconRect = NSRect(
                    x: leftPadding,
                    y: (height - iconSize) / 2.0,
                    width: iconSize,
                    height: iconSize
                )
                configured.draw(in: iconRect)
            }

            var x = leftPadding + iconSize + iconToColGap
            for item in measured {
                let topSize = item.top.size()
                let valSize = item.val.size()
                // Center each line inside its column
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
}
