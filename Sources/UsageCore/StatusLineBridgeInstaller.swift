import Foundation

public enum BridgeStatus: Sendable, Equatable {
    case notInstalled(existingCommand: String?)
    case installedDirect
    case installedChained(originalCommand: String)

    public var isInstalled: Bool {
        switch self {
        case .notInstalled: return false
        case .installedDirect, .installedChained: return true
        }
    }
}

public enum BridgeInstallerError: Error, LocalizedError, Sendable {
    case invalidSettingsJSON(String)
    case ioError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidSettingsJSON(let detail):
            return "settings.json 格式无效：\(detail)"
        case .ioError(let detail):
            return "读写桥接配置失败：\(detail)"
        }
    }
}

public struct StatusLineBridgeInstaller: Sendable {
    public let cliConfigDirectory: URL

    public init(cliConfigDirectory: URL = StatusLineBridgeInstaller.defaultCLIConfigDirectory) {
        self.cliConfigDirectory = cliConfigDirectory
    }

    public static var defaultCLIConfigDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/antigravity-cli", isDirectory: true)
    }

    public var settingsURL: URL {
        cliConfigDirectory.appendingPathComponent("settings.json", isDirectory: false)
    }

    public var backupSettingsURL: URL {
        cliConfigDirectory.appendingPathComponent("settings.json.usage-monitor.bak", isDirectory: false)
    }

    public var bridgeScriptURL: URL {
        cliConfigDirectory.appendingPathComponent("usage-monitor-statusline.sh", isDirectory: false)
    }

    public var snapshotURL: URL {
        cliConfigDirectory.appendingPathComponent("usage-monitor-snapshot.json", isDirectory: false)
    }

    public var metadataURL: URL {
        cliConfigDirectory.appendingPathComponent("usage-monitor-bridge.json", isDirectory: false)
    }

    private struct BridgeMetadata: Codable {
        let hadPreviousStatusLine: Bool
        let previousCommand: String?
        let previousType: String?
        let previousPadding: Int?
        let previousEnabled: Bool?
        let previousStackWithDefault: Bool?
    }

    public func status() -> BridgeStatus {
        guard let root = try? readSettingsObject(),
              let statusLine = root["statusLine"] as? [String: Any],
              let command = statusLine["command"] as? String else {
            return .notInstalled(existingCommand: nil)
        }

        let expandedCommand = (command as NSString).expandingTildeInPath
        if expandedCommand == bridgeScriptURL.path || command == bridgeScriptURL.path {
            if let meta = readMetadata(), let previous = meta.previousCommand, !previous.isEmpty {
                return .installedChained(originalCommand: previous)
            }
            return .installedDirect
        }

        return .notInstalled(existingCommand: command)
    }

    @discardableResult
    public func install() throws -> BridgeStatus {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: cliConfigDirectory, withIntermediateDirectories: true)
        } catch {
            throw BridgeInstallerError.ioError(error.localizedDescription)
        }

        var root: [String: Any]
        if fm.fileExists(atPath: settingsURL.path) {
            root = try readSettingsObject()
            // Always create/refresh backup before modifying settings.json.
            do {
                if fm.fileExists(atPath: backupSettingsURL.path) {
                    try fm.removeItem(at: backupSettingsURL)
                }
                try fm.copyItem(at: settingsURL, to: backupSettingsURL)
            } catch {
                throw BridgeInstallerError.ioError("备份 settings.json 失败：\(error.localizedDescription)")
            }
        } else {
            root = [:]
        }

        let existingStatusLine = root["statusLine"] as? [String: Any]
        let existingCommand = existingStatusLine?["command"] as? String
        let expandedExisting = existingCommand.map { ($0 as NSString).expandingTildeInPath }

        let chainedCommand: String?
        if expandedExisting == bridgeScriptURL.path {
            // Re-install idempotently, preserving previously recorded metadata.
            chainedCommand = readMetadata()?.previousCommand
        } else {
            let meta = BridgeMetadata(
                hadPreviousStatusLine: existingStatusLine != nil,
                previousCommand: existingCommand,
                previousType: existingStatusLine?["type"] as? String,
                previousPadding: existingStatusLine?["padding"] as? Int,
                previousEnabled: existingStatusLine?["enabled"] as? Bool,
                previousStackWithDefault: existingStatusLine?["stack_with_default"] as? Bool
            )
            try writeMetadata(meta)
            chainedCommand = existingCommand
        }

        try writeBridgeScript(chainedCommand: chainedCommand)

        var newStatusLine: [String: Any] = [
            "type": "command",
            "command": bridgeScriptURL.path,
            "enabled": true,
        ]

        if let existingPadding = existingStatusLine?["padding"] as? Int {
            newStatusLine["padding"] = existingPadding
        }

        if let chainedCommand, !chainedCommand.isEmpty {
            // Preserve user's original stacking preference when chaining their custom script.
            if let existingStack = existingStatusLine?["stack_with_default"] as? Bool {
                newStatusLine["stack_with_default"] = existingStack
            }
        } else {
            // Keep the built-in CLI status line visible when no custom script existed.
            newStatusLine["stack_with_default"] = true
        }

        root["statusLine"] = newStatusLine
        try writeSettingsObject(root)

        if let chainedCommand, !chainedCommand.isEmpty {
            return .installedChained(originalCommand: chainedCommand)
        }
        return .installedDirect
    }

    public func uninstall() throws {
        let fm = FileManager.default

        if fm.fileExists(atPath: settingsURL.path) {
            var root = try readSettingsObject()
            if let meta = readMetadata() {
                if meta.hadPreviousStatusLine {
                    var restored: [String: Any] = [:]
                    if let cmd = meta.previousCommand { restored["command"] = cmd }
                    if let type = meta.previousType { restored["type"] = type }
                    if let padding = meta.previousPadding { restored["padding"] = padding }
                    if let enabled = meta.previousEnabled { restored["enabled"] = enabled }
                    if let stack = meta.previousStackWithDefault { restored["stack_with_default"] = stack }
                    root["statusLine"] = restored
                } else {
                    root.removeValue(forKey: "statusLine")
                }
                try writeSettingsObject(root)
            } else if let current = root["statusLine"] as? [String: Any],
                      let cmd = current["command"] as? String,
                      (cmd as NSString).expandingTildeInPath == bridgeScriptURL.path {
                root.removeValue(forKey: "statusLine")
                try writeSettingsObject(root)
            }
        }

        if fm.fileExists(atPath: bridgeScriptURL.path) {
            try? fm.removeItem(at: bridgeScriptURL)
        }
        if fm.fileExists(atPath: metadataURL.path) {
            try? fm.removeItem(at: metadataURL)
        }
    }

    private func writeBridgeScript(chainedCommand: String?) throws {
        let escapedSnapshot = shellSingleQuote(snapshotURL.path)
        var lines: [String] = [
            "#!/bin/sh",
            "# Managed by Antigravity Usage Monitor (safe statusLine bridge).",
            "set -eu",
            "SNAPSHOT=\(escapedSnapshot)",
            "TMP_FILE=\"${SNAPSHOT}.tmp.$$\"",
            "cat > \"$TMP_FILE\"",
            "mv -f \"$TMP_FILE\" \"$SNAPSHOT\"",
        ]

        if let chainedCommand, !chainedCommand.isEmpty {
            let escapedOriginal = shellSingleQuote(chainedCommand)
            lines.append("exec /bin/sh -c \(escapedOriginal) < \"$SNAPSHOT\"")
        } else {
            lines.append("exit 0")
        }

        let content = lines.joined(separator: "\n") + "\n"
        do {
            try content.write(to: bridgeScriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bridgeScriptURL.path)
        } catch {
            throw BridgeInstallerError.ioError("写入桥接脚本失败：\(error.localizedDescription)")
        }
    }

    private func readSettingsObject() throws -> [String: Any] {
        let data: Data
        do {
            data = try Data(contentsOf: settingsURL)
        } catch {
            throw BridgeInstallerError.ioError(error.localizedDescription)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BridgeInstallerError.invalidSettingsJSON("根节点必须是 JSON 对象")
        }
        return object
    }

    private func writeSettingsObject(_ object: [String: Any]) throws {
        do {
            let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: settingsURL, options: .atomic)
        } catch {
            throw BridgeInstallerError.ioError("写入 settings.json 失败：\(error.localizedDescription)")
        }
    }

    private func readMetadata() -> BridgeMetadata? {
        guard let data = try? Data(contentsOf: metadataURL) else { return nil }
        return try? JSONDecoder().decode(BridgeMetadata.self, from: data)
    }

    private func writeMetadata(_ metadata: BridgeMetadata) throws {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(metadata)
            try data.write(to: metadataURL, options: .atomic)
        } catch {
            throw BridgeInstallerError.ioError("写入桥接元数据失败：\(error.localizedDescription)")
        }
    }

    private func shellSingleQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
