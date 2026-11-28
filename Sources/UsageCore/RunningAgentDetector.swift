import Darwin
import Foundation
import SQLite3

public enum RunningAgentSource: String, Sendable, Equatable {
    case desktop
    case cli
}

public struct RunningAgentInfo: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let source: RunningAgentSource
    public let subagentCount: Int
    public let lastModifiedAt: Date?

    public init(
        id: String,
        title: String,
        source: RunningAgentSource,
        subagentCount: Int = 0,
        lastModifiedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.source = source
        self.subagentCount = subagentCount
        self.lastModifiedAt = lastModifiedAt
    }
}

public struct RunningAgentSummary: Sendable, Equatable {
    public let desktopAgents: [RunningAgentInfo]
    public let cliAgents: [RunningAgentInfo]

    public init(desktopAgents: [RunningAgentInfo], cliAgents: [RunningAgentInfo]) {
        self.desktopAgents = desktopAgents
        self.cliAgents = cliAgents
    }

    public static let empty = RunningAgentSummary(desktopAgents: [], cliAgents: [])

    public var desktopCount: Int { desktopAgents.count }
    public var cliCount: Int { cliAgents.count }
    public var totalCount: Int { desktopAgents.count + cliAgents.count }

    public var allAgents: [RunningAgentInfo] {
        (desktopAgents + cliAgents).sorted { lhs, rhs in
            let l = lhs.lastModifiedAt ?? .distantPast
            let r = rhs.lastModifiedAt ?? .distantPast
            if l != r { return l > r }
            return lhs.id < rhs.id
        }
    }
}

/// Read-only detector for currently running Antigravity desktop & CLI agents
/// via the local `conversation_summaries.db` SQLite databases (zero private APIs, zero third-party deps).
public struct RunningAgentDetector: Sendable {
    public static var defaultDesktopDatabaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/antigravity/conversation_summaries.db", isDirectory: false)
    }

    public static var defaultCLIDatabaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/antigravity-cli/conversation_summaries.db", isDirectory: false)
    }

    public let desktopDatabaseURL: URL
    public let cliDatabaseURL: URL

    public init(
        desktopDatabaseURL: URL = RunningAgentDetector.defaultDesktopDatabaseURL,
        cliDatabaseURL: URL = RunningAgentDetector.defaultCLIDatabaseURL
    ) {
        self.desktopDatabaseURL = desktopDatabaseURL
        self.cliDatabaseURL = cliDatabaseURL
    }

    public func detect(
        desktopProcessAlive: Bool,
        cliProcessAlive: Bool,
        now: Date = Date(),
        maxStaleSeconds: TimeInterval = 6 * 3600
    ) -> RunningAgentSummary {
        let desktop = desktopProcessAlive
            ? queryRunningAgents(at: desktopDatabaseURL, source: .desktop, now: now, maxStaleSeconds: maxStaleSeconds)
            : []
        let cli = cliProcessAlive
            ? queryRunningAgents(at: cliDatabaseURL, source: .cli, now: now, maxStaleSeconds: maxStaleSeconds)
            : []
        return RunningAgentSummary(desktopAgents: desktop, cliAgents: cli)
    }

    private struct RawRow {
        let id: String
        let title: String
        let nestingDepth: Int
        let parentId: String
        let lastModifiedAt: Date?
    }

    private func queryRunningAgents(
        at url: URL,
        source: RunningAgentSource,
        now: Date,
        maxStaleSeconds: TimeInterval
    ) -> [RunningAgentInfo] {
        var st = stat()
        guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
            return []
        }

        var db: OpaquePointer?
        let openFlags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(url.path, &db, openFlags, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return []
        }
        defer { sqlite3_close(db) }

        sqlite3_busy_timeout(db, 200)

        let sql = """
        SELECT conversation_id, title, nesting_depth, parent_conversation_id, last_modified_time
        FROM conversation_summaries
        WHERE status = 'CASCADE_RUN_STATUS_RUNNING' AND killed = 0
        ORDER BY last_modified_time DESC
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return []
        }
        defer { sqlite3_finalize(stmt) }

        var rows: [RawRow] = []
        let cutoff = now.addingTimeInterval(-maxStaleSeconds)

        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = Self.columnText(stmt, index: 0)
            guard !id.isEmpty else { continue }
            let title = Self.columnText(stmt, index: 1).trimmingCharacters(in: .whitespacesAndNewlines)
            let depth = Int(sqlite3_column_int(stmt, 2))
            let parentId = Self.columnText(stmt, index: 3)
            let rawTime = Self.columnText(stmt, index: 4)
            let parsedTime = Self.parseSQLiteTimestamp(rawTime)

            if let parsedTime, parsedTime < cutoff {
                continue
            }

            rows.append(
                RawRow(
                    id: id,
                    title: title,
                    nestingDepth: depth,
                    parentId: parentId,
                    lastModifiedAt: parsedTime
                )
            )
        }

        let topLevel = rows.filter { $0.nestingDepth == 0 }
        let topLevelIds = Set(topLevel.map(\.id))

        // Map parent relationships so multi-level running subagents roll up to their top-level ancestor.
        var parentById: [String: String] = [:]
        for row in rows where !row.parentId.isEmpty {
            parentById[row.id] = row.parentId
        }

        var subagentCountByTopId: [String: Int] = [:]
        for row in rows where row.nestingDepth > 0 {
            var cursor = row.parentId
            var visited = Set<String>([row.id])
            while !cursor.isEmpty, !visited.contains(cursor) {
                visited.insert(cursor)
                if topLevelIds.contains(cursor) {
                    subagentCountByTopId[cursor, default: 0] += 1
                    break
                }
                cursor = parentById[cursor] ?? ""
            }
        }

        return topLevel.map { row in
            RunningAgentInfo(
                id: row.id,
                title: row.title.isEmpty ? String(row.id.prefix(8)) : row.title,
                source: source,
                subagentCount: subagentCountByTopId[row.id] ?? 0,
                lastModifiedAt: row.lastModifiedAt
            )
        }
    }

    private static func columnText(_ stmt: OpaquePointer, index: Int32) -> String {
        guard let cString = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: cString)
    }

    /// Parses SQLite timestamps such as `2026-11-28 07:34:08.83818+00:00` or RFC 3339 strings.
    public static func parseSQLiteTimestamp(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Normalize space separator between date and time to 'T'
        var normalized = trimmed
        if normalized.count > 10 {
            let idx = normalized.index(normalized.startIndex, offsetBy: 10)
            if normalized[idx] == " " {
                normalized.replaceSubrange(idx...idx, with: "T")
            }
        }

        // Strip arbitrary-precision fractional seconds (e.g. .83818 or .311557) for rock-solid ISO-8601 parsing
        if let dotIdx = normalized.firstIndex(of: ".") {
            var tzIdx = normalized.index(after: dotIdx)
            while tzIdx < normalized.endIndex, normalized[tzIdx].isNumber {
                tzIdx = normalized.index(after: tzIdx)
            }
            normalized.removeSubrange(dotIdx..<tzIdx)
        }

        return ISO8601DateParser.parse(normalized)
    }
}
