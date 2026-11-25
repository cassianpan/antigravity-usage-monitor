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

    public func parseLine(_ data: Data, conversationId: String, fallbackModel: String? = nil) -> TranscriptRecord? {
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

        let explicitModel = raw.model?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedModel: String
        if let explicitModel, !explicitModel.isEmpty, explicitModel.lowercased() != "unknown" {
            resolvedModel = explicitModel
        } else if let fallbackModel, !fallbackModel.isEmpty, fallbackModel.lowercased() != "unknown" {
            resolvedModel = fallbackModel
        } else {
            resolvedModel = "unknown"
        }

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
        var lastKnownModel: String? = nil
        return parseData(data, conversationId: conversationId, lastKnownModel: &lastKnownModel)
    }

    public func parseData(_ data: Data, conversationId: String, lastKnownModel: inout String?) -> [TranscriptRecord] {
        var results: [TranscriptRecord] = []
        let newline: UInt8 = 0x0A
        var start = data.startIndex
        var hasLeadingUnknown = false
        while start < data.endIndex {
            let end = data[start...].firstIndex(of: newline) ?? data.endIndex
            let slice = data[start..<end]
            if !slice.isEmpty, let record = parseLine(Data(slice), conversationId: conversationId, fallbackModel: lastKnownModel) {
                if record.model.lowercased() != "unknown" {
                    lastKnownModel = record.model
                } else {
                    hasLeadingUnknown = true
                }
                results.append(record)
            }
            start = end < data.endIndex ? data.index(after: end) : data.endIndex
        }
        // Backfill leading model-less entries (e.g. an early CHECKPOINT) once a real model appears in the same conversation.
        if hasLeadingUnknown, let resolved = lastKnownModel {
            results = results.map { record in
                guard record.model.lowercased() == "unknown" else { return record }
                return TranscriptRecord(
                    timestamp: record.timestamp,
                    model: resolved,
                    inputTokens: record.inputTokens,
                    cacheReadTokens: record.cacheReadTokens,
                    outputTokens: record.outputTokens,
                    conversationId: record.conversationId
                )
            }
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
        var lastKnownModel: String?
    }

    private let brainDirectory: URL
    private let parser: TranscriptParser
    private let ledger: UsageLedger?
    private let lock = NSLock()
    private var cursors: [String: FileCursor] = [:]
    private var hasSeededLedger = false

    public init(
        brainDirectory: URL,
        parser: TranscriptParser = TranscriptParser(),
        ledgerURL: URL? = nil
    ) {
        self.brainDirectory = brainDirectory
        self.parser = parser
        self.ledger = ledgerURL.map { UsageLedger(fileURL: $0) }
    }

    public static var defaultBrainDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/antigravity/brain", isDirectory: true)
    }

    /// Synchronously flushes any pending buffered ledger writes to disk.
    public func flushLedger() {
        ledger?.flush()
    }

    /// Scans the brain directory incrementally and returns all parsed records + unique conversation count.
    public func refresh() -> (records: [TranscriptRecord], conversationCount: Int) {
        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        guard let conversationDirs = try? fm.contentsOfDirectory(
            at: brainDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            cursors.removeAll()
            if let ledger {
                return ledger.mergeAndPersist(liveByConversation: [:])
            }
            return ([], 0)
        }

        var activePaths = Set<String>()
        var allRecords: [TranscriptRecord] = []
        var changedByConversation: [String: [TranscriptRecord]] = [:]
        var conversationIds = Set<String>()

        for dir in conversationDirs {
            let transcriptURL = dir
                .appendingPathComponent(".system_generated", isDirectory: true)
                .appendingPathComponent("logs", isDirectory: true)
                .appendingPathComponent("transcript.jsonl", isDirectory: false)

            // Strictly read regular non-symlink files (prevents symlink loops and blocking on FIFO named pipes).
            guard let rv = try? transcriptURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  rv.isRegularFile == true,
                  rv.isSymbolicLink != true else { continue }

            let path = transcriptURL.path
            activePaths.insert(path)

            let conversationId = dir.lastPathComponent
            let attrs = try? fm.attributesOfItem(atPath: path)
            let fileSize = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
            let modDate = (attrs?[.modificationDate] as? Date) ?? .distantPast

            var fileChanged = !hasSeededLedger
            if var cursor = cursors[path] {
                if fileSize < cursor.byteOffset {
                    // File truncated/rewritten: re-parse from scratch.
                    var lastModel: String? = nil
                    let fresh = readSlice(url: transcriptURL, offset: 0, conversationId: conversationId, lastKnownModel: &lastModel)
                    cursor = FileCursor(byteOffset: fresh.newOffset, modificationDate: modDate, records: fresh.records, lastKnownModel: lastModel)
                    cursors[path] = cursor
                    fileChanged = true
                } else if fileSize > cursor.byteOffset || modDate > cursor.modificationDate {
                    let hadNoModelBefore = (cursor.lastKnownModel == nil)
                    var lastModel = cursor.lastKnownModel
                    let delta = readSlice(url: transcriptURL, offset: cursor.byteOffset, conversationId: conversationId, lastKnownModel: &lastModel)
                    cursor.byteOffset = delta.newOffset
                    cursor.modificationDate = modDate
                    cursor.lastKnownModel = lastModel
                    // Backfill any earlier leading "unknown" records once a real model appears in later steps.
                    if hadNoModelBefore, let resolvedModel = lastModel {
                        cursor.records = cursor.records.map { rec in
                            if rec.model.lowercased() == "unknown" {
                                return TranscriptRecord(
                                    timestamp: rec.timestamp,
                                    model: resolvedModel,
                                    inputTokens: rec.inputTokens,
                                    cacheReadTokens: rec.cacheReadTokens,
                                    outputTokens: rec.outputTokens,
                                    conversationId: rec.conversationId
                                )
                            }
                            return rec
                        }
                    }
                    cursor.records.append(contentsOf: delta.records)
                    cursors[path] = cursor
                    if !delta.records.isEmpty || (hadNoModelBefore && lastModel != nil) {
                        fileChanged = true
                    }
                }
                if !cursor.records.isEmpty {
                    conversationIds.insert(conversationId)
                    if fileChanged {
                        changedByConversation[conversationId] = cursor.records
                    }
                    allRecords.append(contentsOf: cursor.records)
                }
            } else {
                var lastModel: String? = nil
                let fresh = readSlice(url: transcriptURL, offset: 0, conversationId: conversationId, lastKnownModel: &lastModel)
                let cursor = FileCursor(byteOffset: fresh.newOffset, modificationDate: modDate, records: fresh.records, lastKnownModel: lastModel)
                cursors[path] = cursor
                if !cursor.records.isEmpty {
                    conversationIds.insert(conversationId)
                    changedByConversation[conversationId] = cursor.records
                    allRecords.append(contentsOf: cursor.records)
                }
            }
        }

        // Prune removed files from live cursor cache (persisted ledger retains their numeric history).
        for key in cursors.keys where !activePaths.contains(key) {
            cursors.removeValue(forKey: key)
        }

        if let ledger {
            let forceInitialFlush = !hasSeededLedger
            hasSeededLedger = true
            return ledger.mergeAndPersist(
                liveByConversation: changedByConversation,
                forceFlush: forceInitialFlush
            )
        }
        return (allRecords, conversationIds.count)
    }

    private func readSlice(url: URL, offset: UInt64, conversationId: String, lastKnownModel: inout String?) -> (records: [TranscriptRecord], newOffset: UInt64) {
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
                let records = parser.parseData(completeData, conversationId: conversationId, lastKnownModel: &lastKnownModel)
                return (records, offset + UInt64(completeLength))
            } else {
                // Single line without trailing newline: attempt parse, only advance if valid JSON record.
                if let record = parser.parseLine(data, conversationId: conversationId, fallbackModel: lastKnownModel) {
                    if record.model.lowercased() != "unknown" {
                        lastKnownModel = record.model
                    }
                    return ([record], offset + UInt64(data.count))
                }
                return ([], offset)
            }
        } catch {
            return ([], offset)
        }
    }
}
