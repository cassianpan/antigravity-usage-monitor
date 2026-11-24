import Foundation
import SwiftUI

struct MarkdownBlock {
    enum Kind: Equatable {
        case heading(Int)
        case paragraph
        case listItem(depth: Int, marker: String)
        case code(depth: Int)
        case quote
    }

    var kind: Kind
    var text: AttributedString
}

enum MarkdownBlocks {
    /// Extracts the localized changelog body from bilingual GitHub Release notes,
    /// stripping the trailing Install / Upgrade & SHA-256 boilerplate.
    static func extractLocalizedReleaseNotes(_ raw: String, preferChinese: Bool) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        // Strip everything from "## Install" onward.
        let bodyOnly: String
        if let installRange = trimmed.range(of: "\n## Install", options: .caseInsensitive) {
            bodyOnly = String(trimmed[..<installRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            bodyOnly = trimmed
        }

        // Split bilingual sections separated by "---" if both "## 更新内容" and "## What's New" exist.
        let zhMarker = "## 更新内容"
        let enMarker = "## What's New"
        if let zhRange = bodyOnly.range(of: zhMarker),
           let enRange = bodyOnly.range(of: enMarker) {
            if preferChinese {
                let slice: String
                if zhRange.lowerBound < enRange.lowerBound {
                    slice = String(bodyOnly[zhRange.upperBound..<enRange.lowerBound])
                } else {
                    slice = String(bodyOnly[zhRange.upperBound...])
                }
                return cleanSectionDividers(slice)
            } else {
                let slice: String
                if enRange.lowerBound < zhRange.lowerBound {
                    slice = String(bodyOnly[enRange.upperBound..<zhRange.lowerBound])
                } else {
                    slice = String(bodyOnly[enRange.upperBound...])
                }
                return cleanSectionDividers(slice)
            }
        }

        return cleanSectionDividers(bodyOnly)
    }

    private static func cleanSectionDividers(_ text: String) -> String {
        text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { $0.trimmingCharacters(in: .whitespaces) != "---" }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parse(_ markdown: String) -> [MarkdownBlock] {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard let document = try? AttributedString(markdown: markdown, options: options) else {
            return [MarkdownBlock(kind: .paragraph, text: AttributedString(markdown))]
        }
        var blocks: [MarkdownBlock] = []
        var currentIntent: PresentationIntent?
        for run in document.runs {
            var text = AttributedString(document[run.range])
            text.presentationIntent = nil
            if !blocks.isEmpty, run.presentationIntent == currentIntent {
                blocks[blocks.count - 1].text.append(text)
            } else {
                blocks.append(MarkdownBlock(kind: kind(of: run.presentationIntent), text: text))
                currentIntent = run.presentationIntent
            }
        }
        return blocks.filter {
            !String($0.text.characters).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private static func kind(of intent: PresentationIntent?) -> MarkdownBlock.Kind {
        guard let intent else { return .paragraph }
        var depth = 0
        var ordinal: Int?
        var innermostOrdered: Bool?
        var isQuote = false
        var isCode = false
        for component in intent.components {
            switch component.kind {
            case .header(let level):
                return .heading(level)
            case .codeBlock:
                isCode = true
            case .listItem(let number):
                if ordinal == nil { ordinal = number }
            case .orderedList:
                depth += 1
                if innermostOrdered == nil { innermostOrdered = true }
            case .unorderedList:
                depth += 1
                if innermostOrdered == nil { innermostOrdered = false }
            case .blockQuote:
                isQuote = true
            default:
                break
            }
        }
        if isCode { return .code(depth: depth) }
        if depth > 0 {
            let marker = innermostOrdered == true ? "\(ordinal ?? 1)." : (depth == 1 ? "•" : "◦")
            return .listItem(depth: depth, marker: marker)
        }
        return isQuote ? .quote : .paragraph
    }
}

/// Rendered Markdown release notes (headings, nested lists, inline bold/code/links).
struct MarkdownNotesView: View {
    let markdown: String

    var body: some View {
        let blocks = MarkdownBlocks.parse(markdown)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                blockView(block, isFirst: index == 0)
            }
        }
        .tint(Palette.accent)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock, isFirst: Bool) -> some View {
        switch block.kind {
        case .heading(let level):
            Text(block.text)
                .font(.system(size: level <= 2 ? 12.5 : 11.5, weight: .semibold))
                .foregroundStyle(Palette.text)
                .padding(.top, isFirst ? 0 : 10)
                .padding(.bottom, 5)
        case .paragraph:
            Text(block.text)
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.secondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 6)
        case .listItem(let depth, let marker):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker)
                    .foregroundStyle(Palette.tertiary)
                    .frame(minWidth: 8, alignment: .trailing)
                Text(block.text)
                    .foregroundStyle(Palette.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: 11.5))
            .padding(.leading, CGFloat(depth - 1) * 14)
            .padding(.bottom, 5)
        case .code(let depth):
            Text(block.text)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.05))
                )
                .padding(.leading, depth > 0 ? CGFloat(depth - 1) * 14 + 14 : 0)
                .padding(.bottom, 6)
        case .quote:
            HStack(alignment: .top, spacing: 8) {
                Capsule().fill(Palette.quaternary).frame(width: 2)
                Text(block.text)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.tertiary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 6)
        }
    }
}
