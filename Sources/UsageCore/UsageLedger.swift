import Darwin
import Foundation

/// Privacy-safe numeric-only local usage ledger (`usage-monitor-ledger-v1.json`).
/// Stores only `(timestamp, model, inputTokens, cacheReadTokens, outputTokens)` per conversation ID
/// — never prompts, replies, file paths, or credentials — so deleting old conversations from
/// `~/.gemini/antigravity/brain/` never erases historical usage totals or cumulative API spend.
public final class UsageLedger: @unchecked Sendable {
    public struct CompactEntry: Codable, Sendable, Equatable {
        /// Epoch seconds (millisecond precision).
        public let t: Double
        /// Model identifier.
        public let m: String
        /// Uncached input tokens.
        public let i: Int
        /// Cached input tokens.
        public let c: Int
        /// Output tokens.
        public let o: Int

        public init(from record: TranscriptRecord) {
            self.t = (record.timestamp.timeIntervalSince1970 * 1000.0).rounded() / 1000.0
            self.m = record.model
            self.i = record.inputTokens
            self.c = record.cacheReadTokens
            self.o = record.outputTokens
        }

        public func toRecord(conversationId: String) -> TranscriptRecord {
            TranscriptRecord(
                timestamp: Date(timeIntervalSince1970: t),
                model: m,
                inputTokens: i,
                cacheReadTokens: c,
                outputTokens: o,
                conversationId: conversationId
            )
        }
    }

    private struct StorageFile: Codable {
        var version: Int
        var updatedAt: Date
        var conversations: [String: [CompactEntry]]
    }

    private struct VersionProbe: Decodable {
        let version: Int
    }

    public static var defaultStorageDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport.appendingPathComponent("AntigravityUsageMonitor", isDirectory: true)
    }

    public static var defaultLedgerURL: URL {
        defaultStorageDirectory.appendingPathComponent("usage-monitor-ledger-v1.json", isDirectory: false)
    }

    public let fileURL: URL
    private let lock = NSLock()
    private var conversations: [String: [CompactEntry]] = [:]
    private var cachedRecords: [TranscriptRecord] = []
    private var loaded = false
    private var readOnlyFutureVersion = false
    private var hasUnflushedChanges = false
    private var lastFlushAt: Date = .distantPast

    public init(fileURL: URL = UsageLedger.defaultLedgerURL) {
        self.fileURL = fileURL
    }

    /// Merges changed live scanned records (grouped by conversationId) with persisted archived conversations.
    /// Any conversation deleted from disk retains its previously persisted numeric entries.
    public func mergeAndPersist(
        liveByConversation: [String: [TranscriptRecord]],
        now: Date = Date(),
        forceFlush: Bool = false
    ) -> (records: [TranscriptRecord], conversationCount: Int) {
        lock.lock()
        defer { lock.unlock() }

        let canPersist = loadIfNeeded(now: now)
        var mutated = false

        for (convId, liveRecords) in liveByConversation where !liveRecords.isEmpty {
            let compact = liveRecords.map(CompactEntry.init(from:))
            if conversations[convId] != compact {
                conversations[convId] = compact
                hasUnflushedChanges = true
                mutated = true
            }
        }

        if mutated || (cachedRecords.isEmpty && !conversations.isEmpty) {
            rebuildRecordCache()
        }

        if canPersist && !readOnlyFutureVersion && hasUnflushedChanges {
            if forceFlush || now.timeIntervalSince(lastFlushAt) >= 2.0 {
                save(now: now)
            }
        }

        return (cachedRecords, conversations.count)
    }

    /// Synchronously flushes any pending buffered writes to disk (safe for `applicationWillTerminate`).
    public func flush(now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        guard loaded && !readOnlyFutureVersion && hasUnflushedChanges else { return }
        save(now: now)
    }

    /// Returns `true` when safe to persist back to disk; returns `false` on transient read I/O errors
    /// so we never clobber an unreadable existing file with an empty in-memory map.
    private func loadIfNeeded(now: Date) -> Bool {
        if loaded { return true }

        var st = stat()
        if lstat(fileURL.path, &st) != 0 {
            if errno == ENOENT {
                loaded = true
                return true
            }
            return false
        }

        // Refuse to follow symlinks for security.
        if (st.st_mode & S_IFMT) == S_IFLNK {
            return false
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            // Transient I/O failure (e.g. EMFILE): do not mark loaded and do not overwrite.
            return false
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode(StorageFile.self, from: data) {
            if decoded.version == 1 {
                self.conversations = decoded.conversations
                rebuildRecordCache()
                loaded = true
                return true
            }
            if decoded.version > 1 {
                // Newer schema from a future version: keep read-only in memory, never downgrade/overwrite disk.
                self.readOnlyFutureVersion = true
                loaded = true
                return false
            }
        } else if let probe = try? JSONDecoder().decode(VersionProbe.self, from: data), probe.version > 1 {
            self.readOnlyFutureVersion = true
            loaded = true
            return false
        }

        // File exists but is corrupted JSON -> back it up before rebuilding.
        let backupURL = URL(fileURLWithPath: "\(fileURL.path).corrupt-\(Int(now.timeIntervalSince1970)).bak")
        try? FileManager.default.moveItem(at: fileURL, to: backupURL)
        loaded = true
        return true
    }

    private func rebuildRecordCache() {
        var rebuilt: [TranscriptRecord] = []
        rebuilt.reserveCapacity(conversations.values.reduce(0) { $0 + $1.count })
        for (convId, entries) in conversations {
            for entry in entries {
                rebuilt.append(entry.toRecord(conversationId: convId))
            }
        }
        cachedRecords = rebuilt
    }

    private func save(now: Date) {
        let payload = StorageFile(version: 1, updatedAt: now, conversations: conversations)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(payload) else { return }

        let fm = FileManager.default
        let dir = fileURL.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)

        // Refuse to write over a symlink target.
        var st = stat()
        if lstat(fileURL.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFLNK {
            return
        }

        do {
            try data.write(to: fileURL, options: .atomic)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            lastFlushAt = now
            hasUnflushedChanges = false
        } catch {
            // Keep `hasUnflushedChanges = true` so subsequent refreshes or terminate flush retry automatically.
        }
    }
}
