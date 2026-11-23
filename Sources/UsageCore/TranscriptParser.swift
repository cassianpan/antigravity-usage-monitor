import Foundation

public enum ISO8601DateParser {
    public static func parse(_ string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: trimmed) {
            return date
        }

        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: trimmed)
    }
}

public struct TranscriptParser: Sendable {
    private struct RawLine: Decodable {
        let createdAt: String?
        let model: String?
        let inputTokens: Int?
        let cacheReadTokens: Int?
        let outputTokens: Int?

        enum CodingKeys: String, CodingKey {
            case createdAt = "created_at"
            case model
            case inputTokens = "input_tokens"
            case cacheReadTokens = "cache_read_tokens"
            case outputTokens = "output_tokens"
        }
    }

    public init() {}

    public func parseLine(_ data: Data, conversationId: String) -> TranscriptRecord? {
        guard !data.isEmpty else { return nil }
        guard let raw = try? JSONDecoder().decode(RawLine.self, from: data) else {
            return nil
        }

        // Only lines carrying token metrics represent billed/tracked model responses.
        guard raw.inputTokens != nil || raw.outputTokens != nil || raw.cacheReadTokens != nil else {
            return nil
        }
        guard let createdAt = raw.createdAt, let timestamp = ISO8601DateParser.parse(createdAt) else {
            return nil
        }

        let modelName = raw.model?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedModel = (modelName?.isEmpty == false) ? modelName! : "unknown"

        return TranscriptRecord(
            timestamp: timestamp,
            model: resolvedModel,
            inputTokens: raw.inputTokens ?? 0,
            cacheReadTokens: raw.cacheReadTokens ?? 0,
            outputTokens: raw.outputTokens ?? 0,
            conversationId: conversationId
        )
    }

    public func parseData(_ data: Data, conversationId: String) -> [TranscriptRecord] {
        var results: [TranscriptRecord] = []
        let newline: UInt8 = 0x0A
        var start = data.startIndex
        while start < data.endIndex {
            let end = data[start...].firstIndex(of: newline) ?? data.endIndex
            let slice = data[start..<end]
            if !slice.isEmpty, let record = parseLine(Data(slice), conversationId: conversationId) {
                results.append(record)
            }
            start = end < data.endIndex ? data.index(after: end) : data.endIndex
        }
        return results
    }
}

/// Incremental file-cursor index over `~/.gemini/antigravity/brain/<id>/.system_generated/logs/transcript.jsonl`.
public final class TranscriptIndex: @unchecked Sendable {
    private struct FileCursor {
        var byteOffset: UInt64
        var modificationDate: Date
        var records: [TranscriptRecord]
    }

    private let brainDirectory: URL
    private let parser: TranscriptParser
    private var cursors: [String: FileCursor] = [:]

    public init(brainDirectory: URL, parser: TranscriptParser = TranscriptParser()) {
        self.brainDirectory = brainDirectory
        self.parser = parser
    }

    public static var defaultBrainDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/antigravity/brain", isDirectory: true)
    }

    /// Scans the brain directory incrementally and returns all parsed records + unique conversation count.
    public func refresh() -> (records: [TranscriptRecord], conversationCount: Int) {
        let fm = FileManager.default
        guard let conversationDirs = try? fm.contentsOfDirectory(
            at: brainDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            cursors.removeAll()
            return ([], 0)
        }

        var activePaths = Set<String>()
        var allRecords: [TranscriptRecord] = []
        var conversationIds = Set<String>()

        for dir in conversationDirs {
            let transcriptURL = dir
                .appendingPathComponent(".system_generated", isDirectory: true)
                .appendingPathComponent("logs", isDirectory: true)
                .appendingPathComponent("transcript.jsonl", isDirectory: false)

            guard fm.fileExists(atPath: transcriptURL.path) else { continue }
            let path = transcriptURL.path
            activePaths.insert(path)

            let conversationId = dir.lastPathComponent
            let attrs = try? fm.attributesOfItem(atPath: path)
            let fileSize = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
            let modDate = (attrs?[.modificationDate] as? Date) ?? .distantPast

            if var cursor = cursors[path] {
                if fileSize < cursor.byteOffset {
                    // File truncated/rewritten: re-parse from scratch.
                    let fresh = readSlice(url: transcriptURL, offset: 0, conversationId: conversationId)
                    cursor = FileCursor(byteOffset: fresh.newOffset, modificationDate: modDate, records: fresh.records)
                    cursors[path] = cursor
                } else if fileSize > cursor.byteOffset || modDate > cursor.modificationDate {
                    let delta = readSlice(url: transcriptURL, offset: cursor.byteOffset, conversationId: conversationId)
                    cursor.byteOffset = delta.newOffset
                    cursor.modificationDate = modDate
                    cursor.records.append(contentsOf: delta.records)
                    cursors[path] = cursor
                }
                if !cursor.records.isEmpty {
                    conversationIds.insert(conversationId)
                    allRecords.append(contentsOf: cursor.records)
                }
            } else {
                let fresh = readSlice(url: transcriptURL, offset: 0, conversationId: conversationId)
                let cursor = FileCursor(byteOffset: fresh.newOffset, modificationDate: modDate, records: fresh.records)
                cursors[path] = cursor
                if !cursor.records.isEmpty {
                    conversationIds.insert(conversationId)
                    allRecords.append(contentsOf: cursor.records)
                }
            }
        }

        // Prune removed files
        for key in cursors.keys where !activePaths.contains(key) {
            cursors.removeValue(forKey: key)
        }

        return (allRecords, conversationIds.count)
    }

    private func readSlice(url: URL, offset: UInt64, conversationId: String) -> (records: [TranscriptRecord], newOffset: UInt64) {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return ([], offset)
        }
        defer { try? handle.close() }

        do {
            try handle.seek(toOffset: offset)
            let data = try handle.readToEnd() ?? Data()
            guard !data.isEmpty else { return ([], offset) }

            // Only advance offset up to the last complete newline so partial trailing writes are retried next refresh.
            let newline: UInt8 = 0x0A
            if let lastNewline = data.lastIndex(of: newline) {
                let completeLength = data.distance(from: data.startIndex, to: lastNewline) + 1
                let completeData = data.prefix(completeLength)
                let records = parser.parseData(completeData, conversationId: conversationId)
                return (records, offset + UInt64(completeLength))
            } else {
                // Single line without trailing newline: attempt parse, only advance if valid JSON record.
                if let record = parser.parseLine(data, conversationId: conversationId) {
                    return ([record], offset + UInt64(data.count))
                }
                return ([], offset)
            }
        } catch {
            return ([], offset)
        }
    }
}
